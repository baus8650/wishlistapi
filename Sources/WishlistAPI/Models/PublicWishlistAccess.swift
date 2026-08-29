import Fluent
import Foundation

final class PublicWishlistAccess: Model, @unchecked Sendable {
    static let schema = "public_wishlist_access"

    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Parent(key: "user_id") var user: User
    @Parent(key: "viewer_id") var viewer: WishlistViewer

    init() {}
    init(wishlistID: UUID, userID: UUID, viewerID: UUID) {
        self.$wishlist.id = wishlistID
        self.$user.id = userID
        self.$viewer.id = viewerID
    }
}
