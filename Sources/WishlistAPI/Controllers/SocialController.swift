import Fluent
import Vapor

struct SocialUserDTO: Content {
    let id: UUID
    let username: String
    let displayName: String?
}

struct FriendshipDTO: Content {
    let id: UUID
    let user: SocialUserDTO
    let direction: String
    let status: String
}

struct FriendGroupDTO: Content {
    let id: UUID
    let name: String
    let members: [SocialUserDTO]
}

struct SocialController: RouteCollection {
    struct CreateGroupRequest: Content { let name: String }

    func boot(routes: any RoutesBuilder) throws {
        routes.get("users", "search", use: search)
        routes.get("friends", use: friends)
        routes.get("friend-requests", use: requests)
        routes.post("friend-requests", ":userID", use: requestFriend)
        routes.post("friend-requests", ":friendshipID", "accept", use: accept)
        routes.delete("friendships", ":friendshipID", use: removeFriendship)
        routes.put("blocks", ":userID", use: block)
        routes.delete("blocks", ":userID", use: unblock)
        routes.get("friend-groups", use: groups)
        routes.post("friend-groups", use: createGroup)
        routes.delete("friend-groups", ":groupID", use: deleteGroup)
        routes.put("friend-groups", ":groupID", "members", ":userID", use: addMember)
        routes.delete("friend-groups", ":groupID", "members", ":userID", use: removeMember)
    }

    func search(req: Request) async throws -> [SocialUserDTO] {
        let me = try req.auth.require(User.self).requireID()
        let q = (req.query[String.self, at: "q"] ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        let blocks = try await blockPairs(for: me, on: req.db)
        return try await User.query(on: req.db)
            .filter(\.$isDiscoverable == true)
            .filter(\.$username ~~ q)
            .limit(20).all()
            .compactMap { user in
                guard let id = user.id, id != me, !blocks.contains(id), let username = user.username else { return nil }
                return SocialUserDTO(id: id, username: username, displayName: user.displayName)
            }
    }

    func friends(req: Request) async throws -> [FriendshipDTO] {
        let me = try req.auth.require(User.self).requireID()
        return try await friendshipDTOs(for: me, status: "accepted", on: req.db)
    }

    func requests(req: Request) async throws -> [FriendshipDTO] {
        let me = try req.auth.require(User.self).requireID()
        return try await friendshipDTOs(for: me, status: "pending", on: req.db)
    }

    func requestFriend(req: Request) async throws -> FriendshipDTO {
        let me = try req.auth.require(User.self).requireID()
        guard let other = req.parameters.get("userID", as: UUID.self), other != me,
              let user = try await User.find(other, on: req.db), user.isDiscoverable else { throw Abort(.notFound) }
        guard user.friendRequestPolicy != "nobody" else { throw Abort(.forbidden, reason: "This person is not accepting friend requests.") }
        guard !((try await blockPairs(for: me, on: req.db)).contains(other)) else { throw Abort(.notFound) }
        if let existing = try await relationship(between: me, and: other, on: req.db) {
            throw Abort(.conflict, reason: existing.status == "accepted" ? "You are already friends." : "A friend request already exists.")
        }
        let friendship = Friendship(requesterID: me, recipientID: other)
        try await friendship.save(on: req.db)
        return FriendshipDTO(id: try friendship.requireID(), user: try socialUser(user), direction: "outgoing", status: "pending")
    }

    func accept(req: Request) async throws -> FriendshipDTO {
        let me = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("friendshipID", as: UUID.self),
              let friendship = try await Friendship.query(on: req.db).filter(\.$id == id).filter(\.$recipient.$id == me).filter(\.$status == "pending").with(\.$requester).first()
        else { throw Abort(.notFound) }
        friendship.status = "accepted"
        try await friendship.save(on: req.db)
        return FriendshipDTO(id: id, user: try socialUser(friendship.requester), direction: "incoming", status: "accepted")
    }

    func removeFriendship(req: Request) async throws -> HTTPStatus {
        let me = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("friendshipID", as: UUID.self), let friendship = try await Friendship.find(id, on: req.db),
              friendship.$requester.id == me || friendship.$recipient.id == me else { throw Abort(.notFound) }
        let other = friendship.$requester.id == me ? friendship.$recipient.id : friendship.$requester.id
        try await friendship.delete(on: req.db)
        try await revokeSocialSharing(between: me, and: other, on: req.db)
        return .noContent
    }

    func block(req: Request) async throws -> HTTPStatus {
        let me = try req.auth.require(User.self).requireID()
        guard let other = req.parameters.get("userID", as: UUID.self), other != me, try await User.find(other, on: req.db) != nil else { throw Abort(.notFound) }
        if let friendship = try await relationship(between: me, and: other, on: req.db) { try await friendship.delete(on: req.db) }
        if try await UserBlock.query(on: req.db).filter(\.$blocker.$id == me).filter(\.$blocked.$id == other).first() == nil {
            try await UserBlock(blockerID: me, blockedID: other).save(on: req.db)
        }
        try await revokeSocialSharing(between: me, and: other, on: req.db)
        return .noContent
    }

    func unblock(req: Request) async throws -> HTTPStatus {
        let me = try req.auth.require(User.self).requireID()
        guard let other = req.parameters.get("userID", as: UUID.self) else { throw Abort(.badRequest) }
        if let row = try await UserBlock.query(on: req.db).filter(\.$blocker.$id == me).filter(\.$blocked.$id == other).first() { try await row.delete(on: req.db) }
        return .noContent
    }

    func groups(req: Request) async throws -> [FriendGroupDTO] {
        let me = try req.auth.require(User.self).requireID()
        let ownedGroups = try await FriendGroup.query(on: req.db)
            .filter(\.$owner.$id == me)
            .sort(\.$name)
            .all()
        var result: [FriendGroupDTO] = []
        for group in ownedGroups {
            result.append(try await groupDTO(group, on: req.db))
        }
        return result
    }

    func createGroup(req: Request) async throws -> FriendGroupDTO {
        let me = try req.auth.require(User.self).requireID()
        let name = try req.content.decode(CreateGroupRequest.self).name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60 else { throw Abort(.badRequest, reason: "Group names must be 1–60 characters.") }
        let group = FriendGroup(ownerID: me, name: name); try await group.save(on: req.db)
        return FriendGroupDTO(id: try group.requireID(), name: name, members: [])
    }

    func deleteGroup(req: Request) async throws -> HTTPStatus {
        let group = try await ownedGroup(req)
        let wishlistIDs = Set(try await WishlistAudienceGrant.query(on: req.db).filter(\.$group.$id == group.requireID()).all().map(\.$wishlist.id))
        try await group.delete(on: req.db)
        for wishlistID in wishlistIDs { try await AudienceService.sync(wishlistID: wishlistID, on: req.db) }
        return .noContent
    }

    func addMember(req: Request) async throws -> FriendGroupDTO {
        let me = try req.auth.require(User.self).requireID(), group = try await ownedGroup(req)
        guard let userID = req.parameters.get("userID", as: UUID.self), let friendship = try await relationship(between: me, and: userID, on: req.db), friendship.status == "accepted" else { throw Abort(.forbidden, reason: "Only friends can be added to a group.") }
        if try await FriendGroupMember.query(on: req.db).filter(\.$group.$id == group.requireID()).filter(\.$user.$id == userID).first() == nil { try await FriendGroupMember(groupID: try group.requireID(), userID: userID).save(on: req.db) }
        try await AudienceService.syncGrants(forGroup: try group.requireID(), on: req.db)
        return try await groupDTO(group, on: req.db)
    }

    func removeMember(req: Request) async throws -> FriendGroupDTO {
        let group = try await ownedGroup(req)
        guard let userID = req.parameters.get("userID", as: UUID.self) else { throw Abort(.badRequest) }
        if let member = try await FriendGroupMember.query(on: req.db).filter(\.$group.$id == group.requireID()).filter(\.$user.$id == userID).first() { try await member.delete(on: req.db) }
        try await AudienceService.syncGrants(forGroup: try group.requireID(), on: req.db)
        return try await groupDTO(group, on: req.db)
    }

    private func ownedGroup(_ req: Request) async throws -> FriendGroup {
        let me = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("groupID", as: UUID.self), let group = try await FriendGroup.query(on: req.db).filter(\.$id == id).filter(\.$owner.$id == me).first() else { throw Abort(.notFound) }
        return group
    }

    private func groupDTO(_ group: FriendGroup, on db: any Database) async throws -> FriendGroupDTO {
        let users = try await FriendGroupMember.query(on: db).filter(\.$group.$id == group.requireID()).with(\.$user).all().map { try socialUser($0.user) }
        return FriendGroupDTO(id: try group.requireID(), name: group.name, members: users)
    }

    private func friendshipDTOs(for me: UUID, status: String, on db: any Database) async throws -> [FriendshipDTO] {
        let outgoing = try await Friendship.query(on: db).filter(\.$requester.$id == me).filter(\.$status == status).with(\.$recipient).all().map { FriendshipDTO(id: try $0.requireID(), user: try socialUser($0.recipient), direction: "outgoing", status: $0.status) }
        let incoming = try await Friendship.query(on: db).filter(\.$recipient.$id == me).filter(\.$status == status).with(\.$requester).all().map { FriendshipDTO(id: try $0.requireID(), user: try socialUser($0.requester), direction: "incoming", status: $0.status) }
        return (outgoing + incoming).sorted { ($0.user.displayName ?? $0.user.username).localizedCaseInsensitiveCompare($1.user.displayName ?? $1.user.username) == .orderedAscending }
    }

    private func relationship(between first: UUID, and second: UUID, on db: any Database) async throws -> Friendship? {
        if let row = try await Friendship.query(on: db).filter(\.$requester.$id == first).filter(\.$recipient.$id == second).first() { return row }
        return try await Friendship.query(on: db).filter(\.$requester.$id == second).filter(\.$recipient.$id == first).first()
    }

    private func blockPairs(for me: UUID, on db: any Database) async throws -> Set<UUID> {
        let outgoing = try await UserBlock.query(on: db).filter(\.$blocker.$id == me).all().map(\.$blocked.id)
        let incoming = try await UserBlock.query(on: db).filter(\.$blocked.$id == me).all().map(\.$blocker.id)
        return Set(outgoing + incoming)
    }

    private func revokeSocialSharing(between first: UUID, and second: UUID, on db: any Database) async throws {
        for (owner, formerFriend) in [(first, second), (second, first)] {
            for member in try await FriendGroupMember.query(on: db).filter(\.$user.$id == formerFriend).all() {
                if let group = try await FriendGroup.find(member.$group.id, on: db), group.$owner.id == owner { try await member.delete(on: db) }
            }
            for grant in try await WishlistAudienceGrant.query(on: db).filter(\.$user.$id == formerFriend).all() {
                if let wishlist = try await Wishlist.find(grant.$wishlist.id, on: db), wishlist.$owner.id == owner { try await grant.delete(on: db) }
            }
            try await AudienceService.syncAllOwnedWishlists(ownerID: owner, on: db)
        }
    }

    private func socialUser(_ user: User) throws -> SocialUserDTO {
        guard let id = user.id, let username = user.username else { throw Abort(.internalServerError) }
        return .init(id: id, username: username, displayName: user.displayName)
    }
}
