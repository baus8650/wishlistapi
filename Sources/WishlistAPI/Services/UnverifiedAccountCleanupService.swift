import Fluent
import Vapor

/// Password registrations that never verify cannot sign in, but retaining
/// them forever makes bot activity look like real growth and consumes storage.
/// Seven days leaves ample time to find a verification email or request a new
/// link before the placeholder account is removed.
enum UnverifiedAccountCleanupService {
    private static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    static func schedule(on app: Application) {
        _ = app.eventLoopGroup.next().scheduleRepeatedTask(
            initialDelay: .seconds(60),
            delay: .hours(24)
        ) { _ in
            Task {
                do {
                    let removed = try await removeExpired(on: app.db)
                    if removed > 0 {
                        app.logger.notice("Removed \(removed) expired unverified account(s).")
                    }
                } catch {
                    app.logger.error("Unable to clean up expired unverified accounts: \(error)")
                }
            }
        }
    }

    @discardableResult
    static func removeExpired(on database: any Database, now: Date = Date()) async throws -> Int {
        let expiredAccounts = try await User.query(on: database)
            .filter(\.$emailVerifiedAt == nil)
            .filter(\.$createdAt < now.addingTimeInterval(-maximumAge))
            .all()

        for account in expiredAccounts {
            // User-owned foreign keys cascade, so this also removes their
            // expired verification tokens without leaving orphaned rows.
            try await account.delete(on: database)
        }
        return expiredAccounts.count
    }
}
