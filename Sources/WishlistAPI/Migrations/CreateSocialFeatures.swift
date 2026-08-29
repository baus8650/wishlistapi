import Fluent

struct AddSocialProfileFields: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("users")
            .field("username", .string)
            .field("is_discoverable", .bool, .required, .sql(.default(false)))
            .field("friend_request_policy", .string, .required, .sql(.default("everyone")))
            .unique(on: "username")
            .update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("users").deleteUnique(on: "username").deleteField("friend_request_policy").deleteField("is_discoverable").deleteField("username").update()
    }
}

struct CreateSocialFeatures: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("friendships").id()
            .field("requester_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("recipient_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("status", .string, .required).field("created_at", .datetime).field("updated_at", .datetime)
            .unique(on: "requester_id", "recipient_id").create()
        try await database.schema("user_blocks").id()
            .field("blocker_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("blocked_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("created_at", .datetime).unique(on: "blocker_id", "blocked_id").create()
        try await database.schema("friend_groups").id()
            .field("owner_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("name", .string, .required).field("created_at", .datetime).create()
        try await database.schema("friend_group_members").id()
            .field("group_id", .uuid, .required, .references("friend_groups", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .unique(on: "group_id", "user_id").create()
        try await database.schema("wishlist_audience_grants").id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("user_id", .uuid, .references("users", "id", onDelete: .cascade))
            .field("group_id", .uuid, .references("friend_groups", "id", onDelete: .cascade))
            .field("created_at", .datetime).create()
        try await database.schema("social_wishlist_access").id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("viewer_id", .uuid, .required, .references("wishlist_viewers", "id", onDelete: .cascade))
            .unique(on: "wishlist_id", "user_id").unique(on: "viewer_id").create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("social_wishlist_access").delete()
        try await database.schema("wishlist_audience_grants").delete()
        try await database.schema("friend_group_members").delete()
        try await database.schema("friend_groups").delete()
        try await database.schema("user_blocks").delete()
        try await database.schema("friendships").delete()
    }
}
