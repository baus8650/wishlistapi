import Fluent
import Vapor

final class User: Model {
    static let schema = "users"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "email")
    var email: String

    @Field(key: "password_hash")
    var passwordHash: String

    @OptionalField(key: "display_name")
    var displayName: String?

    @OptionalField(key: "username")
    var username: String?

    @Field(key: "is_discoverable")
    var isDiscoverable: Bool

    @Field(key: "friend_request_policy")
    var friendRequestPolicy: String

    @OptionalField(key: "avatar_data")
    var avatarData: Data?

    @OptionalField(key: "avatar_content_type")
    var avatarContentType: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, email: String, passwordHash: String, displayName: String? = nil) {
        self.id = id
        self.email = email
        self.passwordHash = passwordHash
        self.displayName = displayName
        self.isDiscoverable = false
        self.friendRequestPolicy = "everyone"
    }
}

extension User {
    /// Safe-to-return representation of a user (never includes passwordHash).
    struct Public: Content {
        let id: UUID?
        let email: String
        let displayName: String?
        let username: String?
        let isDiscoverable: Bool
        let friendRequestPolicy: String
        let hasAvatar: Bool
        let createdAt: Date?
        let updatedAt: Date?
    }

    func toPublic() -> Public {
        .init(
            id: self.id,
            email: self.email,
            displayName: self.displayName,
            username: self.username,
            isDiscoverable: self.isDiscoverable,
            friendRequestPolicy: self.friendRequestPolicy,
            hasAvatar: self.avatarData != nil,
            createdAt: self.createdAt,
            updatedAt: self.updatedAt
        )
    }
}

extension User: Authenticatable {}

// Fluent `Model` types are reference types with mutable properties, so they can't be safely
// verified as `Sendable` by the compiler. Vapor/Fluent commonly treats these as safe to pass
// around in request-handling contexts.
extension User: @unchecked Sendable {}
