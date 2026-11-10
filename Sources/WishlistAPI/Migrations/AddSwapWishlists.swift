import Fluent

struct AddSwapWishlists: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Wishlist.schema)
            .field("swap_id", .uuid, .references(HushfulSwap.schema, "id", onDelete: .cascade)).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(Wishlist.schema).deleteField("swap_id").update()
    }
}
