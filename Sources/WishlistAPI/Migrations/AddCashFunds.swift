import Fluent

struct AddCashFunds: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WishlistItem.schema)
            .field("item_type", .string, .required, .sql(.default("wish")))
            .field("contribution_goal", .double)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(WishlistItem.schema)
            .deleteField("contribution_goal")
            .deleteField("item_type")
            .update()
    }
}
