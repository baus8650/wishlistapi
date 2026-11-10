@testable import WishlistAPI
import Foundation
import Testing
import Vapor

@Suite("Hushful Swap privacy and draws")
struct SwapTests {
    @Test func drawsAreDirectedPermutationsWithoutSelfAssignments() throws {
        for count in [2, 3, 4, 5, 12, 100] {
            let ids = (0..<count).map { _ in UUID() }
            for _ in 0..<100 {
                let draw = try SwapSecurity.draw(ids)
                #expect(Set(draw.keys) == Set(ids))
                #expect(Set(draw.values) == Set(ids))
                #expect(ids.allSatisfy { draw[$0] != $0 })
            }
        }
        // A draw is not constrained to reciprocal pairs.
        let ids = (0..<5).map { _ in UUID() }
        let draw = try SwapSecurity.draw(ids)
        #expect(ids.contains { draw[draw[$0]!] != $0 })
    }
    @Test func rejectsImpossibleAndDuplicateRosters() {
        #expect(throws: Abort.self) { try SwapSecurity.draw([]) }
        #expect(throws: Abort.self) { try SwapSecurity.draw([UUID()]) }
        let id = UUID()
        #expect(throws: Abort.self) { try SwapSecurity.draw([id, id, UUID(), UUID()]) }
    }
    @Test func organizerAndMembersOnlyReceiveTheirOwnRecipient() throws {
        let owner = UUID()
        var members = (0..<5).map { SwapMember(userID: $0 == 0 ? owner : UUID(), name: "Person \($0)", status: "accepted") }
        for i in members.indices {
            members[i].recipientID = members[(i + 1) % members.count].id
            members[i].wishes = [.init(title: "Wish \(i)")]
        }
        let swap = HushfulSwap(ownerID: owner, state: .init(title: "Test", exchangeDate: "2027-01-20", currencyCode: "USD", status: "drawn", members: members))
        swap.id = UUID()
        for i in members.indices {
            let view = try SwapSecurity.view(swap, memberIndex: i)
            #expect(view.isAdmin == (i == 0))
            #expect(view.recipient?.name == members[(i + 1) % members.count].name)
            #expect(view.wishes == members[i].wishes)
            #expect(view.inviteURL == nil)
            let json = String(decoding: try JSONEncoder().encode(view), as: UTF8.self)
            for key in ["recipientID", "guestHash", "secret-", "userID", "lastReminder"] { #expect(!json.contains(key)) }
            for j in members.indices where j != i && j != (i + 1) % members.count { #expect(!json.contains("Wish \(j)")) }
        }
        swap.state.status = "draft"
        #expect(try SwapSecurity.view(swap, memberIndex: 0).recipient == nil)
        #expect(try SwapSecurity.view(swap, memberIndex: 1).inviteURL == nil)
    }
    @Test func reminderTimingAndDeduplication() throws {
        let date = try #require(SwapReminderService.date("2027-01-20"))
        var member = SwapMember(userID: UUID(), name: "Alex", status: "accepted", reminderDays: 7)
        #expect(!SwapReminderService.isDue(member, exchangeDate: "2027-01-20", now: date.addingTimeInterval(-8 * 86400)))
        #expect(SwapReminderService.isDue(member, exchangeDate: "2027-01-20", now: date.addingTimeInterval(-7 * 86400)))
        member.purchaseReminderSent = true
        #expect(!SwapReminderService.isDue(member, exchangeDate: "2027-01-20", now: date))
        member.purchaseReminderSent = false; member.reminderDays = nil
        #expect(!SwapReminderService.isDue(member, exchangeDate: "2027-01-20", now: date))
        member.reminderDays = 0; member.userID = nil
        #expect(!SwapReminderService.isDue(member, exchangeDate: "2027-01-20", now: date))
        #expect(SwapReminderService.date("2027-02-30") == nil)
        #expect(SwapReminderService.date("2027-2-1") == nil)
    }
    @Test func giftLinksRejectExecutableSchemes() throws {
        #expect(throws: Abort.self) { try HushfulSwapController.cleanWishes([.init(title: "Gift", url: "javascript:alert(1)")]) }
        #expect(throws: Abort.self) { try HushfulSwapController.cleanWishes([.init(title: "   ")]) }
        #expect(try HushfulSwapController.cleanWishes([.init(title: " Gift ", url: "https://example.com")]).first?.title == "Gift")
    }
    @Test func invitationTokensAreUnpredictableAndDistinct() {
        let a = SwapSecurity.token(), b = SwapSecurity.token()
        #expect(a.count == 64 && b.count == 64)
        #expect(a != b)
    }
}
