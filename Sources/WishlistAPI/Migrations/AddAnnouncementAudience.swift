import Fluent

struct AddAnnouncementAudience: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Announcement.schema).field("recipient_ids", .array(of: .uuid)).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(Announcement.schema).deleteField("recipient_ids").update()
    }
}
