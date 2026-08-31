import Fluent

struct CreateWebMetrics: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(WebMetricEvent.schema).id()
            .field("visitor_id", .string, .required)
            .field("path", .string, .required)
            .field("signed_in", .bool, .required)
            .field("created_at", .datetime)
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema(WebMetricEvent.schema).delete() }
}
