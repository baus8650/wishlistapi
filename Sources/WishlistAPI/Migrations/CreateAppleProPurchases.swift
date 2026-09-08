import Fluent

struct CreateAppleProPurchases: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("apple_pro_purchases")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("original_transaction_id", .string, .required)
            .field("signed_at", .datetime, .required)
            .field("active", .bool, .required)
            .unique(on: "original_transaction_id")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("apple_pro_purchases").delete()
    }
}
