import Fluent

struct AddItemSales: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_items")
            .field("sale_price", .double)
            .field("sale_discount_percent", .double)
            .field("sale_ends_at", .datetime)
            .update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_items")
            .deleteField("sale_price").deleteField("sale_discount_percent").deleteField("sale_ends_at").update()
    }
}
