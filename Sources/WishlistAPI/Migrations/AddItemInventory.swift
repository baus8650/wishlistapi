import Fluent
import SQLKit
import Vapor

struct AddItemInventory: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await db.schema("wishlist_items")
                .field("inventory_owner_id", .uuid, .references("users", "id", onDelete: .cascade)).update()
            try await sql.raw("""
                UPDATE wishlist_items AS item SET inventory_owner_id = list.owner_user_id
                FROM wishlists AS list WHERE list.id = item.wishlist_id
                """).run()
            // Memberships now describe where an item appears; the legacy parent is optional.
            try await sql.raw("""
                DO $$ DECLARE constraint_name text; BEGIN
                    FOR constraint_name IN SELECT conname FROM pg_constraint
                        WHERE conrelid = 'wishlist_items'::regclass AND contype = 'f'
                        AND confrelid = 'wishlists'::regclass
                    LOOP EXECUTE format('ALTER TABLE wishlist_items DROP CONSTRAINT %I', constraint_name); END LOOP;
                END $$
                """).run()
            try await sql.raw("ALTER TABLE wishlist_items ALTER COLUMN wishlist_id DROP NOT NULL").run()
            try await db.schema("wishlist_items")
                .foreignKey("wishlist_id", references: "wishlists", "id", onDelete: .setNull, name: "item_inventory_legacy_list").update()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            guard try await WishlistItem.query(on: db).filter(\.$wishlist.$id == nil).count() == 0 else {
                throw Abort(.conflict, reason: "Reattach items under No list before reverting the item inventory migration.")
            }
            try await db.schema("wishlist_items").deleteForeignKey(name: "item_inventory_legacy_list").update()
            try await sql.raw("ALTER TABLE wishlist_items ALTER COLUMN wishlist_id SET NOT NULL").run()
            try await db.schema("wishlist_items")
                .foreignKey("wishlist_id", references: "wishlists", "id", onDelete: .cascade)
                .deleteField("inventory_owner_id").update()
        }
    }
}
