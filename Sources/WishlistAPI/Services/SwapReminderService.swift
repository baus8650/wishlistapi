import Fluent
import SQLKit
import Vapor

enum SwapReminderService {
    // Exchange dates are calendar dates. Deliver at noon UTC on the selected day.
    static func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard value.count == 10, let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date.addingTimeInterval(12 * 3600)
    }
    static func isDue(_ member: SwapMember, exchangeDate: String, now: Date) -> Bool {
        guard member.status == "accepted", member.userID != nil, member.purchaseReminderSent != true,
              let days = member.reminderDays, let date = date(exchangeDate), now < date.addingTimeInterval(12 * 3600) else { return false }
        return now >= date.addingTimeInterval(-Double(days) * 86400)
    }
    static func schedule(on app: Application) {
        _ = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(60), delay: .minutes(15)) { _ in
            Task {
                do { try await sendDue(on: app.db, client: app.client, logger: app.logger) }
                catch { app.logger.error("Unable to send swap reminders: \(error)") }
            }
        }
    }
    static func sendDue(on db: any Database, client: any Client, logger: Logger) async throws {
        guard let sql = db as? any SQLDatabase else { return }
        let rows = try await sql.raw("SELECT id FROM hushful_swaps WHERE state->>'status' = 'drawn'").all()
        for row in rows {
            let id = try row.decode(column: "id", as: UUID.self)
            let notifications: [ActivityNotification] = try await db.transaction { tx in
                guard let sql = tx as? any SQLDatabase else { throw Abort(.internalServerError) }
                let locked = try await sql.raw("SELECT id FROM hushful_swaps WHERE id = \(bind: id) FOR UPDATE SKIP LOCKED").all()
                guard !locked.isEmpty, let swap = try await HushfulSwap.find(id, on: tx), swap.state.status == "drawn" else { return [] }
                var notifications: [ActivityNotification] = []
                for i in swap.state.members.indices where isDue(swap.state.members[i], exchangeDate: swap.state.exchangeDate, now: Date()) {
                    guard let userID = swap.state.members[i].userID, try await User.find(userID, on: tx) != nil else { continue }
                    let notification = ActivityNotification(userID: userID, kind: "swap_purchase_reminder", title: "A little gift reminder", message: "Your Hushful Swap is coming up. Open My Lists to plan your gift.")
                    try await notification.save(on: tx)
                    notifications.append(notification)
                    swap.state.members[i].purchaseReminderSent = true
                }
                if !notifications.isEmpty { try await swap.save(on: tx) }
                return notifications
            }
            for notification in notifications { await ActivityService.sendPush(notification, on: db, client: client, logger: logger) }
        }
    }
}
