import Fluent
import Vapor

final class Announcement: Model, @unchecked Sendable {
    static let schema = "announcements"
    @ID(key: .id) var id: UUID?
    @Field(key: "title") var title: String
    @OptionalField(key: "push_body") var pushBody: String?
    @Field(key: "message") var message: String
    @OptionalField(key: "recipient_ids") var recipientIDs: [UUID]?
    @Field(key: "recipient_count") var recipientCount: Int
    @OptionalParent(key: "admin_id") var admin: User?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(id: UUID, title: String, message: String, adminID: UUID, recipientCount: Int, recipientIDs: [UUID]? = nil, pushBody: String? = nil) {
        self.id = id; self.title = title; self.message = message; self.pushBody = pushBody
        self.$admin.id = adminID; self.recipientCount = recipientCount; self.recipientIDs = recipientIDs
    }
}

final class AnnouncementDelivery: Model, @unchecked Sendable {
    static let schema = "announcement_deliveries"
    @ID(key: .id) var id: UUID?
    @Parent(key: "announcement_id") var announcement: Announcement
    @Parent(key: "user_id") var user: User
    @Field(key: "processed") var processed: Bool
    @OptionalField(key: "read_at") var readAt: Date?
    @OptionalField(key: "dismissed_at") var dismissedAt: Date?
    init() {}
    init(announcementID: UUID, userID: UUID) {
        self.$announcement.id = announcementID; self.$user.id = userID; self.processed = false
    }
}
