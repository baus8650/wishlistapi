import Fluent

/// Removes the temporary beta grandfather grants so testers exercise StoreKit.
/// TestFlight uses Apple's sandbox and does not charge testers.
struct RevokeGrandfatheredProForPurchaseTesting: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let users = try await User.query(on: database).all()
        for user in users where user.hasLifetimePro {
            user.hasLifetimePro = false
            try await user.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        // The previous grants can't be distinguished from future administrative
        // grants, so reverting intentionally leaves account entitlements unchanged.
    }
}
