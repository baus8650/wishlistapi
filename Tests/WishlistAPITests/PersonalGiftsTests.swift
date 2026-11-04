@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("My Gifts", .serialized)
struct PersonalGiftsTests {
    @Test("People without any lists can record gifts; invalid inputs never save partial records")
    func standaloneValidation() async throws {
        let app = try await Application.make(.testing)
        let buyer = User(email: "standalone-gift-\(UUID())@example.com", passwordHash: "unused")
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await buyer.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(buyer)
            let controller = PersonalGiftsController()
            for values in [("", -1.0, "https://example.com", 1),
                           ("Gift", -1.0, "https://example.com", 1),
                           ("Gift", 10.0, "javascript:alert(1)", 1),
                           ("Gift", 10.0, "https://example.com", 0)] {
                try req.content.encode(PersonalGiftsController.SaveRequest(title: values.0, recipients: [], price: values.1,
                    currencyCode: "USD", url: values.2, notes: nil, quantity: values.3, purchasedAt: Date()))
                do { _ = try await controller.create(req: req); Issue.record("Invalid purchase accepted") }
                catch let error as Abort { #expect(error.status == .badRequest) }
            }
            #expect(try await PersonalGift.query(on: app.db).filter(\.$user.$id == buyer.requireID()).count() == 0)
            try req.content.encode(PersonalGiftsController.SaveRequest(title: "A gift", recipients: [.init(userID: nil, name: "Grandma")],
                price: nil, currencyCode: nil, url: nil, notes: nil, quantity: 1, purchasedAt: Date()))
            _ = try await controller.create(req: req)
            let feed = try await controller.index(req: req)
            #expect(feed.claims.isEmpty)
            #expect(feed.purchases.count == 1)
            #expect(feed.purchases.first?.recipients.first?.name == "Grandma")
            try await buyer.delete(on: app.db)
        } catch {
            try? await buyer.delete(on: app.db)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Aggregates only my claims and keeps standalone purchases private through create, edit, and delete")
    func lifecycle() async throws {
        let app = try await Application.make(.testing)
        var users: [User] = []
        do {
            try await configure(app)
            try await app.autoMigrate()
            users = (0..<3).map { User(email: "my-gifts-\($0)-\(UUID())@example.com", passwordHash: "unused") }
            for user in users { try await user.save(on: app.db) }
            let recipient = users[0], buyer = users[1], other = users[2]
            recipient.displayName = "Recipient"
            try await recipient.save(on: app.db)
            try await Friendship(requesterID: buyer.requireID(), recipientID: recipient.requireID(), status: "accepted").save(on: app.db)
            let sharedList = Wishlist(ownerUserId: try recipient.requireID(), title: "Birthday")
            sharedList.currencyCode = "EUR"
            let ownList = Wishlist(ownerUserId: try buyer.requireID(), title: "Planning")
            ownList.purpose = "for_myself"
            ownList.collaborationMode = "gift_planning"
            try await sharedList.save(on: app.db)
            try await ownList.save(on: app.db)
            try await WishlistGiftRecipients(wishlistID: ownList.requireID(), recipients: [.init(userID: nil, name: "Grandma")]).save(on: app.db)
            // These tags belong to another creator and must never enter the buyer's feed.
            try await WishlistGiftRecipients(wishlistID: sharedList.requireID(), recipients: [.init(userID: nil, name: "Private tag")]).save(on: app.db)
            let sharedViewer = WishlistViewer(wishlistId: try sharedList.requireID(), userId: try buyer.requireID())
            let ownViewer = WishlistViewer(wishlistId: try ownList.requireID(), userId: try buyer.requireID())
            let otherViewer = WishlistViewer(wishlistId: try sharedList.requireID(), userId: try other.requireID())
            for viewer in [sharedViewer, ownViewer, otherViewer] { try await viewer.save(on: app.db) }
            let first = WishlistItem(wishlistId: try sharedList.requireID(), title: "Book", price: 20, quantity: 3)
            let second = WishlistItem(wishlistId: try ownList.requireID(), title: "Tea")
            for item in [first, second] { try await item.save(on: app.db) }
            try await WishlistItemMembership(itemID: first.requireID(), wishlistID: sharedList.requireID()).save(on: app.db)
            try await WishlistItemMembership(itemID: second.requireID(), wishlistID: ownList.requireID()).save(on: app.db)
            let mine = ItemViewerState(itemId: try first.requireID(), viewerId: try sharedViewer.requireID(), purchased: true, purchasedQuantity: 2)
            try await mine.save(on: app.db)
            try await ItemViewerState(itemId: second.requireID(), viewerId: ownViewer.requireID(), purchased: true, purchasedQuantity: 1).save(on: app.db)
            try await ItemViewerState(itemId: first.requireID(), viewerId: otherViewer.requireID(), purchased: true, purchasedQuantity: 1).save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(buyer)
            let controller = PersonalGiftsController()
            let feed = try await controller.index(req: req)
            #expect(feed.claims.count == 2)
            let shared = try #require(feed.claims.first { $0.itemID == first.id })
            #expect(shared.quantity == 2)
            #expect(shared.currencyCode == "EUR")
            #expect(shared.recipients.map(\.name) == ["Recipient"])
            #expect(shared.recipients.first?.userID == recipient.id)
            #expect(!shared.canEditList)
            #expect(feed.claims.first { $0.itemID == second.id }?.recipients.map(\.name) == ["Grandma"])

            let date = Date(timeIntervalSince1970: 1_700_000_000)
            try req.content.encode(PersonalGiftsController.SaveRequest(title: "Scarf", recipients: [
                .init(userID: recipient.requireID(), name: "Recipient"), .init(userID: nil, name: "Grandma")
            ], price: 35, currencyCode: "USD", url: "https://example.com/scarf", notes: "Already wrapped", quantity: 1, purchasedAt: date))
            let gift = try await controller.create(req: req)
            #expect(gift.recipients.count == 2)
            #expect(gift.purchasedAt == date)
            #expect(try await controller.index(req: req).purchases.count == 1)
            #expect(try await ActivityNotification.query(on: app.db).count() == 0)
            #expect(try await Wishlist.query(on: app.db).count() == 2)
            req.parameters.set("giftID", to: gift.id.uuidString)
            req.auth.login(other)
            let theirFeed = try await controller.index(req: req)
            #expect(theirFeed.purchases.isEmpty)
            #expect(theirFeed.claims.count == 1)
            #expect(theirFeed.claims.first?.quantity == 1)
            do { _ = try await controller.update(req: req); Issue.record("Another account edited the purchase") }
            catch let error as Abort { #expect(error.status == .notFound) }
            do { _ = try await controller.delete(req: req); Issue.record("Another account deleted the purchase") }
            catch let error as Abort { #expect(error.status == .notFound) }
            req.auth.login(buyer)
            try req.content.encode(PersonalGiftsController.SaveRequest(title: "Scarf, updated", recipients: [], price: nil,
                currencyCode: nil, url: nil, notes: nil, quantity: 2, purchasedAt: date))
            let updated = try await controller.update(req: req)
            #expect(updated.price == nil && updated.url == nil && updated.notes == nil)
            #expect(updated.quantity == 2 && updated.recipients.isEmpty)
            mine.purchased = false
            mine.purchasedQuantity = 0
            try await mine.save(on: app.db)
            #expect(try await controller.index(req: req).claims.count == 1)
            // Detached memberships are excluded even if an old claim state survives.
            try await WishlistItemMembership.query(on: app.db).filter(\.$item.$id == second.requireID()).delete()
            #expect(try await controller.index(req: req).claims.isEmpty)
            _ = try await controller.delete(req: req)
            #expect(try await controller.index(req: req).purchases.isEmpty)
            for item in [first, second] { try await item.delete(on: app.db) }
            for user in users { try await user.delete(on: app.db) }
        } catch {
            for user in users { try? await user.delete(on: app.db) }
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
