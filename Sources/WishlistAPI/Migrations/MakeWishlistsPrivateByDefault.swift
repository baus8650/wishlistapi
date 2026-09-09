import Fluent

/// Keeps future database inserts safe when visibility is omitted. Existing
/// wishlist visibility choices are intentionally preserved.
struct MakeWishlistsPrivateByDefault: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists")
            .field("visibility", .string, .required, .sql(.default("private")))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlists")
            .field("visibility", .string, .required, .sql(.default("public")))
            .update()
    }
}
