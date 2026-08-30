import Fluent
import Foundation

final class UserPin: Model, @unchecked Sendable {
    static let schema = "user_pins"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "target_type") var targetType: String
    @Field(key: "target_id") var targetID: UUID
    @Field(key: "position") var position: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(userID: UUID, targetType: String, targetID: UUID, position: Int = 0) {
        self.$user.id = userID; self.targetType = targetType; self.targetID = targetID; self.position = position
    }
}
