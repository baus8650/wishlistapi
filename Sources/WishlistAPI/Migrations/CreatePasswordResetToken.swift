import Fluent

struct CreatePasswordResetToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PasswordResetToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PasswordResetToken.schema).delete()
    }
}
