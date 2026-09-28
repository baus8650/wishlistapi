import Fluent
import SQLKit
import Vapor

enum AdminProGrantSchema {
    static let activeIndexName = "uq_admin_pro_grants_active_user"
    static let legacyConstraintName = "uq:admin_pro_grants.user_id+admin_pro_grants.active"

    static func createActiveUniqueIndex(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Admin Pro grant migration requires PostgreSQL.")
        }
        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS "\(activeIndexName)"
            ON "\(AdminProGrant.schema)" ("user_id")
            WHERE "active" = TRUE
            """).run()
    }
}

struct CreateAdminProGrants: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AdminProGrant.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("granted_by_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("revoked_by_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("reason", .string, .required)
            .field("active", .bool, .required)
            .field("created_at", .datetime)
            .field("revoked_at", .datetime)
            .create()

        // At most one active manual grant may exist for an account while
        // allowing an unlimited history of revoked grants.
        try await AdminProGrantSchema.createActiveUniqueIndex(on: database)
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS \"\(AdminProGrantSchema.activeIndexName)\"").run()
        try await database.schema(AdminProGrant.schema).delete()
    }
}
