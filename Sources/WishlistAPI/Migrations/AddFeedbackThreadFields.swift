import Fluent

struct AddFeedbackThreadFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserFeedback.schema)
            .field("status", .string, .required, .sql(.default("open")))
            .field("archived", .bool, .required, .sql(.default(false)))
            .field("updated_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserFeedback.schema)
            .deleteField("status")
            .deleteField("archived")
            .deleteField("updated_at")
            .update()
    }
}
