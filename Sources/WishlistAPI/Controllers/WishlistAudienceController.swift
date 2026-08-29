import Fluent
import Vapor

struct WishlistAudienceController: RouteCollection {
    struct Audience: Content { let userIDs: [UUID]; let groupIDs: [UUID] }

    func boot(routes: any RoutesBuilder) throws {
        routes.get(":wishlistID", "audience", use: get)
        routes.put(":wishlistID", "audience", use: update)
    }

    func get(req: Request) async throws -> Audience {
        let wishlist = try await ownedWishlist(req)
        let grants = try await WishlistAudienceGrant.query(on: req.db).filter(\.$wishlist.$id == wishlist.requireID()).all()
        return Audience(userIDs: grants.compactMap(\.$user.id), groupIDs: grants.compactMap(\.$group.id))
    }

    func update(req: Request) async throws -> Audience {
        let ownerID = try req.auth.require(User.self).requireID(), wishlist = try await ownedWishlist(req), wishlistID = try wishlist.requireID()
        let body = try req.content.decode(Audience.self)
        let userIDs = Array(Set(body.userIDs)), groupIDs = Array(Set(body.groupIDs))
        for userID in userIDs {
            guard let friendship = try await acceptedFriendship(ownerID, userID, on: req.db), friendship.status == "accepted" else { throw Abort(.forbidden, reason: "Wishlists can only be shared directly with friends.") }
        }
        for groupID in groupIDs {
            guard try await FriendGroup.query(on: req.db).filter(\.$id == groupID).filter(\.$owner.$id == ownerID).first() != nil else { throw Abort(.notFound, reason: "Friend group not found.") }
        }
        try await WishlistAudienceGrant.query(on: req.db).filter(\.$wishlist.$id == wishlistID).delete()
        for id in userIDs { try await WishlistAudienceGrant(wishlistID: wishlistID, userID: id).save(on: req.db) }
        for id in groupIDs { try await WishlistAudienceGrant(wishlistID: wishlistID, groupID: id).save(on: req.db) }
        try await AudienceService.sync(wishlistID: wishlistID, on: req.db)
        return Audience(userIDs: userIDs, groupIDs: groupIDs)
    }

    private func ownedWishlist(_ req: Request) async throws -> Wishlist {
        let ownerID = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self), let wishlist = try await Wishlist.query(on: req.db).filter(\.$id == wishlistID).filter(\.$owner.$id == ownerID).first() else { throw Abort(.notFound) }
        return wishlist
    }

    private func acceptedFriendship(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Friendship? {
        if let row = try await Friendship.query(on: db).filter(\.$requester.$id == first).filter(\.$recipient.$id == second).filter(\.$status == "accepted").first() { return row }
        return try await Friendship.query(on: db).filter(\.$requester.$id == second).filter(\.$recipient.$id == first).filter(\.$status == "accepted").first()
    }
}

enum AudienceService {
    static func syncAllOwnedWishlists(ownerID: UUID, on db: any Database) async throws {
        for wishlist in try await Wishlist.query(on: db).filter(\.$owner.$id == ownerID).all() { try await sync(wishlistID: wishlist.requireID(), on: db) }
    }

    static func syncGrants(forGroup groupID: UUID, on db: any Database) async throws {
        let ids = Set(try await WishlistAudienceGrant.query(on: db).filter(\.$group.$id == groupID).all().map(\.$wishlist.id))
        for id in ids { try await sync(wishlistID: id, on: db) }
    }

    static func sync(wishlistID: UUID, on db: any Database) async throws {
        let grants = try await WishlistAudienceGrant.query(on: db).filter(\.$wishlist.$id == wishlistID).all()
        var desired = Set(grants.compactMap(\.$user.id))
        for groupID in grants.compactMap(\.$group.id) {
            desired.formUnion(try await FriendGroupMember.query(on: db).filter(\.$group.$id == groupID).all().map(\.$user.id))
        }
        let existing = try await SocialWishlistAccess.query(on: db).filter(\.$wishlist.$id == wishlistID).all()
        for access in existing where !desired.contains(access.$user.id) {
            if let viewer = try await WishlistViewer.find(access.$viewer.id, on: db) { try await viewer.delete(on: db) }
        }
        let existingIDs = Set(existing.map(\.$user.id))
        for userID in desired.subtracting(existingIDs) {
            let viewer = WishlistViewer(wishlistId: wishlistID, userId: userID)
            try await viewer.save(on: db)
            try await SocialWishlistAccess(wishlistID: wishlistID, userID: userID, viewerID: viewer.requireID()).save(on: db)
        }
    }
}
