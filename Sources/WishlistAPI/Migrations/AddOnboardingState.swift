import Fluent

/// Stores the first-run experience version on the account so onboarding is
/// completed once across web, iOS, and Android instead of once per device.
struct AddOnboardingState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("onboarding_version", .int)
            .update()

        // Accounts created before this flow existed have already completed the
        // old setup and should not be forced through the new tutorial.
        try await User.query(on: database).filter(\.$onboardingVersion == nil).filter(\.$username != nil)
            .group(.or) { $0.filter(\.$privacySetupCompleted == nil).filter(\.$privacySetupCompleted == true) }
            .set(\.$onboardingVersion, to: 1).update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("onboarding_version")
            .update()
    }
}
