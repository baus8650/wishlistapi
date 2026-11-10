import Fluent
import SQLKit

struct AddAnnouncementReadState: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(AnnouncementDelivery.schema).field("read_at", .datetime).update()
        if let sql = db as? any SQLDatabase {
            try await sql.raw("UPDATE announcement_deliveries SET read_at = dismissed_at WHERE dismissed_at IS NOT NULL").run()
        }
    }
    func revert(on db: any Database) async throws {
        try await db.schema(AnnouncementDelivery.schema).deleteField("read_at").update()
    }
}
