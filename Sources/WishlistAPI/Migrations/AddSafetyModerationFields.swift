import Fluent
import SQLKit
import Vapor

struct AddSafetyModerationFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError, reason: "Safety moderation migration requires PostgreSQL.") }
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"terms_accepted_at\" TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"terms_version\" TEXT").run()
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"suspended_at\" TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE \"user_reports\" ADD COLUMN IF NOT EXISTS \"status\" TEXT NOT NULL DEFAULT 'open'").run()
        try await sql.raw("ALTER TABLE \"user_reports\" ADD COLUMN IF NOT EXISTS \"resolved_at\" TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE \"user_reports\" ADD COLUMN IF NOT EXISTS \"moderator_id\" UUID REFERENCES \"users\" (\"id\") ON DELETE SET NULL").run()
        try await sql.raw("ALTER TABLE \"wishlist_share_links\" ADD COLUMN IF NOT EXISTS \"expires_at\" TIMESTAMPTZ").run()
        try await sql.raw("ALTER TABLE \"user_reports\" ALTER COLUMN \"reporter_id\" DROP NOT NULL").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE \"user_reports\" DROP COLUMN IF EXISTS \"moderator_id\"").run()
        try await sql.raw("ALTER TABLE \"user_reports\" DROP COLUMN IF EXISTS \"resolved_at\"").run()
        try await sql.raw("ALTER TABLE \"user_reports\" DROP COLUMN IF EXISTS \"status\"").run()
        try await sql.raw("ALTER TABLE \"wishlist_share_links\" DROP COLUMN IF EXISTS \"expires_at\"").run()
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"suspended_at\"").run()
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"terms_version\"").run()
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"terms_accepted_at\"").run()
    }
}
