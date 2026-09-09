import Fluent
import Vapor

enum WishlistPermissionService {
    static func canEdit(wishlistID: UUID, userID: UUID, on db: any Database) async throws -> Bool {
        guard let wishlist = try await Wishlist.find(wishlistID, on: db),
              let user = try await User.find(userID, on: db) else { return false }
        if wishlist.$owner.id == userID {
            return !wishlist.matureContentEnabled || user.derivedAgeBand == "adult"
        }
        guard try await WishlistCollaborator.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == userID)
            .first() != nil else { return false }
        guard !wishlist.matureContentEnabled || user.derivedAgeBand == "adult" else { return false }
        return try await !ProfileAccessService.isBlocked(userID, wishlist.$owner.id, on: db)
    }

    static func editableWishlist(req: Request) async throws -> Wishlist {
        let userID = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await canEdit(wishlistID: wishlistID, userID: userID, on: req.db) else {
            throw Abort(.notFound)
        }
        if wishlist.matureContentEnabled,
           try req.auth.require(User.self).derivedAgeBand != "adult" {
            throw Abort(.forbidden, reason: "This list is not available to your account.")
        }
        return wishlist
    }
}
