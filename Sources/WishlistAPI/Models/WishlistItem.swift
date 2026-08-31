//
//  WishlistItem.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent
import Vapor

final class WishlistItem: Model, Content {
    static let schema = "wishlist_items"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "wishlist_id")
    var wishlist: Wishlist

    @Field(key: "title")
    var title: String

    @OptionalField(key: "url")
    var url: String?

    // recipients see everything, so it's safe to return
    @OptionalField(key: "price")
    var price: Double?

    @OptionalField(key: "owner_note")
    var ownerNote: String?

    @Field(key: "quantity")
    var quantity: Int

    @Field(key: "position")
    var position: Int

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        wishlistId: UUID,
        title: String,
        url: String? = nil,
        price: Double? = nil,
        ownerNote: String? = nil,
        quantity: Int = 1
    ) {
        self.id = id
        self.$wishlist.id = wishlistId
        self.title = title
        self.url = url
        self.price = price
        self.ownerNote = ownerNote
        self.quantity = quantity
        self.position = 0
    }
}

// Swift 6 + Fluent models
extension WishlistItem: @unchecked Sendable {}
