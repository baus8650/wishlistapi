@testable import WishlistAPI
import Foundation
import Testing
import Vapor

@Suite("Private recipient sales")
struct RecipientSaleTests {
    @Test("Owners cannot enter recipient APIs using a linked viewer")
    func ownerCannotReadRecipientSales() async throws {
        let app = try await Application.make(.testing)
        let ownerID = UUID()
        let wishlistID = UUID()
        let wishlist = Wishlist(ownerUserId: ownerID, title: "Private gifts")
        wishlist.id = wishlistID
        let viewer = WishlistViewer(id: UUID(), wishlistId: wishlistID, userId: ownerID)
        let request = Request(application: app, on: app.eventLoopGroup.next())
        do {
            _ = try await RecipientShareController().listItemsWithState(req: request, wishlist: wishlist, viewer: viewer)
            Issue.record("Owner gained access to recipient data")
        } catch let error as Abort {
            #expect(error.status == .forbidden)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Recipient validation never changes an owner's sale")
    func ownerSaleIsUnchanged() throws {
        let wishlistID = UUID()
        let item = WishlistItem(wishlistId: wishlistID, title: "Gift", price: 100)
        item.salePrice = 90
        let end = Date().addingTimeInterval(3600)
        try RecipientShareController().validateRecipientSale(
            .init(salePrice: 60, saleDiscountPercent: nil, saleEndsAt: end), item: item, wishlistID: wishlistID)
        #expect(item.price == 100)
        #expect(item.salePrice == 90)
        #expect(item.saleEndsAt == nil)
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        #expect(encoded["recipientSale"] == nil)
    }

    @Test("Recipient sales reject invalid prices, ambiguous discounts, past dates, and cash funds")
    func validation() {
        let wishlistID = UUID()
        let item = WishlistItem(wishlistId: wishlistID, title: "Gift", price: 100)
        let controller = RecipientShareController()
        let invalid: [RecipientShareController.RecipientSale] = [
            .init(salePrice: 101, saleDiscountPercent: nil, saleEndsAt: nil),
            .init(salePrice: 50, saleDiscountPercent: 20, saleEndsAt: nil),
            .init(salePrice: nil, saleDiscountPercent: 101, saleEndsAt: nil),
            .init(salePrice: 50, saleDiscountPercent: nil, saleEndsAt: .distantPast)
        ]
        for sale in invalid {
            #expect(throws: Abort.self) { try controller.validateRecipientSale(sale, item: item, wishlistID: wishlistID) }
        }
        item.itemType = "cash_fund"
        #expect(throws: Abort.self) {
            try controller.validateRecipientSale(.init(salePrice: 50, saleDiscountPercent: nil, saleEndsAt: nil), item: item, wishlistID: wishlistID)
        }
    }
}
