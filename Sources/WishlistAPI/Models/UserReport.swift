import Fluent
import Vapor

final class UserReport: Model, @unchecked Sendable {
    static let schema = "user_reports"

    @ID(key: .id) var id: UUID?
    @Parent(key: "reporter_id") var reporter: User
    @Parent(key: "reported_id") var reported: User
    @Field(key: "reason") var reason: String
    @Field(key: "details") var details: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(reporterID: UUID, reportedID: UUID, reason: String, details: String) {
        self.$reporter.id = reporterID
        self.$reported.id = reportedID
        self.reason = reason
        self.details = details
    }
}

struct UserReportDTO: Content {
    let id: UUID
    let reporterID: UUID
    let reporterEmail: String
    let reportedID: UUID
    let reportedEmail: String
    let reason: String
    let details: String
    let createdAt: Date?
}
