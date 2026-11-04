import Fluent
import Vapor

struct GiftRecipient: Content, Equatable {
    var userID: UUID?
    var name: String
}

/// Separate from Wishlist so public/share serializers cannot expose recipient tags.
final class WishlistGiftRecipients: Model, @unchecked Sendable {
    static let schema = "wishlist_gift_recipients"
    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Field(key: "recipients") var recipients: [GiftRecipient]
    init() {}
    init(wishlistID: UUID, recipients: [GiftRecipient]) {
        self.$wishlist.id = wishlistID
        self.recipients = recipients
    }
}

struct CommentReactionSummary: Content {
    let emoji: String
    let count: Int
    let isMine: Bool
}

final class CommentReaction: Model, @unchecked Sendable {
    static let schema = "comment_reactions"
    @ID(key: .id) var id: UUID?
    @Parent(key: "viewer_id") var viewer: WishlistViewer
    @OptionalParent(key: "note_id") var note: ItemViewerState?
    @OptionalParent(key: "comment_id") var comment: WishlistDiscussionComment?
    @Field(key: "emoji") var emoji: String
    init() {}
    init(viewerID: UUID, noteID: UUID?, commentID: UUID?, emoji: String) {
        self.$viewer.id = viewerID
        self.$note.id = noteID
        self.$comment.id = commentID
        self.emoji = emoji
    }
}
