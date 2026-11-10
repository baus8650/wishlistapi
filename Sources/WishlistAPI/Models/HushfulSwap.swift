import Fluent
import Vapor

// Never return this model or its stored state from a route. Only SwapView is public.
final class HushfulSwap: Model, @unchecked Sendable {
    static let schema = "hushful_swaps"
    @ID(key: .id) var id: UUID?
    @Parent(key: "owner_id") var owner: User
    @Field(key: "invite_token") var inviteToken: String
    @Field(key: "state") var state: SwapState
    init() {}
    init(ownerID: UUID, state: SwapState) {
        self.$owner.id = ownerID
        self.inviteToken = SwapSecurity.token()
        self.state = state
    }
}

struct SwapWish: Content, Equatable {
    var title: String
    var url: String?
    var note: String?
    var id: UUID? = nil
    var updatedAt: Date? = nil
    var price: Double? = nil
    var currencyCode: String? = nil
    var quantity: Int? = nil
    var salePrice: Double? = nil
    var saleDiscountPercent: Double? = nil
    var saleEndsAt: Date? = nil
    var itemType: String? = nil
    var contributionGoal: Double? = nil
}
struct SwapMember: Codable, Sendable {
    var id = UUID()
    var userID: UUID?
    var name: String
    var status: String = "pending"
    var wishlistID: UUID?
    var recipientID: UUID?
    var wishes: [SwapWish] = []
    var lastReminder: Date?
    var reminderDays: Int?
    var purchaseReminderSent: Bool?
}
struct SwapState: Codable, Sendable {
    var title: String
    var exchangeDate: String
    var priceLimit: Double?
    var currencyCode: String
    var status = "draft"
    var members: [SwapMember]
}
struct SwapMemberView: Content {
    var id: UUID
    var name: String
    var status: String
    var canRemind: Bool
}
struct SwapRecipientView: Content {
    var name: String
    var wishes: [SwapWish]
}
struct SwapView: Content {
    var id: UUID
    var title: String
    var exchangeDate: String
    var priceLimit: Double?
    var currencyCode: String
    var status: String
    var isAdmin: Bool
    var myID: UUID
    var reminderDays: Int?
    var myStatus: String
    var wishes: [SwapWish]
    var members: [SwapMemberView]
    var recipient: SwapRecipientView?
    var inviteURL: String?
    var wishlist: WishlistController.Summary? = nil
}
