@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Private planning metadata access", .serialized)
struct PlanningMetadataAccessTests {
    @Test("Recipient selection stays creator-only and grants no access or notifications")
    func recipientsStayPrivate() async throws {
        let app = try await Application.make(.testing)
        var users: [User] = []
        do {
            try await configure(app)
            try await app.autoMigrate()
            let owner = User(email: "metadata-owner-\(UUID())@example.com", passwordHash: "unused")
            let recipient = User(email: "metadata-recipient-\(UUID())@example.com", passwordHash: "unused")
            let coOwner = User(email: "metadata-coowner-\(UUID())@example.com", passwordHash: "unused")
            users = [owner, recipient, coOwner]
            for user in users { try await user.save(on: app.db) }
            let list = Wishlist(ownerUserId: try owner.requireID(), title: "Private gift plans")
            list.purpose = "for_myself"
            try await list.save(on: app.db)
            try await WishlistCollaborator(wishlistID: list.requireID(), userID: coOwner.requireID()).save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(owner)
            req.parameters.set("wishlistID", to: try list.requireID().uuidString)
            try req.content.encode(GiftRecipientsController.Body(recipients: [
                .init(userID: recipient.requireID(), name: "Selected person"),
                .init(userID: nil, name: "  Grandma  "), .init(userID: nil, name: "grandma")
            ]))
            // Neither strangers nor pending requests can be selected as accounts.
            for pending in [false, true] {
                if pending {
                    try await Friendship(requesterID: recipient.requireID(), recipientID: owner.requireID(), status: "pending").save(on: app.db)
                }
                do {
                    _ = try await GiftRecipientsController().update(req: req)
                    Issue.record("A non-friend was selected as an account recipient")
                } catch let error as Abort { #expect(error.status == .forbidden) }
            }
            // Accepted friendships work in either direction; free-text names still work.
            let friendship = try #require(try await Friendship.query(on: app.db)
                .filter(\.$requester.$id == recipient.requireID()).filter(\.$recipient.$id == owner.requireID()).first())
            friendship.status = "accepted"
            try await friendship.save(on: app.db)
            let saved = try await GiftRecipientsController().update(req: req)
            #expect(saved.count == 2)
            #expect(saved.last?.name == "Grandma")
            let lists = try await WishlistController().index(req: req)
            #expect(lists.first { $0.id == list.id }?.giftRecipients?.count == 2)
            #expect(try await SocialWishlistAccess.query(on: app.db).filter(\.$wishlist.$id == list.requireID()).count() == 0)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == recipient.requireID()).count() == 0)
            for user in [recipient, coOwner] {
                req.auth.login(user)
                do {
                    _ = try await GiftRecipientsController().list(req: req)
                    Issue.record("Recipient tags were exposed to another account")
                } catch let error as Abort { #expect(error.status == .notFound) }
                let visible = try await WishlistController().index(req: req)
                #expect(visible.first { $0.id == list.id }?.giftRecipients == nil)
            }
            for user in users { try await user.delete(on: app.db) }
        } catch {
            for user in users { try? await user.delete(on: app.db) }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Note reactions are idempotent and cannot target another list")
    func reactionIsolation() async throws {
        let app = try await Application.make(.testing)
        let owner = User(email: "reaction-owner-\(UUID())@example.com", passwordHash: "unused")
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await owner.save(on: app.db)
            let lists = [Wishlist(ownerUserId: try owner.requireID(), title: "First"), Wishlist(ownerUserId: try owner.requireID(), title: "Second")]
            var notes: [ItemViewerState] = []
            for list in lists {
                list.collaborationMode = "gift_planning"
                try await list.save(on: app.db)
                let item = WishlistItem(wishlistId: try list.requireID(), title: "Gift")
                try await item.save(on: app.db)
                try await WishlistItemMembership(itemID: item.requireID(), wishlistID: list.requireID()).save(on: app.db)
                let viewer = WishlistViewer(wishlistId: try list.requireID(), userId: try owner.requireID())
                try await viewer.save(on: app.db)
                let note = ItemViewerState(itemId: try item.requireID(), viewerId: try viewer.requireID(), purchased: false, note: "A comment")
                try await note.save(on: app.db)
                notes.append(note)
            }
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(owner)
            req.parameters.set("wishlistID", to: try lists[0].requireID().uuidString)
            req.parameters.set("reactionTargetID", to: try notes[0].requireID().uuidString)
            try req.content.encode(CommentReactionService.Update(emoji: "❤️", selected: true))
            for _ in 0..<2 {
                let result = try await GiftPlanningController().reactToNote(req: req)
                #expect(result.first?.count == 1)
                #expect(result.first?.isMine == true)
            }
            req.parameters.set("reactionTargetID", to: try notes[1].requireID().uuidString)
            do {
                _ = try await GiftPlanningController().reactToNote(req: req)
                Issue.record("Cross-list note reaction accepted")
            } catch let error as Abort { #expect(error.status == .notFound) }
            req.parameters.set("reactionTargetID", to: try notes[0].requireID().uuidString)
            try req.content.encode(CommentReactionService.Update(emoji: "❤️", selected: false))
            #expect(try await GiftPlanningController().reactToNote(req: req).isEmpty)
            try await owner.delete(on: app.db)
        } catch {
            try? await owner.delete(on: app.db)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
