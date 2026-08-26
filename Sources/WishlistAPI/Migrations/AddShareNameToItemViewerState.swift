//
//  AddShareNameToItemViewerState.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent

struct AddShareNameToItemViewerState: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("item_viewer_state")
            .field("share_name", .bool, .required, .sql(.default(false)))
            .update()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("item_viewer_state")
            .deleteField("share_name")
            .update()
    }
}
