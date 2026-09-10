import Fluent
import SQLKit
import Vapor

struct AddAdminTOTP: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError, reason: "Admin MFA migration requires PostgreSQL.") }
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"admin_totp_secret\" TEXT").run()
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"admin_totp_enabled\" BOOLEAN NOT NULL DEFAULT FALSE").run()
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"admin_recovery_codes\" TEXT").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"admin_recovery_codes\"").run()
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"admin_totp_enabled\"").run()
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"admin_totp_secret\"").run()
    }
}
