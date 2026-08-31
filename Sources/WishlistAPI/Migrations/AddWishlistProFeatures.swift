import Fluent

struct AddWishlistProFeatures: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Wishlist.schema)
            .field("occasion_date", .datetime)
            .field("reminder_enabled", .bool, .required, .sql(.default(false)))
            .field("icon", .string)
            .field("color_theme", .string)
            .field("is_archived", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Wishlist.schema)
            .deleteField("occasion_date")
            .deleteField("reminder_enabled")
            .deleteField("icon")
            .deleteField("color_theme")
            .deleteField("is_archived")
            .update()
    }
}
