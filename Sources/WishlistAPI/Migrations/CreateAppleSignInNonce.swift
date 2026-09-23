import Fluent

struct CreateAppleSignInNonce: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AppleSignInNonce.schema)
            .id()
            .field("nonce_hash", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "nonce_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(AppleSignInNonce.schema).delete()
    }
}
