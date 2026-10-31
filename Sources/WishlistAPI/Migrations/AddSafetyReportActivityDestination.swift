import Fluent

struct AddSafetyReportActivityDestination: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("activity_notifications").field("report_id", .uuid).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("activity_notifications").deleteField("report_id").update()
    }
}
