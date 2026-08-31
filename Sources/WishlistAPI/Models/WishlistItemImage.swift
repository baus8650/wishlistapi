import Fluent
import Foundation

final class WishlistItemImage: Model, @unchecked Sendable {
    static let schema = "wishlist_item_images"

    @ID(key: .id) var id: UUID?
    @Parent(key: "item_id") var item: WishlistItem
    @Field(key: "data") var data: Data
    @Field(key: "content_type") var contentType: String

    init() {}

    init(itemID: UUID, data: Data, contentType: String) {
        self.$item.id = itemID
        self.data = data
        self.contentType = contentType
    }
}
