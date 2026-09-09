import Fluent

struct CreateAuthRateLimitEvents: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AuthRateLimitEvent.schema)
            .id()
            .field("scope", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AuthRateLimitEvent.schema).delete()
    }
}
