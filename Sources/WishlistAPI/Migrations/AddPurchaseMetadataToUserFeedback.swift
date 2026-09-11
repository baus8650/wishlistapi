import Fluent

/// Adds the non-secret metadata administrators need to review purchase claims.
/// Store tokens and signed transaction payloads are never persisted.
struct AddPurchaseMetadataToUserFeedback: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .field("purchase_provider", .string)
            .field("purchase_order_id", .string)
            .field("purchase_at", .datetime)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .deleteField("purchase_provider")
            .deleteField("purchase_order_id")
            .deleteField("purchase_at")
            .update()
    }
}
