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
        let existingUsers = try await User.query(on: database).all()
        for user in existingUsers where user.onboardingVersion == nil && user.username != nil && user.privacySetupCompleted != false {
            user.onboardingVersion = 1
            try await user.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("onboarding_version")
            .update()
    }
}
