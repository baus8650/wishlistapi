import Fluent
import Vapor

final class WishlistDiscussionComment: Model, Content {
    static let schema = "wishlist_discussion_comments"

    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Parent(key: "viewer_id") var viewer: WishlistViewer
    @Field(key: "message") var message: String
    @Field(key: "share_name") var shareName: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, wishlistID: UUID, viewerID: UUID, message: String, shareName: Bool) {
        self.id = id
        self.$wishlist.id = wishlistID
        self.$viewer.id = viewerID
        self.message = message
        self.shareName = shareName
    }
}

extension WishlistDiscussionComment: @unchecked Sendable {}
