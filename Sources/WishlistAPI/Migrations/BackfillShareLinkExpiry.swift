import Fluent
import SQLKit
import Vapor

/// Applies the same finite lifetime to links created before expiry was added.
/// Without this backfill, old bearer links would remain indefinitely valid.
struct BackfillShareLinkExpiry: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError, reason: "Share-link expiry migration requires PostgreSQL.") }
        try await sql.raw("UPDATE \"wishlist_share_links\" SET \"expires_at\" = COALESCE(\"created_at\", NOW()) + INTERVAL '30 days' WHERE \"expires_at\" IS NULL").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("UPDATE \"wishlist_share_links\" SET \"expires_at\" = NULL").run()
    }
}

