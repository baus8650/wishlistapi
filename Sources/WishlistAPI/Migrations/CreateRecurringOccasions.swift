import Fluent

struct CreateRecurringOccasions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(RecurringOccasion.schema).id()
            .field("owner_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("name", .string, .required).field("name_search", .string, .required)
            .field("event_month", .int, .required).field("event_day", .int, .required)
            .field("reminder_month", .int, .required).field("reminder_day", .int, .required)
            .field("icon", .string, .required).field("color_hex", .string, .required)
            .field("last_created_year", .int).field("created_at", .datetime).field("updated_at", .datetime)
            .unique(on: "owner_id", "name_search", "event_month", "event_day").create()
    }
    func revert(on database: any Database) async throws { try await database.schema(RecurringOccasion.schema).delete() }
}
