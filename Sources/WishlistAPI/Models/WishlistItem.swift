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

    @OptionalField(key: "sale_price")
    var salePrice: Double?

    @OptionalField(key: "sale_discount_percent")
    var saleDiscountPercent: Double?

    @OptionalField(key: "sale_ends_at")
    var saleEndsAt: Date?

    @OptionalField(key: "sale_reminder_sent_for_end")
    var saleReminderSentForEnd: Date?

    var activeSalePrice: Double? {
        guard let price, saleEndsAt.map({ $0 > Date() }) ?? true else { return nil }
        if let salePrice { return salePrice }
        if let saleDiscountPercent { return (price * (1 - saleDiscountPercent / 100) * 100).rounded() / 100 }
        return nil
    }

    @OptionalField(key: "owner_note")
    var ownerNote: String?

    @Field(key: "item_type")
    var itemType: String

    @OptionalField(key: "contribution_goal")
    var contributionGoal: Double?

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
        quantity: Int = 1,
        itemType: String = "wish",
        contributionGoal: Double? = nil
    ) {
        self.id = id
        self.$wishlist.id = wishlistId
        self.title = title
        self.url = url
        self.price = price
        self.ownerNote = ownerNote
        self.quantity = quantity
        self.itemType = itemType
        self.contributionGoal = contributionGoal
        self.position = 0
    }
}

// Swift 6 + Fluent models
extension WishlistItem: @unchecked Sendable {}
