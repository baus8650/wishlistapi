import Fluent
import Vapor

struct WishlistCollaboratorController: RouteCollection {
    struct CollaboratorDTO: Content {
        let id: UUID
        let displayName: String?
        let username: String?
        let isPrimaryOwner: Bool
    }
    struct Response: Content {
        let mode: String
        let collaborators: [CollaboratorDTO]
    }
    struct UpdateRequest: Content {
        let mode: String
        let userIDs: [UUID]
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get(":wishlistID", "collaborators", use: show)
        routes.put(":wishlistID", "collaborators", use: update)
    }

    func show(req: Request) async throws -> Response {
        let wishlist = try await WishlistPermissionService.editableWishlist(req: req)
        return try await response(for: wishlist, on: req.db)
    }

    func update(req: Request) async throws -> Response {
        let userID = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let wishlist = try await Wishlist.query(on: req.db)
                .filter(\.$id == wishlistID).filter(\.$owner.$id == userID).first() else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(UpdateRequest.self)
        guard ["our_wishlist", "gift_planning"].contains(body.mode) else {
            throw Abort(.badRequest, reason: "Invalid collaboration mode.")
        }
        let requested = Set(body.userIDs).subtracting([userID])
        for otherID in requested {
            guard try await acceptedFriendship(userID, otherID, on: req.db) else {
                throw Abort(.forbidden, reason: "Only friends can co-own a wishlist.")
            }
        }
        let existing = try await WishlistCollaborator.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID).all()
        let existingIDs = Set(existing.map(\.$user.id))
        for collaborator in existing where !requested.contains(collaborator.$user.id) {
            try await removePlanningAccess(wishlistID: wishlistID, userID: collaborator.$user.id, on: req.db)
            try await collaborator.delete(on: req.db)
        }
        for newID in requested.subtracting(existingIDs) {
            try await WishlistCollaborator(wishlistID: wishlistID, userID: newID).save(on: req.db)
            try await ActivityService.create(
                userID: newID, actorID: userID, wishlistID: wishlistID,
                kind: "wishlist_collaboration", title: "You’re now a wishlist owner",
                message: "You can now collaborate on “\(wishlist.title)”.", on: req.db,
                client: req.client, logger: req.logger
            )
        }
        wishlist.collaborationMode = body.mode
        try await wishlist.save(on: req.db)
        let allOwners = requested.union([userID])
        if body.mode == "gift_planning" {
            for ownerID in allOwners { try await ensurePlanningAccess(wishlistID: wishlistID, userID: ownerID, on: req.db) }
        } else {
            for ownerID in allOwners { try await removePlanningAccess(wishlistID: wishlistID, userID: ownerID, on: req.db) }
        }
        return try await response(for: wishlist, on: req.db)
    }

    private func response(for wishlist: Wishlist, on db: any Database) async throws -> Response {
        let owner = try await wishlist.$owner.get(on: db)
        let collaborators = try await WishlistCollaborator.query(on: db)
            .filter(\.$wishlist.$id == wishlist.requireID()).with(\.$user).all()
        let rows = [CollaboratorDTO(id: try owner.requireID(), displayName: owner.displayName, username: owner.username, isPrimaryOwner: true)]
            + collaborators.map { CollaboratorDTO(id: $0.$user.id, displayName: $0.user.displayName, username: $0.user.username, isPrimaryOwner: false) }
        return .init(mode: wishlist.collaborationMode, collaborators: rows)
    }

    private func acceptedFriendship(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        try await Friendship.query(on: db).group(.or) { group in
            group.group(.and) { $0.filter(\.$requester.$id == first).filter(\.$recipient.$id == second) }
            group.group(.and) { $0.filter(\.$requester.$id == second).filter(\.$recipient.$id == first) }
        }.filter(\.$status == "accepted").first() != nil
    }

    private func ensurePlanningAccess(wishlistID: UUID, userID: UUID, on db: any Database) async throws {
        if try await SocialWishlistAccess.query(on: db)
            .filter(\.$wishlist.$id == wishlistID).filter(\.$user.$id == userID).first() != nil { return }
        let viewer: WishlistViewer
        if let existing = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID).filter(\.$user.$id == userID).first() {
            viewer = existing
        } else {
            let token = try Tokens.randomURLSafeToken()
            viewer = WishlistViewer(wishlistId: wishlistID, viewerTokenHash: Tokens.sha256Hex(token), userId: userID)
            try await viewer.save(on: db)
        }
        try await SocialWishlistAccess(wishlistID: wishlistID, userID: userID, viewerID: viewer.requireID()).save(on: db)
    }

    private func removePlanningAccess(wishlistID: UUID, userID: UUID, on db: any Database) async throws {
        let accesses = try await SocialWishlistAccess.query(on: db)
            .filter(\.$wishlist.$id == wishlistID).filter(\.$user.$id == userID).all()
        for access in accesses { try await access.delete(on: db) }
        if let viewer = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID).filter(\.$user.$id == userID).first() {
            viewer.$user.id = nil
            try await viewer.save(on: db)
        }
    }
}
