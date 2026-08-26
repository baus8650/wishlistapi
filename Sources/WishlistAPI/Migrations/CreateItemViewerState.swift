//
//  CreateItemViewerState.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent

struct CreateItemViewerState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("item_viewer_state")
            .id()
            .field("item_id", .uuid, .required, .references("wishlist_items", "id", onDelete: .cascade))
            .field("viewer_id", .uuid, .required, .references("wishlist_viewers", "id", onDelete: .cascade))
            .field("purchased", .bool, .required)
            .field("note", .string)
            .field("share_name", .bool, .required, .sql(.default(false)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "item_id", "viewer_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("item_viewer_state").delete()
    }
}
