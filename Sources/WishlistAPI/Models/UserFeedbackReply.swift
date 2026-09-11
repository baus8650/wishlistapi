import Fluent
import Vapor

final class UserFeedbackReply: Model, Content {
    static let schema = "user_feedback_replies"

    @ID(key: .id) var id: UUID?
    @Parent(key: "feedback_id") var feedback: UserFeedback
    @Parent(key: "author_id") var author: User
    @Field(key: "author_role") var authorRole: String
    @Field(key: "message") var message: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(feedbackID: UUID, authorID: UUID, authorRole: String, message: String) {
        self.$feedback.id = feedbackID
        self.$author.id = authorID
        self.authorRole = authorRole
        self.message = message
    }
}

extension UserFeedbackReply: @unchecked Sendable {}
