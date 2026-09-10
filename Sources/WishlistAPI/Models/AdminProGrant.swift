import Fluent
import Foundation

/// A support-issued Pro entitlement. Store purchases remain bound to the
/// account that completed the purchase; this record is only an auditable
/// recovery path when a verified payment did not unlock the account.
final class AdminProGrant: Model, @unchecked Sendable {
    static let schema = "admin_pro_grants"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @OptionalParent(key: "granted_by_id") var grantedBy: User?
    @OptionalParent(key: "revoked_by_id") var revokedBy: User?
    @Field(key: "reason") var reason: String
    @Field(key: "active") var active: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "revoked_at") var revokedAt: Date?

    init() {}

    init(userID: UUID, grantedByID: UUID, reason: String) {
        self.$user.id = userID
        self.$grantedBy.id = grantedByID
        self.reason = reason
        self.active = true
    }
}
