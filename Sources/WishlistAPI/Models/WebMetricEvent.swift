import Fluent
import Foundation

final class WebMetricEvent: Model, @unchecked Sendable {
    static let schema = "web_metric_events"
    @ID(key: .id) var id: UUID?
    @Field(key: "visitor_id") var visitorID: String
    @Field(key: "path") var path: String
    @Field(key: "signed_in") var signedIn: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(visitorID: String, path: String, signedIn: Bool) { self.visitorID = visitorID; self.path = path; self.signedIn = signedIn }
}
