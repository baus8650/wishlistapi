import Foundation
import Vapor

enum SwapSecurity {
    static func token() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &rng)) }.joined()
    }
    // Uniform rejection sampling over permutations, with no self assignments.
    // These are directed recipients, not reciprocal pairs. Never expose the map.
    static func draw(_ ids: [UUID]) throws -> [UUID: UUID] {
        guard ids.count >= 2, Set(ids).count == ids.count else {
            throw Abort(.badRequest, reason: "Each participant needs someone else to gift to. Invite another person before drawing.")
        }
        var recipients = ids.shuffled()
        while zip(ids, recipients).contains(where: { $0 == $1 }) { recipients.shuffle() }
        return Dictionary(uniqueKeysWithValues: zip(ids, recipients))
    }
    static func view(_ swap: HushfulSwap, memberIndex: Int) throws -> SwapView {
        let state = swap.state, me = state.members[memberIndex]
        let admin = me.userID == swap.$owner.id
        let recipient = state.status == "drawn" ? state.members.first { $0.id == me.recipientID } : nil
        return SwapView(id: try swap.requireID(), title: state.title, exchangeDate: state.exchangeDate,
            priceLimit: state.priceLimit, currencyCode: state.currencyCode, status: state.status,
            isAdmin: admin, myID: me.id, reminderDays: me.reminderDays, myStatus: me.status, wishes: me.wishes,
            members: state.members.map { member in
                SwapMemberView(id: member.id, name: member.name, status: member.status,
                    canRemind: admin && state.status == "draft" && member.status == "pending" && member.userID != nil &&
                        (member.lastReminder.map { Date().timeIntervalSince($0) >= 86400 } ?? true))
            }, recipient: recipient.map { SwapRecipientView(name: $0.name, wishes: $0.wishes) },
            inviteURL: admin && state.status == "draft" ? "https://hushful.app/swap/\(swap.inviteToken)" : nil)
    }
}
