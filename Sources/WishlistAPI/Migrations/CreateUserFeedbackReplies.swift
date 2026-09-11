import Fluent

struct CreateUserFeedbackReplies: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserFeedbackReply.schema)
            .id()
            .field("feedback_id", .uuid, .required, .references(UserFeedback.schema, "id", onDelete: .cascade))
            .field("author_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("author_role", .string, .required)
            .field("message", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserFeedbackReply.schema).delete()
    }
}
