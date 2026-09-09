import Fluent
import SQLKit
import Vapor

struct AddWishlistVisibility: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Wishlist visibility migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"wishlists\" ADD COLUMN IF NOT EXISTS \"visibility\" TEXT NOT NULL DEFAULT 'public'").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Wishlist visibility migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"wishlists\" DROP COLUMN IF EXISTS \"visibility\"").run()
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
