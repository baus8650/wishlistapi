import Fluent

struct CreateAuthIdentity: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AuthIdentity.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("provider", .string, .required)
            .field("provider_subject", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "provider", "provider_subject")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AuthIdentity.schema).delete()
    }
}
