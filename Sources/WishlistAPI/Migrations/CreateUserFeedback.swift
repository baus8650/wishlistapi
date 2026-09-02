import Fluent

struct CreateUserFeedback: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("category", .string, .required)
            .field("message", .string, .required)
            .field("platform", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_feedback").delete()
    }
}
