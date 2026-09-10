import Fluent
import SQLKit
import Vapor

struct AddAdminSecurityControls: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError, reason: "Admin security migration requires PostgreSQL.") }
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"role\" TEXT NOT NULL DEFAULT 'user'").run()
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS \"admin_audit_events\" (
                \"id\" UUID NOT NULL PRIMARY KEY,
                \"admin_id\" UUID REFERENCES \"users\" (\"id\") ON DELETE SET NULL,
                \"action\" TEXT NOT NULL,
                \"target_type\" TEXT,
                \"target_id\" UUID,
                \"metadata\" TEXT,
                \"created_at\" TIMESTAMPTZ
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AdminAuditEvent.schema).delete()
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"role\"").run()
    }
}
