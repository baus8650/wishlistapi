import Fluent
import Vapor

final class PushDevice: Model, @unchecked Sendable {
    static let schema = "push_devices"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "token") var token: String
    @Field(key: "environment") var environment: String
    @Field(key: "platform") var platform: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
    init(userID: UUID, token: String, environment: String, platform: String = "ios") {
        self.$user.id = userID
        self.token = token
        self.environment = environment
        self.platform = platform
    }
}
