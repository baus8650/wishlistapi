import Fluent
import Vapor

enum WishlistPermissionService {
    static func canEdit(wishlistID: UUID, userID: UUID, on db: any Database) async throws -> Bool {
        if try await Wishlist.query(on: db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userID)
            .first() != nil { return true }
        return try await WishlistCollaborator.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == userID)
            .first() != nil
    }

    static func editableWishlist(req: Request) async throws -> Wishlist {
        let userID = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await canEdit(wishlistID: wishlistID, userID: userID, on: req.db) else {
            throw Abort(.notFound)
        }
        return wishlist
    }
}
