import Fluent

struct AddWishlistVisibility: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists")
            .field("visibility", .string, .required, .sql(.default("public")))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlists").deleteField("visibility").update()
    }
}

struct CreatePublicWishlistAccess: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("public_wishlist_access").id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("viewer_id", .uuid, .required, .references("wishlist_viewers", "id", onDelete: .cascade))
            .unique(on: "wishlist_id", "user_id")
            .unique(on: "viewer_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("public_wishlist_access").delete()
    }
}
