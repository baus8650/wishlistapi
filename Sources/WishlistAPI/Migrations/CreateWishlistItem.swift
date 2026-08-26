//
//  CreateWishlistItem.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent

struct CreateWishlistItem: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlist_items")
            .id()
            .field("wishlist_id", .uuid, .required, .references("wishlists", "id", onDelete: .cascade))
            .field("title", .string, .required)
            .field("url", .string)
            .field("price", .double)
            .field("owner_note", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlist_items").delete()
    }
}
