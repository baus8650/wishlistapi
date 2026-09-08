import Fluent
import SQLKit
import Vapor

struct AddCashFunds: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Staging databases can contain the older wishlist_items table while
        // missing this migration's log entry. PostgreSQL's conditional ALTER
        // keeps a retry safe without dropping existing wishes.
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Cash-fund migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"wishlist_items\" ADD COLUMN IF NOT EXISTS \"item_type\" TEXT NOT NULL DEFAULT 'wish'").run()
        try await sql.raw("ALTER TABLE \"wishlist_items\" ADD COLUMN IF NOT EXISTS \"contribution_goal\" DOUBLE PRECISION").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistItem.schema)
            .deleteField("contribution_goal")
            .deleteField("item_type")
            .update()
    }
}
