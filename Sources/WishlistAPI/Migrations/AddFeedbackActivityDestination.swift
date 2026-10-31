import Fluent

struct AddFeedbackActivityDestination: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("activity_notifications")
            .field("feedback_id", .uuid)
            .field("feedback_admin", .bool)
            .update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("activity_notifications")
            .deleteField("feedback_id").deleteField("feedback_admin").update()
    }
}
