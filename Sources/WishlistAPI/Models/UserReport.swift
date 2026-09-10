import Fluent
import Vapor

final class UserReport: Model, @unchecked Sendable {
    static let schema = "user_reports"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "reporter_id") var reporter: User?
    @Parent(key: "reported_id") var reported: User
    @Field(key: "reason") var reason: String
    @Field(key: "details") var details: String
    @OptionalField(key: "target_type") var targetType: String?
    @OptionalField(key: "target_id") var targetID: UUID?
    @Field(key: "status") var status: String
    @OptionalField(key: "resolved_at") var resolvedAt: Date?
    @OptionalParent(key: "moderator_id") var moderator: User?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(reporterID: UUID? = nil, reportedID: UUID, reason: String, details: String, targetType: String? = "account", targetID: UUID? = nil) {
        if let reporterID { self.$reporter.id = reporterID }
        self.$reported.id = reportedID
        self.reason = reason
        self.details = details
        self.targetType = targetType
        self.targetID = targetID ?? reportedID
        self.status = "open"
    }
}

struct UserReportDTO: Content {
    let id: UUID
    let reporterID: UUID?
    let reporterEmail: String?
    let reportedID: UUID
    let reportedEmail: String
    let reason: String
    let details: String
    let targetType: String?
    let targetID: UUID?
    let status: String
    let resolvedAt: Date?
    let createdAt: Date?
}
