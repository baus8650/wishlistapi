import Fluent
import SQLKit
import Vapor

/// Adds the adult-only list display preference. It defaults to hidden so an
/// existing account does not unexpectedly see lists intended for adults.
struct AddAgeRestrictedListVisibilityPreference: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Age-restricted list migration requires PostgreSQL.")
        }

        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"show_age_restricted_lists\" BOOLEAN NOT NULL DEFAULT false").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Age-restricted list migration requires PostgreSQL.")
        }

        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"show_age_restricted_lists\"").run()
    }
}
