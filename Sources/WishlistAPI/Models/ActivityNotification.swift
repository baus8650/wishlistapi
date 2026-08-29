import Fluent
import Vapor

final class ActivityNotification: Model, @unchecked Sendable {
    static let schema = "activity_notifications"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @OptionalParent(key: "actor_id") var actor: User?
    @OptionalParent(key: "wishlist_id") var wishlist: Wishlist?
    @Field(key: "kind") var kind: String
    @Field(key: "title") var title: String
    @Field(key: "message") var message: String
    @OptionalField(key: "read_at") var readAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(userID: UUID, actorID: UUID? = nil, wishlistID: UUID? = nil, kind: String, title: String, message: String) {
        self.$user.id = userID
        if let actorID { self.$actor.id = actorID }
        if let wishlistID { self.$wishlist.id = wishlistID }
        self.kind = kind; self.title = title; self.message = message
    }
}
