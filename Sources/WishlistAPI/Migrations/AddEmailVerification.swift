import Fluent
import Foundation

/// Adds verification without disrupting accounts that existed before the
/// feature shipped. Those accounts had already completed the old sign-up
/// process, so they are intentionally grandfathered in as verified.
struct AddEmailVerification: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(User.schema)
            .field("email_verified_at", .datetime)
            .update()

        try await User.query(on: database).filter(\.$emailVerifiedAt == nil)
            .set(\.$emailVerifiedAt, to: Date()).update()

        try await database.schema(EmailVerificationToken.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(EmailVerificationToken.schema).delete()
        try await database.schema(User.schema)
            .deleteField("email_verified_at")
            .update()
    }
}
