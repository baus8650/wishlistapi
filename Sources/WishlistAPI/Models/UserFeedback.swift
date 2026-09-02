import Fluent
import Vapor

final class UserFeedback: Model, Content {
    static let schema = "user_feedback"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "category") var category: String
    @Field(key: "message") var message: String
    @Field(key: "platform") var platform: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, category: String, message: String, platform: String) {
        self.id = id
        self.$user.id = userID
        self.category = category
        self.message = message
        self.platform = platform
    }
}

extension UserFeedback: @unchecked Sendable {}
