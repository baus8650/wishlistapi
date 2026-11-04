@testable import WishlistAPI
import Foundation
import Testing
@testable import PostgresKit
import PostgresNIO

@Suite("Planning metadata")
struct PlanningMetadataTests {
    @Test("Recipient storage binds as JSONB for typed names, accounts, and empty lists")
    func recipientStorageBinding() throws {
        let name = GiftRecipient(userID: nil, name: "Grandma")
        let account = GiftRecipient(userID: UUID(), name: "A friend")
        for recipients in [[], [name], [account], [name, account]] {
            let record = WishlistGiftRecipients(wishlistID: UUID(), recipients: recipients)
            var bindings = PostgresBindings()
            try PostgresDataTranslation.encode(value: record.recipientDocument, in: .default, to: &bindings)
            #expect(bindings.debugDescription.contains("JSONB;"))
            #expect(!bindings.debugDescription.contains("JSONB[]"))
            let encoded = try JSONEncoder().encode(record.recipientDocument)
            let decoded = try JSONDecoder().decode(GiftRecipientDocument.self, from: encoded)
            #expect(decoded.recipients == recipients)
            // Previously stored JSON arrays remain readable without a data migration.
            let legacy = try JSONEncoder().encode(recipients)
            #expect(try JSONDecoder().decode(GiftRecipientDocument.self, from: legacy).recipients == recipients)
        }
    }

    @Test("Reactions count each viewer and identify only the current viewer's selection")
    func reactionSummaries() {
        let mine = UUID(), other = UUID(), note = UUID()
        let rows = [
            CommentReaction(viewerID: mine, noteID: note, commentID: nil, emoji: "❤️"),
            CommentReaction(viewerID: other, noteID: note, commentID: nil, emoji: "❤️"),
            CommentReaction(viewerID: other, noteID: note, commentID: nil, emoji: "👍")
        ]
        let summary = CommentReactionService.summaries(rows, viewerID: mine)
        #expect(summary.count == 2)
        #expect(summary.first { $0.emoji == "❤️" }?.count == 2)
        #expect(summary.first { $0.emoji == "❤️" }?.isMine == true)
        #expect(summary.first { $0.emoji == "👍" }?.isMine == false)
        #expect(CommentReactionService.summaries([], viewerID: mine).isEmpty)
    }

    @Test("Public wishlist payloads have no recipient tags or account IDs")
    func publicRecipientPrivacy() throws {
        let list = RecipientShareController.SharedWishlistPublic(id: UUID(), title: "Holiday gifts", sharedByName: "Planner")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as! [String: Any]
        #expect(json["giftRecipients"] == nil)
        #expect(json["recipients"] == nil)
        #expect(json["userID"] == nil)
    }
}
