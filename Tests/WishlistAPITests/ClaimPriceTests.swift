@testable import WishlistAPI
import Foundation
import Testing

struct ClaimPriceTests {
    @Test func snapshotsActiveSaleAndCurrencyAndKeepsTheSavedValue() {
        let list = Wishlist()
        list.currencyCode = "USD"
        let item = WishlistItem(wishlistId: UUID(), title: "Book", price: 100)
        item.currencyCode = "EUR"
        item.salePrice = 75
        item.saleEndsAt = Date().addingTimeInterval(3600)
        let snapshot = RecipientShareController().claimPriceSnapshot(item: item, list: list, sale: nil)
        #expect(snapshot.unitPrice == 75)
        #expect(snapshot.currencyCode == "EUR")
        #expect(snapshot.claimedAt != nil)
        item.price = 200
        item.salePrice = nil
        #expect(snapshot.unitPrice == 75)
    }

    @Test func ignoresExpiredSalesAndHonorsRecipientDiscount() {
        let list = Wishlist()
        let item = WishlistItem(wishlistId: UUID(), title: "Book", price: 100)
        item.salePrice = 70
        item.saleEndsAt = Date().addingTimeInterval(-3600)
        let controller = RecipientShareController()
        #expect(controller.claimPriceSnapshot(item: item, list: list, sale: nil).unitPrice == 100)
        let sale = RecipientShareController.RecipientSale(salePrice: nil, saleDiscountPercent: 20, saleEndsAt: Date().addingTimeInterval(3600))
        #expect(controller.claimPriceSnapshot(item: item, list: list, sale: sale).unitPrice == 80)
    }
}
