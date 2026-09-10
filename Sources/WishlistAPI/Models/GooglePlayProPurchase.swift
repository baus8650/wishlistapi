import Foundation
import Fluent

final class GooglePlayProPurchase: Model, @unchecked Sendable {
    static let schema = "google_play_pro_purchases"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "purchase_token") var purchaseToken: String
    @Field(key: "product_id") var productID: String
    @OptionalField(key: "order_id") var orderID: String?
    @Field(key: "purchased_at") var purchasedAt: Date
    @Field(key: "active") var active: Bool
    @Field(key: "acknowledged") var acknowledged: Bool

    init() {}

    init(userID: UUID, purchaseToken: String, productID: String, orderID: String?, purchasedAt: Date, active: Bool, acknowledged: Bool) {
        self.$user.id = userID
        self.purchaseToken = purchaseToken
        self.productID = productID
        self.orderID = orderID
        self.purchasedAt = purchasedAt
        self.active = active
        self.acknowledged = acknowledged
    }
}
