import Fluent
import SQLKit
import Vapor

enum ItemDeletionReason: String, Codable, CaseIterable, Sendable {
    case notSpecified = "not_specified"
    case noLongerWanted = "no_longer_wanted"
    case alreadyPurchased = "already_purchased"
    case purchasedMyself = "purchased_myself"
    case replaced = "replaced"
    case addedByMistake = "added_by_mistake"
    case other

    var title: String {
        switch self {
        case .notSpecified: "Not specified"
        case .noLongerWanted: "No longer wanted"
        case .alreadyPurchased: "Already claimed"
        case .purchasedMyself: "Purchased myself"
        case .replaced: "Replaced with another item"
        case .addedByMistake: "Added by mistake"
        case .other: "Other"
        }
    }
}

struct ItemDeletionRequest: Content {
    var reason: ItemDeletionReason = .notSpecified
    var note: String? = nil
    struct SelfPurchase: Content {
        let recordID: UUID
        let paidUnitPrice: Double?
        let quantity: Int
        let purchasedAt: Date
    }
    var selfPurchase: SelfPurchase? = nil

    init(reason: ItemDeletionReason = .notSpecified, note: String? = nil) {
        self.reason = reason; self.note = note
    }

    private enum CodingKeys: String, CodingKey { case reason, note, selfPurchase }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reason = try values.decodeIfPresent(ItemDeletionReason.self, forKey: .reason) ?? .notSpecified
        note = try values.decodeIfPresent(String.self, forKey: .note)
        selfPurchase = try values.decodeIfPresent(SelfPurchase.self, forKey: .selfPurchase)
    }

    static func read(from req: Request) throws -> Self {
        guard let data = req.body.data, data.readableBytes > 0 else { return .init() }
        var body = try req.content.decode(Self.self)
        body.note = body.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.note?.isEmpty == true { body.note = nil }
        if let note = body.note {
            guard body.reason == .other, note.count <= 240 else {
                throw Abort(.badRequest, reason: "Choose Other for a custom reason and keep it under 240 characters.")
            }
            try ContentSafetyService.validate(note, field: "deletion reason")
        }
        if let purchase = body.selfPurchase {
            guard body.reason == .purchasedMyself, (1...999).contains(purchase.quantity),
                  purchase.paidUnitPrice.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }) ?? true,
                  purchase.purchasedAt <= Date().addingTimeInterval(300) else {
                throw Abort(.badRequest, reason: "Enter a valid purchase price, quantity and date.")
            }
        }
        return body
    }

    var explanation: String? {
        if reason == .notSpecified { return nil }
        return reason == .other ? (note ?? reason.title) : reason.title
    }
}

enum ItemDeletionNotificationService {
    struct Delivery: Sendable {
        let userID: UUID
        let actorID: UUID
        let message: String
        var title: String { "Claimed item removed" }
    }

    // Serializes removal of the same canonical item across list and inventory endpoints.
    static func lockItem(_ id: UUID, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let rows = try await sql.raw("SELECT id FROM wishlist_items WHERE id = \(bind: id) FOR UPDATE").all()
        guard !rows.isEmpty else { throw Abort(.notFound) }
    }

    // Record inside the deletion transaction, before claim rows cascade away.
    // No claimant identities or counts are returned to the deleting user.
    static func record(item: WishlistItem, actorID: UUID, reason: ItemDeletionRequest,
                       permanentlyDeleted: Bool, on db: any Database) async throws -> [Delivery] {
        let states = try await ItemViewerState.query(on: db).filter(\.$item.$id == item.requireID())
            .filter(\.$purchasedQuantity > 0).with(\.$viewer).all()
        let recipients = Set(states.filter { $0.viewer.notificationsEnabled }.compactMap { $0.viewer.$user.id })
            .subtracting([actorID])
        let action = permanentlyDeleted ? "was deleted" : "was removed from all wishlists"
        var message = "“\(item.title)”, which you claimed, \(action)."
        if let explanation = reason.explanation { message += " Reason: \(explanation)." }
        var deliveries: [Delivery] = []
        for userID in recipients {
            let delivery = Delivery(userID: userID, actorID: actorID, message: message)
            // The item is gone: don't link the notification to an unavailable item or list.
            try await ActivityService.create(userID: userID, actorID: actorID, kind: "claimed_item_removed",
                title: delivery.title, message: message, on: db)
            deliveries.append(delivery)
        }
        return deliveries
    }

    static func recordSelfPurchase(item: WishlistItem, actor: User, fallbackCurrency: String?, request: ItemDeletionRequest, on db: any Database) async throws {
        guard request.reason == .purchasedMyself else { return }
        let userID = try actor.requireID()
        let purchase = request.selfPurchase
        if let id = purchase?.recordID, let existing = try await PersonalGift.find(id, on: db) {
            guard existing.$user.id == userID else { throw Abort(.conflict) }
            return
        }
        let gift = PersonalGift(userID: userID)
        gift.id = purchase?.recordID
        gift.title = item.title
        gift.priceConfirmed = purchase?.paidUnitPrice != nil
        gift.price = purchase?.paidUnitPrice ?? item.activeSalePrice ?? item.price
        gift.currencyCode = item.currencyCode ?? fallbackCurrency
        gift.url = item.url
        gift.notes = "Purchased myself"
        gift.quantity = purchase?.quantity ?? item.quantity
        gift.purchasedAt = purchase?.purchasedAt ?? Date()
        gift.recipientDocument = .init(recipients: [.init(userID: userID, name: ActivityService.actorName(for: actor, fallback: "Me"))])
        try await gift.save(on: db)
    }

    // Push is deliberately sent only after the deletion transaction commits.
    static func send(_ deliveries: [Delivery], req: Request) async {
        for delivery in deliveries {
            await APNSService.send(userID: delivery.userID, kind: "claimed_item_removed", title: delivery.title,
                message: delivery.message, actorID: delivery.actorID, wishlistID: nil,
                on: req.db, client: req.client, logger: req.logger)
            await FCMService.send(userID: delivery.userID, kind: "claimed_item_removed", title: delivery.title,
                message: delivery.message, actorID: delivery.actorID, wishlistID: nil,
                on: req.db, client: req.client, logger: req.logger)
        }
    }
}
