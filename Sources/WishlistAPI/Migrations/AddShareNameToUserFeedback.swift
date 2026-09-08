import Fluent

/// Adds the field used by UserFeedback after the original migration shipped
/// without it. Keeping this additive makes the migration safe for existing
/// production databases as well as fresh installs.
struct AddShareNameToUserFeedback: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .field("share_name", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .deleteField("share_name")
            .update()
    }
}
