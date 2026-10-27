@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Claimed item deletion alerts", .serialized)
struct ItemDeletionNotificationTests {
    private func request(_ app: Application, user: User, item: UUID, list: UUID? = nil, body: [String: Any]? = nil) throws -> Request {
        let buffer = try body.map { ByteBuffer(data: try JSONSerialization.data(withJSONObject: $0)) }
        let request = Request(application: app, collectedBody: buffer, on: app.eventLoopGroup.next())
        request.auth.login(user)
        request.parameters.set("itemID", to: item.uuidString)
        if let list { request.parameters.set("wishlistID", to: list.uuidString) }
        if body != nil { request.headers.contentType = .json }
        return request
    }

    @Test("Only active signed-in claimants receive one durable alert with the reason")
    func deletionLifecycle() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let owner = User(email: "delete-owner@example.com", passwordHash: "unused")
            let claimant = User(email: "delete-claimant@example.com", passwordHash: "unused")
            let other = User(email: "delete-other@example.com", passwordHash: "unused")
            let muted = User(email: "delete-muted@example.com", passwordHash: "unused")
            for user in [owner, claimant, other, muted] { try await user.save(on: app.db) }
            let ownerID = try owner.requireID()
            let first = Wishlist(ownerUserId: ownerID, title: "Birthday")
            let second = Wishlist(ownerUserId: ownerID, title: "Holiday")
            try await first.save(on: app.db); try await second.save(on: app.db)
            let firstID = try first.requireID(), secondID = try second.requireID()
            let viewers = [
                WishlistViewer(wishlistId: firstID, userId: try claimant.requireID()),
                WishlistViewer(wishlistId: secondID, userId: try claimant.requireID()),
                WishlistViewer(wishlistId: firstID, userId: try other.requireID()),
                WishlistViewer(wishlistId: firstID, userId: try muted.requireID()),
                WishlistViewer(wishlistId: firstID, userId: ownerID),
                WishlistViewer(wishlistId: firstID) // Anonymous viewers cannot receive account activity.
            ]
            viewers[3].notificationsEnabled = false
            for viewer in viewers { try await viewer.save(on: app.db) }
            let item = WishlistItem(wishlistId: firstID, title: "Blue headphones")
            item.$inventoryOwner.id = ownerID
            try await item.save(on: app.db)
            let itemID = try item.requireID()
            for list in [firstID, secondID] { try await WishlistItemMembership(itemID: itemID, wishlistID: list).save(on: app.db) }
            for (index, viewer) in viewers.enumerated() {
                try await ItemViewerState(itemId: itemID, viewerId: viewer.requireID(), purchased: index != 2,
                    purchasedQuantity: index == 2 ? 0 : 1).save(on: app.db)
            }
            // A non-owner cannot trigger either deletion or a notification.
            do {
                _ = try await ItemInventoryController().delete(req: request(app, user: other, item: itemID))
                Issue.record("Recipient deleted an owner's item")
            } catch let error as Abort { #expect(error.status == .notFound) }
            #expect(try await ActivityNotification.query(on: app.db).count() == 0)
            // Persisted alerts roll back together with a failed deletion.
            enum Rollback: Error { case expected }
            do {
                try await app.db.transaction { db in
                    _ = try await ItemDeletionNotificationService.record(item: item, actorID: ownerID,
                        reason: .init(reason: .noLongerWanted), permanentlyDeleted: true, on: db)
                    throw Rollback.expected
                }
            } catch Rollback.expected {}
            #expect(try await ActivityNotification.query(on: app.db).count() == 0)
            _ = try await ItemInventoryController().delete(req: request(app, user: owner, item: itemID,
                body: ["reason": "already_purchased"]))
            #expect(try await WishlistItem.find(itemID, on: app.db) == nil)
            #expect(try await ItemViewerState.query(on: app.db).filter(\.$item.$id == itemID).count() == 0)
            let alerts = try await ActivityNotification.query(on: app.db).all()
            #expect(alerts.count == 1)
            #expect(alerts.first?.$user.id == claimant.id)
            #expect(alerts.first?.kind == "claimed_item_removed")
            #expect(alerts.first?.message.contains("Blue headphones") == true)
            #expect(alerts.first?.message.contains("Already purchased") == true)
            #expect(alerts.first?.$wishlist.id == nil)
            // Repeating a DELETE cannot create another alert.
            do {
                _ = try await ItemInventoryController().delete(req: request(app, user: owner, item: itemID))
                Issue.record("Repeated deletion succeeded")
            } catch let error as Abort { #expect(error.status == .notFound) }
            #expect(try await ActivityNotification.query(on: app.db).count() == 1)

            let linked = WishlistItem(wishlistId: firstID, title: "Coffee grinder")
            linked.$inventoryOwner.id = ownerID
            try await linked.save(on: app.db)
            let linkedID = try linked.requireID()
            for list in [firstID, secondID] { try await WishlistItemMembership(itemID: linkedID, wishlistID: list).save(on: app.db) }
            try await ItemViewerState(itemId: linkedID, viewerId: viewers[0].requireID(), purchased: true, purchasedQuantity: 1).save(on: app.db)
            // Removing from one of several lists is not reported as deletion.
            _ = try await WishlistItemController().delete(req: request(app, user: owner, item: linkedID, list: firstID))
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$kind == "claimed_item_removed").count() == 1)
            try await SocialWishlistAccess(wishlistID: secondID, userID: claimant.requireID(), viewerID: viewers[1].requireID()).save(on: app.db)
            _ = try await WishlistItemController().delete(req: request(app, user: owner, item: linkedID, list: secondID,
                body: ["reason": "other", "note": "Choosing a quieter model"]))
            let removal = try await ActivityNotification.query(on: app.db).filter(\.$user.$id == claimant.requireID())
                .sort(\.$createdAt, .descending).first()
            #expect(removal?.message.contains("removed from all wishlists") == true)
            #expect(removal?.message.contains("Choosing a quieter model") == true)
            #expect(try await ActivityNotification.query(on: app.db).count() == 2)
            #expect(try await WishlistItem.find(linkedID, on: app.db) != nil)
            // Unsupported reasons must fail before changing the item or activity.
            do {
                _ = try await ItemInventoryController().delete(req: request(app, user: owner, item: linkedID, body: ["reason": "invalid"]))
                Issue.record("Invalid deletion reason was accepted")
            } catch { #expect(try await WishlistItem.find(linkedID, on: app.db) != nil) }
            _ = try await ItemInventoryController().delete(req: request(app, user: owner, item: linkedID))
            #expect(try await ActivityNotification.query(on: app.db).count() == 2)
            // Moving an item to No list also notifies, and later permanent deletion does not repeat it.
            let lamp = WishlistItem(wishlistId: firstID, title: "Desk lamp")
            lamp.$inventoryOwner.id = ownerID
            try await lamp.save(on: app.db)
            let lampID = try lamp.requireID()
            try await WishlistItemMembership(itemID: lampID, wishlistID: firstID).save(on: app.db)
            try await ItemViewerState(itemId: lampID, viewerId: viewers[0].requireID(), purchased: true, purchasedQuantity: 1).save(on: app.db)
            _ = try await ItemInventoryController().updateLinks(req: request(app, user: owner, item: lampID, body: ["wishlistIDs": []]))
            #expect(try await ActivityNotification.query(on: app.db).count() == 3)
            _ = try await ItemInventoryController().delete(req: request(app, user: owner, item: lampID, body: [:]))
            #expect(try await ActivityNotification.query(on: app.db).count() == 3)
            for user in [owner, claimant, other, muted] { try await user.delete(on: app.db) }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
