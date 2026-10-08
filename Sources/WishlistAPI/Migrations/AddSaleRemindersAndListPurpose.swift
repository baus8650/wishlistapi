import Fluent

struct AddSaleRemindersAndListPurpose: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists")
            .field("purpose", .string, .required, .sql(.default("for_others"))).update()
        try await database.schema("wishlist_items")
            .field("sale_reminder_sent_for_end", .datetime).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_items").deleteField("sale_reminder_sent_for_end").update()
        try await database.schema("wishlists").deleteField("purpose").update()
    }
}
