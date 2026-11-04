@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Comment reaction notifications", .serialized)
struct CommentReactionNotificationTests {
    @Test("Only the author is notified; retries, removals, self-reactions, blocks and muted lists stay quiet")
    func lifecycle() async throws {
        let app = try await Application.make(.testing)
        var users: [User] = []
        do {
            try await configure(app)
            try await app.autoMigrate()
            users = (0..<4).map { User(email: "reaction-notify-\($0)-\(UUID())@example.com", passwordHash: "unused") }
            for user in users { try await user.save(on: app.db) }
            let owner = users[0], author = users[1], reactor = users[2], observer = users[3]
            let list = Wishlist(ownerUserId: try owner.requireID(), title: "Private plans")
            list.collaborationMode = "gift_planning"
            list.purpose = "for_myself"
            try await list.save(on: app.db)
            var viewers: [WishlistViewer] = []
            for user in users {
                let viewer = WishlistViewer(wishlistId: try list.requireID(), userId: try user.requireID())
                try await viewer.save(on: app.db)
                viewers.append(viewer)
            }
            let guest = WishlistViewer(wishlistId: try list.requireID())
            try await guest.save(on: app.db)
            let item = WishlistItem(wishlistId: try list.requireID(), title: "Surprise item")
            try await item.save(on: app.db)
            try await WishlistItemMembership(itemID: item.requireID(), wishlistID: list.requireID()).save(on: app.db)
            let note = ItemViewerState(itemId: try item.requireID(), viewerId: try viewers[1].requireID(), purchased: false, note: "Secret comment text")
            try await note.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.parameters.set("reactionTargetID", to: try note.requireID().uuidString)
            func react(_ viewer: WishlistViewer, _ emoji: String, _ selected: Bool = true, kind: String = "note") async throws {
                try req.content.encode(CommentReactionService.Update(emoji: emoji, selected: selected))
                _ = try await CommentReactionService.update(req: req, wishlist: list, viewer: viewer, kind: kind)
            }
            func count(_ user: User) async throws -> Int {
                try await ActivityNotification.query(on: app.db).filter(\.$user.$id == user.requireID()).filter(\.$kind == "comment_reaction").count()
            }
            try await react(viewers[2], "❤️")
            #expect(try await count(author) == 1)
            #expect(try await count(owner) == 0)
            #expect(try await count(reactor) == 0)
            #expect(try await count(observer) == 0)
            let notification = try #require(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == author.requireID()).first())
            #expect(notification.itemID == item.id)
            #expect(notification.$wishlist.id == list.id)
            #expect(notification.message.contains("❤️"))
            #expect(!notification.message.contains("Secret comment"))
            #expect(notification.$actor.id == nil)
            try await react(viewers[2], "❤️") // Idempotent retry.
            try await react(viewers[2], "❤️", false)
            try await react(viewers[1], "👍") // Self-reaction.
            #expect(try await count(author) == 1)
            viewers[1].notificationsEnabled = false
            try await viewers[1].save(on: app.db)
            try await react(viewers[2], "🦦")
            #expect(try await count(author) == 1)
            viewers[1].notificationsEnabled = true
            try await viewers[1].save(on: app.db)
            let block = UserBlock(blockerID: try author.requireID(), blockedID: try reactor.requireID())
            try await block.save(on: app.db)
            try await react(viewers[2], "👀")
            #expect(try await count(author) == 1)
            try await block.delete(on: app.db)
            try await react(guest, "🎉")
            #expect(try await count(author) == 2)
            let guestNote = ItemViewerState(itemId: try item.requireID(), viewerId: try guest.requireID(), purchased: false, note: "Anonymous comment")
            try await guestNote.save(on: app.db)
            req.parameters.set("reactionTargetID", to: try guestNote.requireID().uuidString)
            try await react(viewers[2], "👍") // Unlinked guest authors have no account to notify.
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$kind == "comment_reaction").count() == 2)

            let comment = WishlistDiscussionComment(wishlistID: try list.requireID(), viewerID: try viewers[0].requireID(), message: "List discussion", shareName: true)
            try await comment.save(on: app.db)
            req.parameters.set("reactionTargetID", to: try comment.requireID().uuidString)
            try await react(viewers[2], "🎉", kind: "comment")
            #expect(try await count(owner) == 1)
            let general = try #require(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == owner.requireID()).first())
            #expect(general.itemID == nil)
            list.collaborationMode = "our_wishlist"
            list.purpose = "for_others"
            try await list.save(on: app.db)
            try await react(viewers[2], "👀", kind: "comment")
            #expect(try await count(owner) == 1) // No planning spoilers after changing list purpose.
            for user in users { try await user.delete(on: app.db) }
        } catch {
            for user in users { try? await user.delete(on: app.db) }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
