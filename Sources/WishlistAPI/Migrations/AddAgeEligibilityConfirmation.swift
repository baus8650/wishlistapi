import Fluent
import SQLKit
import Vapor

/// Records the point at which a new account confirmed the minimum age. This
/// is an eligibility attestation, not independent age verification.
struct AddAgeEligibilityConfirmation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Age eligibility migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"age_confirmed_at\" TIMESTAMPTZ").run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("ALTER TABLE \"users\" DROP COLUMN IF EXISTS \"age_confirmed_at\"").run()
    }
}
