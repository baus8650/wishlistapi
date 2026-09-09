import Fluent
import SQLKit
import Vapor

/// Lets security-sensitive account changes invalidate previously issued JWTs.
struct AddAuthenticationVersion: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Authentication version migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"authentication_version\" INTEGER NOT NULL DEFAULT 0").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Authentication version migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"authentication_version\"").run()
    }
}
