import Fluent

struct CreateUserReports: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserReport.schema)
            .id()
            .field("reporter_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("reported_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("reason", .string, .required)
            .field("details", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(UserReport.schema).delete()
    }
}
