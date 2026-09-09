import Fluent
import SQLKit
import Vapor

/// Moves mature-content status from an age-derived value to an explicit,
/// owner-controlled opt-in. Existing accounts never had this control, so
/// their compatibility flags are reset to the safe default.
struct AddExplicitMatureContentControls: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Mature-content migration requires PostgreSQL.")
        }

        try await sql.raw("ALTER TABLE \"wishlists\" ADD COLUMN IF NOT EXISTS \"mature_content_enabled\" BOOLEAN NOT NULL DEFAULT false").run()
        try await sql.raw("UPDATE \"users\" SET \"mature_profile_enabled\" = false").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Mature-content migration requires PostgreSQL.")
        }

        try await sql.raw("ALTER TABLE \"wishlists\" DROP COLUMN IF EXISTS \"mature_content_enabled\"").run()
    }
}
