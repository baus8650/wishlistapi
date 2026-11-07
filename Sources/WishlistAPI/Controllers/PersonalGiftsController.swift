import Fluent
import Vapor

struct PersonalGiftsController: RouteCollection {
    struct Purchase: Content {
        let id: UUID
        let title: String
        let recipients: [GiftRecipient]
        let price: Double?
        let currencyCode: String?
        let url: String?
        let notes: String?
        let quantity: Int
        var priceConfirmed: Bool? = nil
        let purchasedAt: Date
    }
    struct SaveRequest: Content {
        let title: String
        let recipients: [GiftRecipient]
        let price: Double?
        let currencyCode: String?
        let url: String?
        let notes: String?
        let quantity: Int
        var priceConfirmed: Bool? = nil
        let purchasedAt: Date
    }
    struct Claim: Content {
        let id: UUID
        let itemID: UUID
        let title: String
        let quantity: Int
        let price: Double?
        let currencyCode: String?
        let url: String?
        let wishlistID: UUID
        let wishlistTitle: String
        let viewerID: UUID
        let lastUpdatedAt: Date?
        let claimedAt: Date?
        let savedUnitPrice: Double?
        let paidUnitPrice: Double?
        let hasPriceSnapshot: Bool
        let canEditList: Bool
        let recipients: [GiftRecipient]
    }
    struct Index: Content { let claims: [Claim]; let purchases: [Purchase] }

    func boot(routes: any RoutesBuilder) throws {
        let gifts = routes.grouped("my-gifts")
        gifts.get(use: index)
        gifts.put("claims", ":claimID", "price", use: updateClaimPrice)
        gifts.post(use: create)
        gifts.put(":giftID", use: update)
        gifts.delete(":giftID", use: delete)
    }

    func index(req: Request) async throws -> Index {
        let user = try req.auth.require(User.self), userID = try user.requireID()
        let viewers = try await WishlistViewer.query(on: req.db).filter(\.$user.$id == userID)
            .with(\.$wishlist) { $0.with(\.$owner) }.all()
        let states = try await ItemViewerState.query(on: req.db)
            .filter(\.$viewer.$id ~~ viewers.compactMap(\.id))
            .group(.or) { $0.filter(\.$purchasedQuantity > 0).filter(\.$purchased == true) }
            .with(\.$item).sort(\.$updatedAt, .descending).all()
        let links = try await WishlistItemMembership.query(on: req.db)
            .filter(\.$item.$id ~~ states.map(\.$item.id)).all()
        let linked = Set(links.map { "\($0.$wishlist.id):\($0.$item.id)" })
        let byViewer = Dictionary(uniqueKeysWithValues: viewers.compactMap { viewer in viewer.id.map { ($0, viewer) } })
        // Only the creator's recipient labels are available in this private feed.
        let tags = try await WishlistGiftRecipients.query(on: req.db)
            .filter(\.$wishlist.$id ~~ viewers.filter { $0.wishlist.$owner.id == userID }.map(\.$wishlist.id)).all()
        let tagsByList = Dictionary(uniqueKeysWithValues: tags.map { ($0.$wishlist.id, $0.recipients) })
        var eligibility: [UUID: (canEdit: Bool, recipients: [GiftRecipient])] = [:]
        for viewer in viewers {
            let list = viewer.wishlist, owner = list.owner
            guard try await ProfileAccessService.canViewWishlist(viewer: user, wishlist: list, owner: owner, on: req.db) else { continue }
            if list.matureContentEnabled || owner.isAgeRestrictedProfile {
                guard user.derivedAgeBand == "adult" else { continue }
            }
            let canEdit = try await WishlistPermissionService.canEdit(wishlistID: list.requireID(), userID: userID, on: req.db)
            let forOthers = try await WishlistPermissionService.giftsAreForOthers(wishlist: list, on: req.db)
            if canEdit && !forOthers { continue }
            // A shared planning-list owner is not necessarily the gift recipient.
            let people = tagsByList[try list.requireID()] ?? (forOthers ? [] : [.init(userID: owner.id, name: ActivityService.actorName(for: owner, fallback: "Wishlist recipient"))])
            eligibility[try viewer.requireID()] = (canEdit, people)
        }
        var claims: [Claim] = []
        for state in states {
            guard let viewer = byViewer[state.$viewer.id], let access = eligibility[state.$viewer.id],
                  linked.contains("\(viewer.$wishlist.id):\(state.$item.id)") else { continue }
            let list = viewer.wishlist
            claims.append(.init(id: try state.requireID(), itemID: state.$item.id, title: state.item.title,
                quantity: max(state.purchasedQuantity, state.purchased ? 1 : 0), price: state.claimPrice.map { $0.paidUnitPrice ?? $0.unitPrice } ?? state.item.price,
                currencyCode: state.claimPrice.map { $0.currencyCode } ?? (state.item.currencyCode ?? list.currencyCode), url: state.item.url,
                wishlistID: try list.requireID(), wishlistTitle: list.title, viewerID: try viewer.requireID(),
                lastUpdatedAt: state.updatedAt ?? state.createdAt, claimedAt: state.claimPrice?.claimedAt,
                savedUnitPrice: state.claimPrice?.unitPrice, paidUnitPrice: state.claimPrice?.paidUnitPrice,
                hasPriceSnapshot: state.claimPrice != nil, canEditList: access.canEdit, recipients: access.recipients))
        }
        let purchases = try await PersonalGift.query(on: req.db).filter(\.$user.$id == userID)
            .sort(\.$purchasedAt, .descending).all().map(dto)
        return .init(claims: claims, purchases: purchases)
    }

    struct ClaimPriceRequest: Content { let paidUnitPrice: Double? }

    func updateClaimPrice(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(ClaimPriceRequest.self)
        if let price = body.paidUnitPrice {
            guard price.isFinite, price >= 0, price <= 1_000_000_000 else {
                throw Abort(.badRequest, reason: "Enter a unit price between 0 and 1,000,000,000.")
            }
        }
        guard let id = req.parameters.get("claimID", as: UUID.self),
              let state = try await ItemViewerState.find(id, on: req.db),
              state.purchased || state.purchasedQuantity > 0 else { throw Abort(.notFound) }
        let viewer = try await state.$viewer.get(on: req.db)
        guard viewer.$user.id == userID else { throw Abort(.notFound) }
        // Preserve the same visibility rules as the private claims feed.
        guard try await index(req: req).claims.contains(where: { $0.id == id }) else { throw Abort(.notFound) }
        if state.claimPrice == nil {
            let item = try await state.$item.get(on: req.db)
            let list = try await viewer.$wishlist.get(on: req.db)
            // Historical sale prices and claim dates cannot be reconstructed.
            state.claimPrice = .init(unitPrice: item.price, currencyCode: item.currencyCode ?? list.currencyCode, claimedAt: nil, paidUnitPrice: nil)
        }
        state.claimPrice?.paidUnitPrice = body.paidUnitPrice
        try await state.save(on: req.db)
        return .noContent
    }

    func create(req: Request) async throws -> Purchase {
        try await save(req: req, existing: nil)
    }
    func update(req: Request) async throws -> Purchase {
        let gift = try await ownedGift(req: req)
        return try await save(req: req, existing: gift)
    }
    private func ownedGift(req: Request) async throws -> PersonalGift {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("giftID", as: UUID.self),
              let gift = try await PersonalGift.query(on: req.db).filter(\.$id == id).filter(\.$user.$id == userID).first() else { throw Abort(.notFound) }
        return gift
    }
    private func save(req: Request, existing: PersonalGift?) async throws -> Purchase {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(SaveRequest.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 200 else { throw Abort(.badRequest, reason: "Enter a gift name of up to 200 characters.") }
        guard (1...999).contains(body.quantity) else { throw Abort(.badRequest, reason: "Quantity must be between 1 and 999.") }
        if let price = body.price, !price.isFinite || price < 0 { throw Abort(.badRequest, reason: "Enter a valid price of zero or more.") }
        let url = body.url?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url, !url.isEmpty {
            guard let value = URL(string: url), ["https", "http"].contains(value.scheme?.lowercased() ?? ""), value.host?.isEmpty == false else {
                throw Abort(.badRequest, reason: "Enter a valid link starting with https:// or http://.")
            }
        }
        let notes = body.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (notes?.count ?? 0) <= 2000 else { throw Abort(.badRequest, reason: "Notes can be up to 2,000 characters.") }
        try ContentSafetyService.validate(title, field: "gift name")
        if let notes { try ContentSafetyService.validate(notes, field: "gift notes") }
        let recipients = try await GiftRecipientsController.validated(body.recipients, userID: userID, on: req.db)
        let gift = existing ?? PersonalGift(userID: userID)
        gift.title = title
        gift.price = body.price
        gift.currencyCode = try body.currencyCode.flatMap { $0.isEmpty ? nil : try CurrencyCode.validated($0) }
        gift.url = url?.isEmpty == false ? url : nil
        gift.notes = notes?.isEmpty == false ? notes : nil
        gift.quantity = body.quantity
        gift.purchasedAt = body.purchasedAt
        gift.priceConfirmed = body.price != nil && body.priceConfirmed == true
        gift.recipientDocument = .init(recipients: recipients)
        try await gift.save(on: req.db)
        return try dto(gift)
    }
    func delete(req: Request) async throws -> HTTPStatus {
        let gift = try await ownedGift(req: req)
        try await gift.delete(on: req.db)
        return .noContent
    }
    private func dto(_ gift: PersonalGift) throws -> Purchase {
        .init(id: try gift.requireID(), title: gift.title, recipients: gift.recipientDocument.recipients,
              price: gift.price, currencyCode: gift.currencyCode, url: gift.url, notes: gift.notes,
              quantity: gift.quantity, priceConfirmed: gift.priceConfirmed, purchasedAt: gift.purchasedAt)
    }
}
