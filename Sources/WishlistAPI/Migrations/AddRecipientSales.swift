import Fluent

struct AddRecipientSales: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("item_viewer_state").field("recipient_sale", .json).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("item_viewer_state").deleteField("recipient_sale").update()
    }
}
