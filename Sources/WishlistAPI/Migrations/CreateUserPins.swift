import Fluent

struct CreateUserPins: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_pins").id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("target_type", .string, .required)
            .field("target_id", .uuid, .required)
            .field("position", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .unique(on: "user_id", "target_type", "target_id")
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema("user_pins").delete() }
}
