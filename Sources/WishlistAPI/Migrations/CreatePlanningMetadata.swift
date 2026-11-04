import Fluent

struct CreatePlanningMetadata: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("wishlist_gift_recipients").id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("recipients", .json, .required).unique(on: "wishlist_id").create()
        try await db.schema("comment_reactions").id()
            .field("viewer_id", .uuid, .required, .references("wishlist_viewers", "id", onDelete: .cascade))
            .field("note_id", .uuid, .references("item_viewer_state", "id", onDelete: .cascade))
            .field("comment_id", .uuid, .references("wishlist_discussion_comments", "id", onDelete: .cascade))
            .field("emoji", .string, .required)
            .unique(on: "viewer_id", "note_id", "emoji")
            .unique(on: "viewer_id", "comment_id", "emoji").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema("comment_reactions").delete()
        try await db.schema("wishlist_gift_recipients").delete()
    }
}
