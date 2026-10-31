import Fluent

struct AddListAndItemCurrencies: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists").field("currency_code", .string).update()
        try await database.schema("wishlist_items").field("currency_code", .string).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_items").deleteField("currency_code").update()
        try await database.schema("wishlists").deleteField("currency_code").update()
    }
}
