import Fluent

struct AddActivityItemID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("activity_notifications").field("item_id", .uuid).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("activity_notifications").deleteField("item_id").update()
    }
}
