import Fluent

struct AddAnnouncementDismissals: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(AnnouncementDelivery.schema).field("dismissed_at", .datetime).update()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(AnnouncementDelivery.schema).deleteField("dismissed_at").update()
    }
}
