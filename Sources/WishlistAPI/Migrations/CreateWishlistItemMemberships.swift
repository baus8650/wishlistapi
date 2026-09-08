import Fluent

struct CreateWishlistItemMemberships: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WishlistItemMembership.schema)
            .id()
            .field("item_id", .uuid, .required, .references(WishlistItem.schema, "id", onDelete: .cascade))
            .field("wishlist_id", .uuid, .required, .references(Wishlist.schema, "id", onDelete: .cascade))
            .field("position", .int, .required, .sql(.default(0)))
            .unique(on: "item_id", "wishlist_id")
            // Staging may contain this table without a matching Fluent log entry
            // after an interrupted or copied deployment. Keep this migration
            // safe to retry while preserving any existing rows.
            .ignoreExisting()
            .create()

        for item in try await WishlistItem.query(on: database).all() {
            let itemID = try item.requireID()
            let wishlistID = item.$wishlist.id
            let exists = try await WishlistItemMembership.query(on: database)
                .filter(\.$item.$id == itemID)
                .filter(\.$wishlist.$id == wishlistID)
                .first() != nil
            if !exists {
                try await WishlistItemMembership(
                    itemID: itemID,
                    wishlistID: wishlistID,
                    position: item.position
                ).save(on: database)
            }
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistItemMembership.schema).delete()
    }
}
