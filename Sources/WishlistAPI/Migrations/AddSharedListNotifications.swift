import Fluent

struct AddSharedListNotifications: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_viewers")
            .field("notifications_enabled", .bool, .required, .sql(.default(true)))
            .update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_viewers").deleteField("notifications_enabled").update()
    }
}
