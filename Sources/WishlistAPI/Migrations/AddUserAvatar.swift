import Fluent

struct AddUserAvatar: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("avatar_data", .data)
            .field("avatar_content_type", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("users")
            .deleteField("avatar_content_type")
            .deleteField("avatar_data")
            .update()
    }
}
