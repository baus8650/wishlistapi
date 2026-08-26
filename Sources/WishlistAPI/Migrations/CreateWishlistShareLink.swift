//
//  CreateWishlistShareLink.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent

struct CreateWishlistShareLink: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_share_links")
            .id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_share_links").delete()
    }
}
