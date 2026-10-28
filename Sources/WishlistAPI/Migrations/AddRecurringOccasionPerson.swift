import Fluent
import SQLKit

struct AddRecurringOccasionPerson: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(RecurringOccasion.schema)
            .field("person_id", .uuid, .references(User.schema, "id", onDelete: .setNull))
            .field("notifications_enabled", .bool, .required, .sql(.default(true))).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(RecurringOccasion.schema)
            .deleteField("person_id").deleteField("notifications_enabled").update()
    }
}
