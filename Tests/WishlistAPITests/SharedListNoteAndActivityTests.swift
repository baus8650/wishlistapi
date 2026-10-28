@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Shared list notes and item notification targets", .serialized)
struct SharedListNoteAndActivityTests {
    @Test func sharedNoteAndActivityTargetRoundTrip() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let owner = User(email: "note-owner-\(UUID())@example.com", passwordHash: "unused")
            let recipient = User(email: "note-recipient-\(UUID())@example.com", passwordHash: "unused")
            try await owner.save(on: app.db)
            try await recipient.save(on: app.db)
            let wishlist = Wishlist(ownerUserId: try owner.requireID(), title: "Birthday")
            wishlist.descriptionText = "Please check sizes before ordering."
            try await wishlist.save(on: app.db)
            let viewer = WishlistViewer(wishlistId: try wishlist.requireID(), userId: try recipient.requireID())
            try await viewer.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(recipient)
            req.parameters.set("accountShareID", to: try viewer.requireID().uuidString)
            let shared = try await AccountShareController().settings(req: req)
            #expect(shared.description == wishlist.descriptionText)

            wishlist.descriptionText = nil
            try await wishlist.save(on: app.db)
            let cleared = try await AccountShareController().settings(req: req)
            #expect(cleared.description == nil)

            let itemID = UUID()
            try await ActivityService.create(userID: recipient.requireID(), actorID: owner.requireID(),
                wishlistID: wishlist.requireID(), itemID: itemID, kind: "wishlist_updated",
                title: "Updated", message: "An item changed", on: app.db)
            let activity = try await ActivityController().list(req: req)
            #expect(activity.count == 1)
            #expect(activity.first?.itemID == itemID)
            #expect(activity.first?.wishlistID == wishlist.id)
            // Older, list-only activity remains valid after the additive migration.
            try await ActivityService.create(userID: recipient.requireID(), wishlistID: wishlist.requireID(),
                kind: "wishlist_updated", title: "List updated", message: "A list changed", on: app.db)
            let all = try await ActivityController().list(req: req)
            #expect(all.count == 2)
            #expect(all.contains { $0.itemID == nil })
            try await recipient.delete(on: app.db)
            try await owner.delete(on: app.db)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
