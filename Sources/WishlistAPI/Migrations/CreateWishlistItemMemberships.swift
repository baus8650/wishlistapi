import Fluent

struct CreateWishlistItemMemberships: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WishlistItemMembership.schema)
            .id()
            .field("item_id", .uuid, .required, .references(WishlistItem.schema, "id", onDelete: .cascade))
            .field("wishlist_id", .uuid, .required, .references(Wishlist.schema, "id", onDelete: .cascade))
            .field("position", .int, .required, .sql(.default(0)))
            .unique(on: "item_id", "wishlist_id")
            .create()

        for item in try await WishlistItem.query(on: database).all() {
            try await WishlistItemMembership(
                itemID: try item.requireID(),
                wishlistID: item.$wishlist.id,
                position: item.position
            ).save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistItemMembership.schema).delete()
    }
}
