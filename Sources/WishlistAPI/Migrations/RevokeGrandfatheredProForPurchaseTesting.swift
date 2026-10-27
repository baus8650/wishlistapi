import Fluent

/// Removes the temporary beta grandfather grants so testers exercise StoreKit.
/// TestFlight uses Apple's sandbox and does not charge testers.
struct RevokeGrandfatheredProForPurchaseTesting: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await User.query(on: database).filter(\.$hasLifetimePro == true)
            .set(\.$hasLifetimePro, to: false).update()
    }

    func revert(on database: any Database) async throws {
        // The previous grants can't be distinguished from future administrative
        // grants, so reverting intentionally leaves account entitlements unchanged.
    }
}
