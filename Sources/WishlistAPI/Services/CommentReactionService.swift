import Fluent
import SQLKit
import Vapor

enum CommentReactionService {
    struct Update: Content { let emoji: String; let selected: Bool }

    static func summaries(_ rows: [CommentReaction], viewerID: UUID) -> [CommentReactionSummary] {
        let groups = Dictionary(grouping: rows, by: \.emoji)
        return groups.keys.sorted().map { emoji in
            let matches = groups[emoji] ?? []
            return .init(emoji: emoji, count: matches.count, isMine: matches.contains { $0.$viewer.id == viewerID })
        }
    }

    static func update(req: Request, wishlist: Wishlist, viewer: WishlistViewer, kind: String) async throws -> [CommentReactionSummary] {
        let body = try req.content.decode(Update.self)
        guard ReactionEmoji.isValid(body.emoji), let id = req.parameters.get("reactionTargetID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Choose a single emoji for your reaction.")
        }
        let viewerID = try viewer.requireID()
        try await AuthRateLimitService.enforce(req, scope: "comment-reaction:\(viewerID)", limit: 240, window: 3600)
        let authorViewerID: UUID
        let itemID: UUID?
        if kind == "note" {
            guard wishlist.allowNotes, let note = try await ItemViewerState.find(id, on: req.db),
                  let author = try await WishlistViewer.find(note.$viewer.id, on: req.db),
                  author.$wishlist.id == wishlist.id,
                  !(note.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  try await WishlistItemMembership.query(on: req.db)
                    .filter(\.$wishlist.$id == wishlist.requireID()).filter(\.$item.$id == note.$item.id).first() != nil else { throw Abort(.notFound) }
            authorViewerID = note.$viewer.id
            itemID = note.$item.id
        } else {
            guard let comment = try await WishlistDiscussionComment.find(id, on: req.db),
                  comment.$wishlist.id == wishlist.id else { throw Abort(.notFound) }
            authorViewerID = comment.$viewer.id
            itemID = nil
        }
        let (result, notification) = try await req.db.transaction { db -> ([CommentReactionSummary], ActivityNotification?) in
            // Serialize a viewer's changes so repeated taps and retries cannot create duplicate reactions.
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM wishlist_viewers WHERE id = \(bind: viewerID) FOR UPDATE").run()
            let query = CommentReaction.query(on: db).filter(\.$viewer.$id == viewerID).filter(\.$emoji == body.emoji)
            if kind == "note" { query.filter(\.$note.$id == id) } else { query.filter(\.$comment.$id == id) }
            let existing = try await query.first()
            var notification: ActivityNotification?
            if body.selected, existing == nil {
                try await CommentReaction(viewerID: viewerID, noteID: kind == "note" ? id : nil,
                    commentID: kind == "note" ? nil : id, emoji: body.emoji).save(on: db)
                notification = try await CommentReactionNotificationService.record(wishlist: wishlist,
                    authorViewerID: authorViewerID, actor: viewer, emoji: body.emoji, itemID: itemID, on: db)
            } else if !body.selected, let existing { try await existing.delete(on: db) }
            let all = CommentReaction.query(on: db)
            if kind == "note" { all.filter(\.$note.$id == id) } else { all.filter(\.$comment.$id == id) }
            return (summaries(try await all.all(), viewerID: viewerID), notification)
        }
        if let notification {
            await ActivityService.sendPush(notification, on: req.db, client: req.client, logger: req.logger)
        }
        return result
    }
}
