import Fluent
import Vapor

final class WishlistCollaborator: Model, Content {
    static let schema = "wishlist_collaborators"

    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Parent(key: "user_id") var user: User
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(id: UUID? = nil, wishlistID: UUID, userID: UUID) {
        self.id = id
        self.$wishlist.id = wishlistID
        self.$user.id = userID
    }
}

extension WishlistCollaborator: @unchecked Sendable {}
