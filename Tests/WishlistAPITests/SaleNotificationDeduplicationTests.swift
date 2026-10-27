@testable import WishlistAPI
import Foundation
import Testing

@Suite("One sale notification per item and recipient")
struct SaleNotificationDeduplicationTests {
    private func list(owner: UUID, purpose: String = "for_others", archived: Bool = false) -> Wishlist {
        let result = Wishlist(ownerUserId: owner, title: "List")
        result.id = UUID()
        result.purpose = purpose
        result.isArchived = archived
        return result
    }

    @Test("Three overlapping lists produce one alert per person with an accessible destination")
    func overlappingLists() throws {
        let owner = UUID(), recipient = UUID(), otherRecipient = UUID()
        let first = list(owner: owner), second = list(owner: owner), third = list(owner: owner)
        let audiences: [SaleNotificationService.ListAudience] = [
            .init(wishlist: first, recipientIDs: [recipient]),
            .init(wishlist: second, recipientIDs: [recipient]),
            .init(wishlist: third, recipientIDs: [recipient, otherRecipient])
        ]
        let targets = try SaleNotificationService.notificationTargets(for: audiences, actorID: owner)
        #expect(targets.count == 2)
        #expect(targets.filter { $0.userID == recipient }.count == 1)
        #expect(targets.first { $0.userID == otherRecipient }?.wishlistID == third.id)
        // A later update must still notify the same people.
        #expect(try SaleNotificationService.notificationTargets(for: audiences, actorID: owner).count == 2)
    }

    @Test("Muted and archived lists do not suppress alerts through another eligible list")
    func eligibleDestination() throws {
        let owner = UUID(), recipient = UUID()
        let muted = list(owner: owner), archived = list(owner: owner, archived: true), enabled = list(owner: owner)
        let targets = try SaleNotificationService.notificationTargets(for: [
            .init(wishlist: muted, recipientIDs: []),
            .init(wishlist: archived, recipientIDs: [recipient]),
            .init(wishlist: enabled, recipientIDs: [recipient, owner])
        ], actorID: owner)
        #expect(targets.count == 1)
        #expect(targets.first?.userID == recipient)
        #expect(targets.first?.wishlistID == enabled.id)
    }

    @Test("Personal-list owner alerts also deduplicate without suppressing shared-list recipients")
    func mixedPurposes() throws {
        let owner = UUID(), recipient = UUID(), actor = UUID()
        let targets = try SaleNotificationService.notificationTargets(for: [
            .init(wishlist: list(owner: owner, purpose: "for_myself"), recipientIDs: [recipient]),
            .init(wishlist: list(owner: owner, purpose: "for_myself"), recipientIDs: []),
            .init(wishlist: list(owner: owner), recipientIDs: [recipient, actor, owner])
        ], actorID: actor)
        #expect(targets.count == 2)
        #expect(Set(targets.map(\.userID)) == [owner, recipient])
    }
}
