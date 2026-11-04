import Fluent

struct CreatePersonalGifts: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("personal_gifts").id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("price", .double)
            .field("currency_code", .string)
            .field("url", .string)
            .field("notes", .string)
            .field("quantity", .int, .required)
            .field("purchased_at", .datetime, .required)
            .field("recipients", .json, .required)
            .field("created_at", .datetime).field("updated_at", .datetime).create()
    }
    func revert(on db: any Database) async throws { try await db.schema("personal_gifts").delete() }
}
