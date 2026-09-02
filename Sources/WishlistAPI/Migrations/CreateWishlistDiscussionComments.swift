import Fluent

struct CreateWishlistDiscussionComments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_discussion_comments")
            .id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("viewer_id", .uuid, .required, .references("wishlist_viewers", "id", onDelete: .cascade))
            .field("message", .string, .required)
            .field("share_name", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_discussion_comments").delete()
    }
}
