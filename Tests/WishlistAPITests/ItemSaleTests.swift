@testable import WishlistAPI
import Foundation
import Testing
import Vapor

@Suite("Item sales")
struct ItemSaleTests {
    @Test("Percentage discounts round to cents and expire")
    func percentageAndExpiry() throws {
        let item = WishlistItem(wishlistId: UUID(), title: "Wish", price: 19.99)
        try WishlistItemController().applySale(item, price: item.price, salePrice: nil, discount: 25, endsAt: Date().addingTimeInterval(60))
        #expect(item.activeSalePrice == 14.99)
        #expect(item.price == 19.99)
        item.saleEndsAt = Date().addingTimeInterval(-1)
        #expect(item.activeSalePrice == nil)
    }
    @Test("Fixed sale price can be removed")
    func fixedAndClear() throws {
        let item = WishlistItem(wishlistId: UUID(), title: "Wish", price: 100)
        let controller = WishlistItemController()
        try controller.applySale(item, price: item.price, salePrice: 60, discount: nil, endsAt: nil)
        #expect(item.activeSalePrice == 60)
        try controller.applySale(item, price: item.price, salePrice: nil, discount: nil, endsAt: nil)
        #expect(item.activeSalePrice == nil)
        #expect(item.saleEndsAt == nil)
    }
    @Test("Reject invalid or ambiguous discounts")
    func invalidDiscounts() {
        let item = WishlistItem(wishlistId: UUID(), title: "Wish", price: 100)
        let controller = WishlistItemController()
        for discount in [-1.0, 0, 101, .infinity, .nan] {
            #expect(throws: Abort.self) { try controller.applySale(item, price: 100, salePrice: nil, discount: discount, endsAt: nil) }
        }
        for price in [-1.0, 100, 101, .infinity, .nan] {
            #expect(throws: Abort.self) { try controller.applySale(item, price: 100, salePrice: price, discount: nil, endsAt: nil) }
        }
        #expect(throws: Abort.self) { try controller.applySale(item, price: nil, salePrice: 10, discount: nil, endsAt: nil) }
        #expect(throws: Abort.self) { try controller.applySale(item, price: 100, salePrice: 10, discount: 20, endsAt: nil) }
        item.itemType = "cash_fund"
        #expect(throws: Abort.self) { try controller.applySale(item, price: 100, salePrice: 10, discount: nil, endsAt: nil) }
    }
}
