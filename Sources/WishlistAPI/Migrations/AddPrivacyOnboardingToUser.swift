import Fluent

struct AddPrivacyOnboardingToUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("privacy_setup_completed", .bool)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("privacy_setup_completed")
            .update()
    }
}
