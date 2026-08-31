import Fluent

struct AddWishlistProductivityTools: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Wishlist.schema)
            .field("description", .string)
            .field("custom_color_hex", .string)
            .field("reminder_date", .datetime)
            .update()

        try await database.schema(WishlistViewer.schema)
            .field("recipient_due_date", .datetime)
            .field("recipient_reminder_enabled", .bool, .required, .sql(.default(false)))
            .field("recipient_reminder_date", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistViewer.schema)
            .deleteField("recipient_due_date")
            .deleteField("recipient_reminder_enabled")
            .deleteField("recipient_reminder_date")
            .update()
        try await database.schema(Wishlist.schema)
            .deleteField("description")
            .deleteField("custom_color_hex")
            .deleteField("reminder_date")
            .update()
    }
}
