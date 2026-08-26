//
//  CreateWishlist.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent

struct CreateWishlist: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("wishlists")
            .id()
            .field("owner_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("title", .string, .required)
            // Wishlist settings (defaults)
            .field("show_purchaser_names", .bool, .required, .sql(.default(false)))
            .field("allow_multiple_purchases", .bool, .required, .sql(.default(false)))
            .field("allow_notes", .bool, .required, .sql(.default(true)))
            .field("auto_lock_on_purchase", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("wishlists").delete()
    }
}
