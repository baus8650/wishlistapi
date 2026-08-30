import Fluent
import Vapor

struct NetworkWishlistDTO: Content {
    let wishlistID: UUID
    let title: String
    let owner: SocialUserDTO
    let access: String
    let accountShareID: UUID?
}

struct NetworkController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("network", "wishlists", use: wishlists)
    }

    func wishlists(req: Request) async throws -> [NetworkWishlistDTO] {
        let me = try req.auth.require(User.self).requireID()
        let outgoing = try await Friendship.query(on: req.db)
            .filter(\.$requester.$id == me).filter(\.$status == "accepted").all().map(\.$recipient.id)
        let incoming = try await Friendship.query(on: req.db)
            .filter(\.$recipient.$id == me).filter(\.$status == "accepted").all().map(\.$requester.id)
        let friendIDs = Array(Set(outgoing + incoming))
        guard !friendIDs.isEmpty else { return [] }

        let users = try await User.query(on: req.db).filter(\.$id ~~ friendIDs).all()
        let owners = Dictionary(uniqueKeysWithValues: try users.map { user -> (UUID, SocialUserDTO) in
            let id = try user.requireID()
            let username = user.username ?? "hushful_\(id.uuidString.prefix(8).lowercased())"
            return (id, .init(id: id, username: username, displayName: user.displayName, hasAvatar: user.avatarData != nil))
        })

        var result: [UUID: NetworkWishlistDTO] = [:]
        let publicLists = try await Wishlist.query(on: req.db)
            .filter(\.$owner.$id ~~ friendIDs)
            .filter(\.$visibility == "public")
            .all()
        for wishlist in publicLists {
            let id = try wishlist.requireID(), ownerID = wishlist.$owner.id
            guard let owner = owners[ownerID] else { continue }
            result[id] = .init(wishlistID: id, title: wishlist.title, owner: owner, access: "public", accountShareID: nil)
        }

        let shared = try await SocialWishlistAccess.query(on: req.db)
            .filter(\.$user.$id == me).with(\.$wishlist).all()
        for access in shared where friendIDs.contains(access.wishlist.$owner.id) {
            let wishlist = access.wishlist
            let id = try wishlist.requireID(), ownerID = wishlist.$owner.id
            guard let owner = owners[ownerID] else { continue }
            result[id] = .init(wishlistID: id, title: wishlist.title, owner: owner, access: "shared", accountShareID: access.$viewer.id)
        }

        return result.values.sorted {
            let ownerOrder = ($0.owner.displayName ?? $0.owner.username).localizedCaseInsensitiveCompare($1.owner.displayName ?? $1.owner.username)
            return ownerOrder == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : ownerOrder == .orderedAscending
        }
    }
}
