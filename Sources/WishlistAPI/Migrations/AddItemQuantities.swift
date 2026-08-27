import Fluent
import SQLKit

struct AddItemQuantities: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_items")
            .field("quantity", .int, .required, .sql(.default(1)))
            .update()
        try await database.schema("item_viewer_state")
            .field("purchased_quantity", .int, .required, .sql(.default(0)))
            .update()
        if let sql = database as? any SQLDatabase {
            try await sql.raw("UPDATE item_viewer_state SET purchased_quantity = 1 WHERE purchased = TRUE").run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema("item_viewer_state").deleteField("purchased_quantity").update()
        try await database.schema("wishlist_items").deleteField("quantity").update()
    }
}
