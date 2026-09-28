import Fluent
import SQLKit
import Vapor

/// Replaces the original `(user_id, active)` unique constraint. That
/// constraint allowed only one revoked row per account, so revoking a later
/// grant could fail with PostgreSQL error 23505. A partial unique index gives
/// the intended invariant: one active grant, unlimited revoked history.
struct RepairAdminProGrantUniqueness: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Admin Pro grant migration requires PostgreSQL.")
        }

        try await sql.raw("""
            ALTER TABLE "\(AdminProGrant.schema)"
            DROP CONSTRAINT IF EXISTS "\(AdminProGrantSchema.legacyConstraintName)"
            """).run()

        try await AdminProGrantSchema.createActiveUniqueIndex(on: database)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        // Do not restore the old composite constraint: a valid database may
        // already contain multiple revoked grants by the time this migration
        // is reverted.
        try await sql.raw("DROP INDEX IF EXISTS \"\(AdminProGrantSchema.activeIndexName)\"").run()
    }
}
