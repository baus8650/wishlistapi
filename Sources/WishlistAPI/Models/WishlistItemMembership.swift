import Fluent
import Foundation

final class WishlistItemMembership: Model, @unchecked Sendable {
    static let schema = "wishlist_item_memberships"

    @ID(key: .id) var id: UUID?
    @Parent(key: "item_id") var item: WishlistItem
    @Parent(key: "wishlist_id") var wishlist: Wishlist
    @Field(key: "position") var position: Int

    init() {}
    init(itemID: UUID, wishlistID: UUID, position: Int = 0) {
        self.$item.id = itemID
        self.$wishlist.id = wishlistID
        self.position = position
    }
}
