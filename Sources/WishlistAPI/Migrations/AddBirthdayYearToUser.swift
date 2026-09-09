import Fluent

struct AddBirthdayYearToUser: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("birthday_year", .int)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("birthday_year")
            .update()
    }
}
