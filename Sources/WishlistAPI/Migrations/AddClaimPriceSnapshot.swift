import Fluent

struct AddClaimPriceSnapshot: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("personal_gifts").field("price_confirmed", .bool).update()
        try await database.schema("item_viewer_state").field("claim_price", .json).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("personal_gifts").deleteField("price_confirmed").update()
        try await database.schema("item_viewer_state").deleteField("claim_price").update()
    }
}
