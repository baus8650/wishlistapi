//
//  ItemViewerState.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent
import Vapor

final class ItemViewerState: Model, Content {
    static let schema = "item_viewer_state"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "item_id")
    var item: WishlistItem

    @Parent(key: "viewer_id")
    var viewer: WishlistViewer

    @Field(key: "purchased")
    var purchased: Bool

    @Field(key: "purchased_quantity")
    var purchasedQuantity: Int
    
    @Field(key: "share_name")
    var shareName: Bool

    @OptionalField(key: "note")
    var note: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(id: UUID? = nil, itemId: UUID, viewerId: UUID, purchased: Bool, purchasedQuantity: Int = 0, note: String? = nil, shareName: Bool = false) {
        self.id = id
        self.$item.id = itemId
        self.$viewer.id = viewerId
        self.purchased = purchased
        self.purchasedQuantity = purchasedQuantity
        self.note = note
        self.shareName = shareName
    }
}

extension ItemViewerState: @unchecked Sendable {}
