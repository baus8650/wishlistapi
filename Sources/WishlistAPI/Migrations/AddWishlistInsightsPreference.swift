import Fluent

struct AddWishlistInsightsPreference: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Wishlist.schema)
            .field("show_insights", .bool, .required, .sql(.default(true)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(Wishlist.schema)
            .deleteField("show_insights")
            .update()
    }
}
