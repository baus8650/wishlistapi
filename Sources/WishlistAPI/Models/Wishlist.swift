//
//  Wishlist.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Fluent
import Vapor

final class Wishlist: Model, Content {
    static let schema = "wishlists"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "owner_user_id")
    var owner: User

    @Field(key: "title")
    var title: String

    @Field(key: "visibility")
    var visibility: String

    @Field(key: "position")
    var position: Int

    @Field(key: "collaboration_mode")
    var collaborationMode: String

    @OptionalField(key: "occasion_date")
    var occasionDate: Date?

    @Field(key: "reminder_enabled")
    var reminderEnabled: Bool

    @OptionalField(key: "icon")
    var icon: String?

    @OptionalField(key: "color_theme")
    var colorTheme: String?

    @Field(key: "is_archived")
    var isArchived: Bool

    // MARK: Wishlist Settings

    @Field(key: "show_purchaser_names")
    var showPurchaserNames: Bool

    @Field(key: "allow_multiple_purchases")
    var allowMultiplePurchases: Bool

    @Field(key: "allow_notes")
    var allowNotes: Bool

    @Field(key: "auto_lock_on_purchase")
    var autoLockOnPurchase: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        ownerUserId: UUID,
        title: String,
        visibility: String = "public",
        showPurchaserNames: Bool = false,
        allowMultiplePurchases: Bool = false,
        allowNotes: Bool = true,
        autoLockOnPurchase: Bool = false
    ) {
        self.id = id
        self.$owner.id = ownerUserId
        self.title = title
        self.visibility = visibility
        self.position = 0
        self.collaborationMode = "our_wishlist"
        self.reminderEnabled = false
        self.isArchived = false
        self.showPurchaserNames = showPurchaserNames
        self.allowMultiplePurchases = allowMultiplePurchases
        self.allowNotes = allowNotes
        self.autoLockOnPurchase = autoLockOnPurchase
    }
}

// Swift 6 + Fluent models
extension Wishlist: @unchecked Sendable {}
