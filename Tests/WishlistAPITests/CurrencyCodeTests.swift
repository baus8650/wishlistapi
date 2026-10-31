@testable import WishlistAPI
import Foundation
import Testing
import Vapor

@Suite("List and item currency validation")
struct CurrencyCodeTests {
    @Test func normalizesSupportedCurrenciesAndInheritance() throws {
        #expect(try CurrencyCode.validated(" cop ") == "COP")
        #expect(try CurrencyCode.validated("rub") == "RUB")
        #expect(try CurrencyCode.validated("JPY") == "JPY")
        #expect(try CurrencyCode.validated("") == nil)
        #expect(throws: Abort.self) { try CurrencyCode.validated("ZZZ") }
    }

    @Test func itemOverrideCanBeSetClearedOrOmitted() throws {
        let decoder = JSONDecoder()
        let explicit = try decoder.decode(WishlistItemController.CreateRequest.self, from: Data(#"{"title":"Wish","currencyCode":"COP"}"#.utf8))
        #expect(explicit.currencyCode == "COP")
        let inherit = try decoder.decode(WishlistItemController.UpdateRequest.self, from: Data(#"{"currencyCode":""}"#.utf8))
        #expect(inherit.currencyCode == "")
        let legacy = try decoder.decode(WishlistItemController.CreateRequest.self, from: Data(#"{"title":"Wish"}"#.utf8))
        #expect(legacy.currencyCode == nil)
    }

    @Test func listRequestsCarryCurrency() throws {
        let request = try JSONDecoder().decode(WishlistController.UpdateSettingsRequest.self, from: Data(#"{"currencyCode":"RUB"}"#.utf8))
        #expect(request.currencyCode == "RUB")
        let create = try JSONDecoder().decode(WishlistController.CreateRequest.self, from: Data(#"{"title":"Travel","currencyCode":"COP"}"#.utf8))
        #expect(create.currencyCode == "COP")
    }
    @Test func responseModelsEncodeCurrency() throws {
        let list = Wishlist(ownerUserId: UUID(), title: "Travel")
        list.currencyCode = "COP"
        let item = WishlistItem(wishlistId: nil, title: "Suitcase", price: 100)
        item.currencyCode = "RUB"
        let listJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(list)) as! [String: Any]
        let itemJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as! [String: Any]
        #expect(listJSON["currencyCode"] as? String == "COP")
        #expect(itemJSON["currencyCode"] as? String == "RUB")
    }

}
