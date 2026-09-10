import Fluent

struct CreateGooglePlayProPurchases: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("google_play_pro_purchases")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("purchase_token", .string, .required)
            .field("product_id", .string, .required)
            .field("order_id", .string)
            .field("purchased_at", .datetime, .required)
            .field("active", .bool, .required)
            .field("acknowledged", .bool, .required)
            .unique(on: "purchase_token")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("google_play_pro_purchases").delete()
    }
}
