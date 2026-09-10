import Fluent

struct CreateAdminProGrants: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AdminProGrant.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("granted_by_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("revoked_by_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("reason", .string, .required)
            .field("active", .bool, .required)
            .field("created_at", .datetime)
            .field("revoked_at", .datetime)
            // At most one active manual grant may exist for an account while
            // still allowing a complete history of revoked grants.
            .unique(on: "user_id", "active")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AdminProGrant.schema).delete()
    }
}
