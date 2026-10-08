@testable import WishlistAPI
import Foundation
import Testing
import Vapor

@Suite("Sale reminders and list purpose")
struct SaleReminderTests {
    @Test("Personal sale alerts reach the owner even when they changed their own item")
    func personalAudience() {
        let owner = UUID(), friend = UUID()
        #expect(SaleNotificationService.audience(purpose: "for_myself", ownerID: owner, recipientIDs: [friend], actorID: owner) == [owner])
        #expect(SaleNotificationService.audience(purpose: "for_myself", ownerID: owner, recipientIDs: [], actorID: nil) == [owner])
    }
    @Test("Shared alerts only target followers and exclude the owner and actor")
    func sharedAudience() {
        let owner = UUID(), friend = UUID(), actor = UUID()
        #expect(SaleNotificationService.audience(purpose: "for_others", ownerID: owner, recipientIDs: [owner, friend, actor], actorID: actor) == [friend])
        #expect(SaleNotificationService.audience(purpose: "for_others", ownerID: owner, recipientIDs: [], actorID: nil).isEmpty)
    }
    @Test("Reminder is due only during the final day and only once for that end date")
    func reminderWindow() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let item = WishlistItem(wishlistId: UUID(), title: "Sale", price: 100)
        let controller = WishlistItemController()
        try controller.applySale(item, price: 100, salePrice: 75, discount: nil, endsAt: now.addingTimeInterval(86401))
        #expect(!SaleReminderService.isDue(item, now: now))
        item.saleEndsAt = now.addingTimeInterval(86400)
        #expect(SaleReminderService.isDue(item, now: now))
        item.saleReminderSentForEnd = item.saleEndsAt
        #expect(!SaleReminderService.isDue(item, now: now))
        try controller.applySale(item, price: 100, salePrice: 75, discount: nil, endsAt: now.addingTimeInterval(3600))
        #expect(SaleReminderService.isDue(item, now: now))
        item.saleEndsAt = now
        #expect(!SaleReminderService.isDue(item, now: now))
        try controller.applySale(item, price: 100, salePrice: nil, discount: nil, endsAt: nil)
        #expect(!SaleReminderService.isDue(item, now: now))
    }
    @Test("Lists preserve existing recipient alerts by default and reject unknown purposes")
    func purposeValidation() throws {
        #expect(Wishlist(ownerUserId: UUID(), title: "List").purpose == "for_others")
        #expect(try WishlistController().validatedPurpose("for_myself") == "for_myself")
        #expect(throws: Abort.self) { try WishlistController().validatedPurpose("invalid") }
    }
}
