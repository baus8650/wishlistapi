import Fluent
import Vapor

struct GiftRecipient: Content, Equatable {
    var userID: UUID?
    var name: String
}

/// A keyed document forces the SQL driver to bind JSONB rather than a native
/// PostgreSQL array of JSONB values. Accept the original array format on reads.
struct GiftRecipientDocument: Codable {
    var recipients: [GiftRecipient]

    init(recipients: [GiftRecipient]) { self.recipients = recipients }

    private enum CodingKeys: String, CodingKey { case recipients }

    init(from decoder: any Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode([GiftRecipient].self) {
            recipients = legacy
        } else {
            recipients = try decoder.container(keyedBy: CodingKeys.self).decode([GiftRecipient].self, forKey: .recipients)
        }
    }
}

/// Separate from Wishlist so public/share serializers cannot expose recipient tags.
final class WishlistGiftRecipients: Model, @unchecked Sendable {
    static let schema = "wishlist_gift_recipients"
    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Field(key: "recipients") var recipientDocument: GiftRecipientDocument
    var recipients: [GiftRecipient] {
        get { recipientDocument.recipients }
        set { recipientDocument = .init(recipients: newValue) }
    }
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
