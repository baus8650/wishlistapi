import Fluent

struct AddBirthdayToUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("birthday_month", .int)
            .field("birthday_day", .int)
            .field("birthday_visibility", .string, .required, .sql(.default("private")))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("birthday_visibility")
            .deleteField("birthday_day")
            .deleteField("birthday_month")
            .update()
    }
}
