import Fluent
import Vapor

/// Private purchase records, separate from shared wishlist items.
final class PersonalGift: Model, @unchecked Sendable {
    static let schema = "personal_gifts"
    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: User
    @Field(key: "title") var title: String
    @OptionalField(key: "price") var price: Double?
    @OptionalField(key: "currency_code") var currencyCode: String?
    @OptionalField(key: "url") var url: String?
    @OptionalField(key: "notes") var notes: String?
    @Field(key: "quantity") var quantity: Int
    @Field(key: "purchased_at") var purchasedAt: Date
    @Field(key: "recipients") var recipientDocument: GiftRecipientDocument
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    init() {}
    init(userID: UUID) {
        self.$user.id = userID
    }
}
