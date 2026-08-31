import Fluent

struct CreateWishlistItemImages: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WishlistItemImage.schema)
            .id()
            .field("item_id", .uuid, .required, .references(WishlistItem.schema, "id", onDelete: .cascade))
            .field("data", .data, .required)
            .field("content_type", .string, .required)
            .unique(on: "item_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistItemImage.schema).delete()
    }
}
