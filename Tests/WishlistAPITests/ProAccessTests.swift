@testable import WishlistAPI
import AppStoreServerLibrary
import Foundation
import Testing
import Vapor

@Suite("Pro access")
struct ProAccessTests {
    @Test("Free accounts cannot use Pro features; entitled accounts can")
    func proGate() throws {
        let user = User(email: "test@example.com", passwordHash: "unused")
        #expect(throws: Abort.self) { try ProAccessService.requirePro(user) }
        user.hasLifetimePro = true
        try ProAccessService.requirePro(user)
    }

    @Test("Only account-bound lifetime Pro transactions can grant access")
    func purchaseValidation() throws {
        let now = Date()
        let valid = JWSTransactionDecodedPayload(originalTransactionId: "123", productId: "com.bausch.hushful.pro.lifetime", type: .nonConsumable, appAccountToken: UUID(), signedDate: now)
        try ProPurchaseController.validatePurchase(valid, now: now)
        var wrongProduct = valid
        wrongProduct.productId = "another.product"
        #expect(throws: Abort.self) { try ProPurchaseController.validatePurchase(wrongProduct, now: now) }
        var unbound = valid
        unbound.appAccountToken = nil
        #expect(throws: Abort.self) { try ProPurchaseController.validatePurchase(unbound, now: now) }
        var future = valid
        future.signedDate = now.addingTimeInterval(301)
        #expect(throws: Abort.self) { try ProPurchaseController.validatePurchase(future, now: now) }
        var noDate = valid
        noDate.signedDate = nil
        #expect(throws: Abort.self) { try ProPurchaseController.validatePurchase(noDate, now: now) }
    }
}
