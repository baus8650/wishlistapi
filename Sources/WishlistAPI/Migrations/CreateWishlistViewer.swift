//
//  CreateWishlistViewer.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent

struct CreateWishlistViewer: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_viewers")
            .id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("user_id", .uuid, .references("users", "id", onDelete: .setNull))
            .field("viewer_token_hash", .string)
            .field("display_name", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "wishlist_id", "viewer_token_hash")
            .unique(on: "wishlist_id", "user_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_viewers").delete()
    }
}
