@testable import WishlistAPI
import Foundation
import Testing

@Suite("Planning metadata")
struct PlanningMetadataTests {
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
