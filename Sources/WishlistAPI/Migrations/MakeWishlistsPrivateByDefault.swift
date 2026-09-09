import Fluent
import SQLKit
import Vapor

/// Keeps future database inserts safe when visibility is omitted. Existing
/// wishlist visibility choices are intentionally preserved.
struct MakeWishlistsPrivateByDefault: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Wishlist visibility migration requires PostgreSQL.")
        }

        // AddWishlistVisibility creates this column. This migration only
        // changes the default for future rows and leaves existing choices
        // untouched.
        try await sql.raw("ALTER TABLE \"wishlists\" ALTER COLUMN \"visibility\" SET DEFAULT 'private'").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Wishlist visibility migration requires PostgreSQL.")
        }

        try await sql.raw("ALTER TABLE \"wishlists\" ALTER COLUMN \"visibility\" SET DEFAULT 'public'").run()
    }
}
