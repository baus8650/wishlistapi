import Fluent
import Foundation

/// A short-lived, single-use challenge issued before a native Sign in with
/// Apple request. Only its SHA-256 digest is persisted, so a database read
/// cannot be used to replay an in-flight Apple identity token.
final class AppleSignInNonce: Model, @unchecked Sendable {
    static let schema = "apple_sign_in_nonces"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "nonce_hash")
    var nonceHash: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, nonceHash: String, expiresAt: Date) {
        self.id = id
        self.nonceHash = nonceHash
        self.expiresAt = expiresAt
    }
}
