import Fluent
import Vapor

struct ItemInventoryController: RouteCollection {
    struct LinksRequest: Content { let wishlistIDs: [UUID] }

    struct Entry: Content {
        let item: WishlistItem
        let wishlistIDs: [UUID]
        let canDelete: Bool
        let otherListCount: Int
        let isInventoryOwner: Bool
    }

    func boot(routes: any RoutesBuilder) throws {
        let items = routes.grouped("items")
        items.get(use: index)
        items.post(use: create)
        items.put(":itemID", use: update)
        items.delete(":itemID", use: delete)
        items.put(":itemID", "sale", use: sale)
        items.put(":itemID", "links", use: updateLinks)
        items.on(.PUT, ":itemID", "image", body: .collect(maxSize: "5mb"), use: uploadImage)
        items.delete(":itemID", "image", use: removeImage)
    }

    func editableIDs(user: User, on db: any Database) async throws -> Set<UUID> {
        let userID = try user.requireID()
        let collaborations = try await WishlistCollaborator.query(on: db).filter(\.$user.$id == userID).all()
        let owned = try await Wishlist.query(on: db).filter(\.$owner.$id == userID).all()
        let joint = try await Wishlist.query(on: db).filter(\.$id ~~ collaborations.map(\.$wishlist.id)).all()
        var eligible = owned.filter { !$0.matureContentEnabled || user.derivedAgeBand == "adult" }
        for list in joint where !list.matureContentEnabled || user.derivedAgeBand == "adult" {
            if try await !ProfileAccessService.isBlocked(userID, list.$owner.id, on: db) { eligible.append(list) }
        }
        return Set(eligible.compactMap(\.id))
    }

    func index(req: Request) async throws -> [Entry] {
        let user = try req.auth.require(User.self), userID = try user.requireID()
        let editable = try await editableIDs(user: user, on: req.db)
        let memberships = try await WishlistItemMembership.query(on: req.db)
            .filter(\.$wishlist.$id ~~ Array(editable)).all()
        let items = try await WishlistItem.query(on: req.db).group(.or) {
            $0.filter(\.$inventoryOwner.$id == userID)
            $0.filter(\.$id ~~ memberships.map(\.$item.id))
        }.sort(\.$updatedAt, .descending).all()
        let allLinks = try await WishlistItemMembership.query(on: req.db).filter(\.$item.$id ~~ items.compactMap(\.id)).all()
        let byItem = Dictionary(grouping: allLinks, by: { $0.$item.id })
        return try items.map { item in
            let ids = Set((byItem[try item.requireID()] ?? []).map(\.$wishlist.id))
            return .init(item: item, wishlistIDs: Array(ids.intersection(editable)), canDelete: ids.isSubset(of: editable), otherListCount: ids.subtracting(editable).count, isInventoryOwner: item.$inventoryOwner.id == userID)
        }
    }

    // Authority comes from inventory ownership or a current editable list membership.
    func authorizedItem(req: Request, on db: any Database) async throws -> (WishlistItem, Set<UUID>, Set<UUID>) {
        let user = try req.auth.require(User.self), userID = try user.requireID()
        guard let id = req.parameters.get("itemID", as: UUID.self), let item = try await WishlistItem.find(id, on: db) else { throw Abort(.notFound) }
        let editable = try await editableIDs(user: user, on: db)
        let links = try await WishlistItemMembership.query(on: db).filter(\.$item.$id == id).all()
        let linked = Set(links.map(\.$wishlist.id))
        guard item.$inventoryOwner.id == userID || !linked.isDisjoint(with: editable) else { throw Abort(.notFound) }
        return (item, editable, linked)
    }

    func create(req: Request) async throws -> WishlistItem {
        try await save(req: req, creating: true)
    }

    func update(req: Request) async throws -> WishlistItem {
        try await save(req: req, creating: false)
    }

    private func save(req: Request, creating: Bool) async throws -> WishlistItem {
        let user = try req.auth.require(User.self), userID = try user.requireID()
        let body = try req.content.decode(WishlistItemController.CreateRequest.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Abort(.badRequest, reason: "Title is required.") }
        try ContentSafetyService.validate(title, field: "item title")
        if let price = body.price, !price.isFinite || price < 0 { throw Abort(.badRequest, reason: "Enter a valid price.") }
        guard (body.quantity ?? 1) > 0 else { throw Abort(.badRequest, reason: "Quantity must be at least one.") }
        if let note = body.ownerNote { try ContentSafetyService.validate(note, field: "note") }
        let controller = WishlistItemController()
        let type = try controller.validatedType(body.itemType, url: body.url, goal: body.contributionGoal)
        if type == "cash_fund" { try ProAccessService.requirePro(user) }
        let result = try await req.db.transaction { db -> (WishlistItem, Double?) in
            let item: WishlistItem
            let editable: Set<UUID>
            let previousLinks: Set<UUID>
            if creating {
                editable = try await editableIDs(user: user, on: db)
                previousLinks = []
                item = WishlistItem(wishlistId: nil, title: title)
                item.$inventoryOwner.id = userID
            } else {
                (item, editable, previousLinks) = try await authorizedItem(req: req, on: db)
            }
            let requested = Set(body.linkedWishlistIDs ?? Array(previousLinks.intersection(editable)))
            guard requested.isSubset(of: editable) else { throw Abort(.forbidden, reason: "Choose lists you can edit.") }
            // Lists the editor cannot access remain linked and are never exposed by the inventory.
            let retained = previousLinks.subtracting(editable)
            let finalLinks = requested.union(retained)
            let previousSale = item.activeSalePrice
            item.itemType = type
            try controller.applySale(item, price: body.price, salePrice: body.salePrice,
                discount: body.saleDiscountPercent, endsAt: body.saleEndsAt)
            item.title = title
            item.url = body.url
            item.price = type == "cash_fund" ? nil : body.price
            item.ownerNote = body.ownerNote
            item.quantity = type == "cash_fund" ? 1 : (body.quantity ?? 1)
            item.itemType = type
            item.contributionGoal = type == "cash_fund" ? body.contributionGoal : nil
            item.$wishlist.id = finalLinks.sorted { $0.uuidString < $1.uuidString }.first
            try await item.save(on: db)
            // Validate selected destinations; retained destinations were already linked.
            let existing = try await WishlistItemMembership.query(on: db).filter(\.$item.$id == item.requireID()).all()
            for link in existing where !finalLinks.contains(link.$wishlist.id) { try await link.delete(on: db) }
            for id in finalLinks.subtracting(previousLinks) {
                let maxPosition = try await WishlistItemMembership.query(on: db).filter(\.$wishlist.$id == id).max(\.$position) ?? -1
                try await WishlistItemMembership(itemID: item.requireID(), wishlistID: id, position: maxPosition + 1).save(on: db)
            }
            return (item, previousSale)
        }
        if let _ = result.0.activeSalePrice, result.0.activeSalePrice != result.1 {
            try await SaleNotificationService.notify(item: result.0, actorID: userID, title: "Wishlist item on sale",
                message: "\(result.0.title) is on sale", on: req.db, client: req.client, logger: req.logger)
        } else if result.1 != nil, result.0.activeSalePrice == nil {
            try await SaleNotificationService.notify(item: result.0, actorID: userID, title: "Sale removed",
                message: "The sale on \(result.0.title) has been removed", on: req.db, client: req.client, logger: req.logger)
        }
        return result.0
    }

    func updateLinks(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(LinksRequest.self)
        try await req.db.transaction { db in
            let (item, editable, previous) = try await authorizedItem(req: req, on: db)
            let selected = Set(body.wishlistIDs)
            guard selected.isSubset(of: editable) else { throw Abort(.forbidden, reason: "Choose lists you can edit.") }
            let final = selected.union(previous.subtracting(editable))
            let existing = try await WishlistItemMembership.query(on: db).filter(\.$item.$id == item.requireID()).all()
            for link in existing where !final.contains(link.$wishlist.id) { try await link.delete(on: db) }
            for id in final.subtracting(previous) {
                let maximum = try await WishlistItemMembership.query(on: db).filter(\.$wishlist.$id == id).max(\.$position) ?? -1
                try await WishlistItemMembership(itemID: item.requireID(), wishlistID: id, position: maximum + 1).save(on: db)
            }
            item.$wishlist.id = final.sorted { $0.uuidString < $1.uuidString }.first
            try await item.save(on: db)
        }
        return .noContent
    }

    func delete(req: Request) async throws -> HTTPStatus {
        try await req.db.transaction { db in
            let (item, editable, linked) = try await authorizedItem(req: req, on: db)
            guard linked.isSubset(of: editable) else { throw Abort(.forbidden, reason: "This item also appears on a list you cannot edit. Remove it from your lists instead.") }
            try await item.delete(on: db)
        }
        return .noContent
    }

    func sale(req: Request) async throws -> WishlistItem {
        let (item, _, _) = try await authorizedItem(req: req, on: req.db)
        let actorID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(WishlistItemController.SaleRequest.self)
        let previous = item.activeSalePrice
        try WishlistItemController().applySale(item, price: item.price, salePrice: body.salePrice,
            discount: body.saleDiscountPercent, endsAt: body.saleEndsAt)
        try await item.save(on: req.db)
        if item.activeSalePrice != previous {
            try await SaleNotificationService.notify(item: item, actorID: actorID,
                title: item.activeSalePrice == nil ? "Sale removed" : "Wishlist item on sale",
                message: item.activeSalePrice == nil ? "The sale on \(item.title) has been removed" : "\(item.title) is on sale",
                on: req.db, client: req.client, logger: req.logger)
        }
        return item
    }

    func uploadImage(req: Request) async throws -> HTTPStatus {
        let (item, _, _) = try await authorizedItem(req: req, on: req.db)
        let type = req.headers.contentType?.description.lowercased() ?? ""
        guard ["image/jpeg", "image/png", "image/webp"].contains(type) else { throw Abort(.unsupportedMediaType) }
        guard var buffer = req.body.data, let data = buffer.readData(length: buffer.readableBytes), !data.isEmpty else { throw Abort(.badRequest) }
        let image = try await WishlistItemImage.query(on: req.db).filter(\.$item.$id == item.requireID()).first()
            ?? WishlistItemImage(itemID: item.requireID(), data: data, contentType: type)
        image.data = data; image.contentType = type
        try await image.save(on: req.db)
        return .noContent
    }

    func removeImage(req: Request) async throws -> HTTPStatus {
        let (item, _, _) = try await authorizedItem(req: req, on: req.db)
        if let image = try await WishlistItemImage.query(on: req.db).filter(\.$item.$id == item.requireID()).first() {
            try await image.delete(on: req.db)
        }
        return .noContent
    }
}
