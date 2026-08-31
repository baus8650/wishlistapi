import Fluent

struct AddWishlistOrdering: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists")
            .field("position", .int, .required, .sql(.default(0)))
            .update()
        try await database.schema("wishlist_items")
            .field("position", .int, .required, .sql(.default(0)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_items").deleteField("position").update()
        try await database.schema("wishlists").deleteField("position").update()
    }
}
