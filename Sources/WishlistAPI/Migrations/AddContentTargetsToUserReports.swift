import Fluent
import SQLKit
import Vapor

struct AddContentTargetsToUserReports: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Report target migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"user_reports\" ADD COLUMN IF NOT EXISTS \"target_type\" TEXT").run()
        try await sql.raw("ALTER TABLE \"user_reports\" ADD COLUMN IF NOT EXISTS \"target_id\" UUID").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Report target migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"user_reports\" DROP COLUMN IF EXISTS \"target_id\"").run()
        try await sql.raw("ALTER TABLE \"user_reports\" DROP COLUMN IF EXISTS \"target_type\"").run()
    }
}
