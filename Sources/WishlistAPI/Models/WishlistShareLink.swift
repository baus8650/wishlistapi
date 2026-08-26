//
//  WishlistShareLink.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent
import Vapor

final class WishlistShareLink: Model, Content {
    static let schema = "wishlist_share_links"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "wishlist_id")
    var wishlist: Wishlist

    // store SHA256 hex of the share token
    @Field(key: "token_hash")
    var tokenHash: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, wishlistId: UUID, tokenHash: String) {
        self.id = id
        self.$wishlist.id = wishlistId
        self.tokenHash = tokenHash
    }
}

extension WishlistShareLink: @unchecked Sendable {}
