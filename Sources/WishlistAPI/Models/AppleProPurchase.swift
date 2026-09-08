import Fluent
import Foundation

final class AppleProPurchase: Model, @unchecked Sendable {
    static let schema = "apple_pro_purchases"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "original_transaction_id") var originalTransactionID: String
    @Field(key: "signed_at") var signedAt: Date
    @Field(key: "active") var active: Bool

    init() {}
    init(userID: UUID, originalTransactionID: String, signedAt: Date, active: Bool) {
        self.$user.id = userID
        self.originalTransactionID = originalTransactionID
        self.signedAt = signedAt
        self.active = active
    }
}
