//
//  WishlistViewer.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent
import Vapor

final class WishlistViewer: Model, Content {
    static let schema = "wishlist_viewers"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "wishlist_id")
    var wishlist: Wishlist

    // Optional: later you can link a viewer to an account
    @OptionalParent(key: "user_id")
    var user: User?

    // device-level identity (SHA256 hex of viewerToken)
    @OptionalField(key: "viewer_token_hash")
    var viewerTokenHash: String?

    @OptionalField(key: "display_name")
    var displayName: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        wishlistId: UUID,
        viewerTokenHash: String? = nil,
        displayName: String? = nil,
        userId: UUID? = nil
    ) {
        self.id = id
        self.$wishlist.id = wishlistId
        self.viewerTokenHash = viewerTokenHash
        self.displayName = displayName
        if let userId { self.$user.id = userId }
    }
}

extension WishlistViewer: @unchecked Sendable {}
