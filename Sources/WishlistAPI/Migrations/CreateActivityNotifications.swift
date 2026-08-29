import Fluent

struct CreateActivityNotifications: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("activity_notifications").id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("actor_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("wishlist_id", .uuid, .references("wishlists", "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("title", .string, .required)
            .field("message", .string, .required)
            .field("read_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema("activity_notifications").delete() }
}
