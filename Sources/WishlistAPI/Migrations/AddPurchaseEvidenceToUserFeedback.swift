import Fluent

/// Stores only server-derived purchase status for Purchase feedback. Raw
/// Apple JWS strings and Google Play tokens are deliberately never persisted.
struct AddPurchaseEvidenceToUserFeedback: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .field("purchase_evidence", .string)
            .field("purchase_evidence_details", .string)
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("user_feedback")
            .deleteField("purchase_evidence")
            .deleteField("purchase_evidence_details")
            .update()
    }
}
