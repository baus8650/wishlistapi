import Fluent
import SQLKit
import Vapor

/// Grants lifetime Pro to every account that exists when this migration runs.
/// New accounts receive the column default (`false`) and can unlock through StoreKit.
struct GrandfatherExistingUsersIntoPro: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // A previous deployment may have added the column before recording
        // this migration. Keep retries safe for the existing staging database.
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Lifetime Pro migration requires PostgreSQL.")
        }
        try await sql.raw("ALTER TABLE \"users\" ADD COLUMN IF NOT EXISTS \"has_lifetime_pro\" BOOLEAN NOT NULL DEFAULT false").run()

        let existingUsers = try await User.query(on: database).all()
        for user in existingUsers {
            user.hasLifetimePro = true
            try await user.save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(User.schema)
            .deleteField("has_lifetime_pro")
            .update()
    }
}
