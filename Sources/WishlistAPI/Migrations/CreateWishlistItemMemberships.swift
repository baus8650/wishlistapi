import Fluent
import SQLKit
import Vapor

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

        // Seed only fields available at this point, independent of future item model fields.
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("""
            INSERT INTO wishlist_item_memberships (id, item_id, wishlist_id, position)
            SELECT gen_random_uuid(), id, wishlist_id, position FROM wishlist_items
            WHERE wishlist_id IS NOT NULL
            ON CONFLICT (item_id, wishlist_id) DO NOTHING
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistItemMembership.schema).delete()
    }
}
