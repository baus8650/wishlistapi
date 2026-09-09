import Fluent

struct AddBirthdaySetupState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("birthday_setup_completed", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("birthday_setup_completed")
            .update()
    }
}
