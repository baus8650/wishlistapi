import Fluent
import Foundation

final class AuthIdentity: Model, @unchecked Sendable {
    static let schema = "auth_identities"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "user_id")
    var user: User

    @Field(key: "provider")
    var provider: String

    @Field(key: "provider_subject")
    var providerSubject: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, userID: UUID, provider: String, providerSubject: String) {
        self.id = id
        self.$user.id = userID
        self.provider = provider
        self.providerSubject = providerSubject
    }
}
