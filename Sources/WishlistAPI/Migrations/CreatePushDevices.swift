import Fluent

struct CreatePushDevices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PushDevice.schema)
            .id()
            .field("user_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("token", .string, .required)
            .field("environment", .string, .required)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PushDevice.schema).delete()
    }
}
