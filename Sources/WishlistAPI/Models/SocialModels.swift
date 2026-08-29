import Fluent
import Vapor

final class Friendship: Model, @unchecked Sendable {
    static let schema = "friendships"
    @ID(key: .id) var id: UUID?
    @Parent(key: "requester_id") var requester: User
    @Parent(key: "recipient_id") var recipient: User
    @Field(key: "status") var status: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(requesterID: UUID, recipientID: UUID, status: String = "pending") {
        self.$requester.id = requesterID; self.$recipient.id = recipientID; self.status = status
    }
}

final class UserBlock: Model, @unchecked Sendable {
    static let schema = "user_blocks"
    @ID(key: .id) var id: UUID?
    @Parent(key: "blocker_id") var blocker: User
    @Parent(key: "blocked_id") var blocked: User
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(blockerID: UUID, blockedID: UUID) { self.$blocker.id = blockerID; self.$blocked.id = blockedID }
}

final class FriendGroup: Model, @unchecked Sendable {
    static let schema = "friend_groups"
    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_id") var owner: User
    @Field(key: "name") var name: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(ownerID: UUID, name: String) { self.$owner.id = ownerID; self.name = name }
}

final class FriendGroupMember: Model, @unchecked Sendable {
    static let schema = "friend_group_members"
    @ID(key: .id) var id: UUID?
    @Parent(key: "group_id") var group: FriendGroup
    @Parent(key: "user_id") var user: User
    init() {}
    init(groupID: UUID, userID: UUID) { self.$group.id = groupID; self.$user.id = userID }
}

final class WishlistAudienceGrant: Model, @unchecked Sendable {
    static let schema = "wishlist_audience_grants"
    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @OptionalParent(key: "user_id") var user: User?
    @OptionalParent(key: "group_id") var group: FriendGroup?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    init() {}
    init(wishlistID: UUID, userID: UUID? = nil, groupID: UUID? = nil) {
        self.$wishlist.id = wishlistID
        if let userID { self.$user.id = userID }
        if let groupID { self.$group.id = groupID }
    }
}

final class SocialWishlistAccess: Model, @unchecked Sendable {
    static let schema = "social_wishlist_access"
    @ID(key: .id) var id: UUID?
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Parent(key: "user_id") var user: User
    @Parent(key: "viewer_id") var viewer: WishlistViewer
    init() {}
    init(wishlistID: UUID, userID: UUID, viewerID: UUID) {
        self.$wishlist.id = wishlistID; self.$user.id = userID; self.$viewer.id = viewerID
    }
}
