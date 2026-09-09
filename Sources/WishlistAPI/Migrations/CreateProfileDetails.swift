import Fluent

struct CreateProfileDetails: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_profile_attributes").id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("label", .string, .required)
            .field("label_search", .string, .required)
            .field("value", .string, .required)
            .field("visibility", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "user_id", "label_search")
            .create()

        try await database.schema("birthday_alerts").id()
            .field("subscriber_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("subject_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("reminder_days_before", .int, .required, .sql(.default(7)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "subscriber_id", "subject_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("birthday_alerts").delete()
        try await database.schema("user_profile_attributes").delete()
    }
}
