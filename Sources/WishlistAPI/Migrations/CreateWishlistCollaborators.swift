import Fluent

struct CreateWishlistCollaborators: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists")
            .field("collaboration_mode", .string, .required, .sql(.default("our_wishlist")))
            .update()
        try await database.schema("wishlist_collaborators")
            .id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime)
            .unique(on: "wishlist_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_collaborators").delete()
        try await database.schema("wishlists").deleteField("collaboration_mode").update()
    }
}
