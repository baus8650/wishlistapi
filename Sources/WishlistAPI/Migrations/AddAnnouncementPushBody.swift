import Fluent

struct AddAnnouncementPushBody: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(Announcement.schema).field("push_body", .string).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(Announcement.schema).deleteField("push_body").update()
    }
}
