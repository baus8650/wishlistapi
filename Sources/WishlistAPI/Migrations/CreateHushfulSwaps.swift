import Fluent

struct CreateHushfulSwaps: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(HushfulSwap.schema).id()
            .field("owner_id", .uuid, .required, .references(User.schema, "id", onDelete: .cascade))
            .field("invite_token", .string, .required)
            .field("state", .json, .required)
            .unique(on: "invite_token").create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(HushfulSwap.schema).delete()
    }
}
