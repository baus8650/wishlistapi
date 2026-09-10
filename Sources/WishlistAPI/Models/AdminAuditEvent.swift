import Fluent
import Vapor

final class AdminAuditEvent: Model, Content, @unchecked Sendable {
    static let schema = "admin_audit_events"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "admin_id") var admin: User?
    @Field(key: "action") var action: String
    @OptionalField(key: "target_type") var targetType: String?
    @OptionalField(key: "target_id") var targetID: UUID?
    @OptionalField(key: "metadata") var metadata: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(adminID: UUID, action: String, targetType: String? = nil, targetID: UUID? = nil, metadata: String? = nil) {
        self.$admin.id = adminID
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.metadata = metadata
    }
}
