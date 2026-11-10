import Fluent

struct CreateAnnouncements: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(User.schema).field("announcement_push_enabled", .bool).update()
        try await db.schema(Announcement.schema).id()
            .field("title", .string, .required).field("message", .string, .required)
            .field("recipient_count", .int, .required)
            .field("admin_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("created_at", .datetime).create()
        try await db.schema(AnnouncementDelivery.schema).id()
            .field("announcement_id", .uuid, .required, .references(Announcement.schema, "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("processed", .bool, .required)
            .unique(on: "announcement_id", "user_id").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(AnnouncementDelivery.schema).delete()
        try await db.schema(Announcement.schema).delete()
        try await db.schema(User.schema).deleteField("announcement_push_enabled").update()
    }
}
