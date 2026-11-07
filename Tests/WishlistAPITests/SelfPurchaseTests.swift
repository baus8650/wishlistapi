@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Self purchases", .serialized)
struct SelfPurchaseTests {
    @Test func recordsPriceQuantityAndRecipientOnceAcrossListRemovals() async throws {
        let app = try await Application.make(.testing)
        let user = User(email: "self-purchase-\(UUID())@example.com", passwordHash: "unused")
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await user.save(on: app.db)
            let item = WishlistItem(wishlistId: UUID(), title: "Book", price: 25)
            item.salePrice = 20
            let id = UUID()
            var request = ItemDeletionRequest(reason: .purchasedMyself)
            request.selfPurchase = .init(recordID: id, paidUnitPrice: 17, quantity: 2, purchasedAt: Date())
            let initialRequest = request
            for _ in 0..<2 {
                try await app.db.transaction { db in
                    try await ItemDeletionNotificationService.recordSelfPurchase(item: item, actor: user, fallbackCurrency: "EUR", request: initialRequest, on: db)
                }
            }
            let records = try await PersonalGift.query(on: app.db).filter(\.$user.$id == user.requireID()).all()
            #expect(records.count == 1)
            let record = try #require(records.first)
            #expect(record.price == 17)
            #expect(record.quantity == 2)
            #expect(record.priceConfirmed == true)
            #expect(record.currencyCode == "EUR")
            #expect(record.recipientDocument.recipients.first?.userID == user.id)
            // Purchase records roll back if list removal fails in the transaction.
            enum RemovalFailure: Error { case failed }
            request.selfPurchase = .init(recordID: UUID(), paidUnitPrice: nil, quantity: 1, purchasedAt: Date())
            let rollbackRequest = request
            do {
                try await app.db.transaction { db in
                    try await ItemDeletionNotificationService.recordSelfPurchase(item: item, actor: user, fallbackCurrency: "EUR", request: rollbackRequest, on: db)
                    throw RemovalFailure.failed
                }
            } catch RemovalFailure.failed {}
            #expect(try await PersonalGift.query(on: app.db).filter(\.$user.$id == user.requireID()).count() == 1)
            try await user.delete(on: app.db)
        } catch {
            try? await user.delete(on: app.db)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
