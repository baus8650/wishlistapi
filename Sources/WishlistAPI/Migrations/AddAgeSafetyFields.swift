import Fluent

struct AddAgeSafetyFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("age_band", .string, .required, .sql(.default("unknown")))
            .field("mature_profile_enabled", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("mature_profile_enabled")
            .deleteField("age_band")
            .update()
    }
}
