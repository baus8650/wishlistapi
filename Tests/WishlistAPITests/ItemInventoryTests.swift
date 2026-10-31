@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Item inventory lifecycle", .serialized)
struct ItemInventoryTests {
    private func request(_ app: Application, user: User, itemID: UUID? = nil, body: [String: Any]? = nil) throws -> Request {
        let buffer = try body.map { ByteBuffer(data: try JSONSerialization.data(withJSONObject: $0)) }
        let req = Request(application: app, collectedBody: buffer, on: app.eventLoopGroup.next())
        req.auth.login(user)
        if let itemID { req.parameters.set("itemID", to: itemID.uuidString) }
        if body != nil { req.headers.contentType = .json }
        return req
    }

    @Test("An item appears once, survives its last list, supports reuse, and excludes unauthorized users")
    func lifecycle() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let owner = User(email: "inventory-owner@example.com", passwordHash: "unused")
            let stranger = User(email: "inventory-stranger@example.com", passwordHash: "unused")
            try await owner.save(on: app.db); try await stranger.save(on: app.db)
            let ownerID = try owner.requireID()
            let first = Wishlist(ownerUserId: ownerID, title: "Birthday")
            let second = Wishlist(ownerUserId: ownerID, title: "Holiday")
            try await first.save(on: app.db); try await second.save(on: app.db)
            let firstID = try first.requireID(), secondID = try second.requireID()
            // Exercise the migration with an existing item before its inventory owner is backfilled.
            let legacy = WishlistItem(wishlistId: firstID, title: "Legacy item")
            try await legacy.save(on: app.db)
            try await AddItemInventory().revert(on: app.db)
            try await AddItemInventory().prepare(on: app.db)
            let backfilled = try await WishlistItem.find(legacy.requireID(), on: app.db)
            #expect(backfilled?.$inventoryOwner.id == ownerID)
            try await legacy.delete(on: app.db)
            let controller = ItemInventoryController()
            let created = try await controller.create(req: request(app, user: owner, body: [
                "title": "One shared item", "price": 100, "quantity": 2, "currencyCode": "COP",
                "linkedWishlistIDs": [firstID.uuidString, secondID.uuidString]
            ]))
            #expect(created.currencyCode == "COP")
            let itemID = try created.requireID()
            let initial = try await controller.index(req: request(app, user: owner))
            #expect(initial.count == 1)
            #expect(Set(initial[0].wishlistIDs) == [firstID, secondID])
            #expect(try await controller.index(req: request(app, user: stranger)).isEmpty)
            do {
                _ = try await controller.update(req: request(app, user: stranger, itemID: itemID, body: ["title": "Unauthorized"]))
                Issue.record("Stranger edited an inventory item")
            } catch let error as Abort { #expect(error.status == .notFound) }
            // Reject a forged destination without changing either item or memberships.
            let privateList = Wishlist(ownerUserId: try stranger.requireID(), title: "Stranger's list")
            try await privateList.save(on: app.db)
            do {
                _ = try await controller.update(req: request(app, user: owner, itemID: itemID, body: [
                    "title": "Should roll back", "linkedWishlistIDs": [privateList.requireID().uuidString]
                ]))
                Issue.record("Unauthorized destination was accepted")
            } catch let error as Abort { #expect(error.status == .forbidden) }
            #expect(try await WishlistItem.find(itemID, on: app.db)?.title == "One shared item")
            // Memberships outside the editor's lists remain untouched and disable global deletion.
            let foreign = WishlistItemMembership(itemID: itemID, wishlistID: try privateList.requireID())
            try await foreign.save(on: app.db)
            let limited = try await controller.index(req: request(app, user: owner))
            #expect(limited[0].otherListCount == 1)
            #expect(!limited[0].canDelete)
            _ = try await controller.updateLinks(req: request(app, user: owner, itemID: itemID, body: ["wishlistIDs": [firstID.uuidString]]))
            #expect(try await WishlistItemMembership.find(foreign.requireID(), on: app.db) != nil)
            do {
                _ = try await controller.delete(req: request(app, user: owner, itemID: itemID))
                Issue.record("Deleted an item from an inaccessible list")
            } catch let error as Abort { #expect(error.status == .forbidden) }
            try await foreign.delete(on: app.db)
            // Lists-only changes preserve the item's details and sale.
            _ = try await controller.sale(req: request(app, user: owner, itemID: itemID, body: ["salePrice": 75]))
            _ = try await controller.updateLinks(req: request(app, user: owner, itemID: itemID, body: ["wishlistIDs": []]))
            let unlisted = try await controller.index(req: request(app, user: owner))
            #expect(unlisted.count == 1)
            #expect(unlisted[0].wishlistIDs.isEmpty)
            #expect(unlisted[0].item.salePrice == 75)
            #expect(unlisted[0].item.currencyCode == "COP")
            #expect(unlisted[0].item.$wishlist.id == nil)
            _ = try await controller.update(req: request(app, user: owner, itemID: itemID, body: [
                "title": "Retained and edited", "price": 100, "quantity": 2, "salePrice": 75, "currencyCode": "", "linkedWishlistIDs": []
            ]))
            #expect(try await WishlistItem.find(itemID, on: app.db)?.currencyCode == nil)
            _ = try await controller.updateLinks(req: request(app, user: owner, itemID: itemID, body: ["wishlistIDs": [secondID.uuidString]]))
            #expect(try await WishlistItemMembership.query(on: app.db).filter(\.$item.$id == itemID).count() == 1)
            // Retained photos remain visible to the inventory owner, but not strangers.
            let upload = Request(application: app, collectedBody: ByteBuffer(bytes: [137, 80, 78, 71]), on: app.eventLoopGroup.next())
            upload.auth.login(owner)
            upload.parameters.set("itemID", to: itemID.uuidString)
            upload.headers.contentType = .png
            _ = try await controller.uploadImage(req: upload)
            _ = try await controller.updateLinks(req: request(app, user: owner, itemID: itemID, body: ["wishlistIDs": []]))
            #expect(try await WishlistItemImageController().show(req: request(app, user: owner, itemID: itemID)).status == .ok)
            do {
                _ = try await WishlistItemImageController().show(req: request(app, user: stranger, itemID: itemID))
                Issue.record("Stranger viewed a private retained photo")
            } catch let error as Abort { #expect(error.status == .notFound) }
            #expect(try await WishlistItem.find(itemID, on: app.db)?.currencyCode == nil)
            _ = try await controller.updateLinks(req: request(app, user: owner, itemID: itemID, body: ["wishlistIDs": [secondID.uuidString]]))
            // Removing the last list through the existing list API also retains it.
            let remove = try request(app, user: owner, itemID: itemID)
            remove.parameters.set("wishlistID", to: secondID.uuidString)
            _ = try await WishlistItemController().delete(req: remove)
            #expect(try await WishlistItem.find(itemID, on: app.db) != nil)
            #expect(try await controller.index(req: request(app, user: owner))[0].wishlistIDs.isEmpty)
            _ = try await controller.delete(req: request(app, user: owner, itemID: itemID))
            #expect(try await WishlistItem.find(itemID, on: app.db) == nil)
            // New inventory entries can start with no lists at all.
            let loose = try await controller.create(req: request(app, user: owner, body: ["title": "For later", "linkedWishlistIDs": []]))
            #expect(loose.$wishlist.id == nil)
            _ = try await controller.delete(req: request(app, user: owner, itemID: loose.requireID()))
            // Deleting a whole list retains its items too.
            let retained = try await controller.create(req: request(app, user: owner, body: ["title": "Keep after list deletion", "linkedWishlistIDs": [firstID.uuidString]]))
            let deleteList = try request(app, user: owner)
            deleteList.parameters.set("wishlistID", to: firstID.uuidString)
            _ = try await WishlistController().delete(req: deleteList)
            #expect(try await WishlistItem.find(retained.requireID(), on: app.db) != nil)
            #expect(try await controller.index(req: request(app, user: owner))[0].wishlistIDs.isEmpty)
            _ = try await controller.delete(req: request(app, user: owner, itemID: retained.requireID()))
            try await owner.delete(on: app.db); try await stranger.delete(on: app.db)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
