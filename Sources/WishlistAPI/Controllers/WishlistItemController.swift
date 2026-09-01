//
//  WishlistItemController.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Vapor
import Fluent

struct WishlistItemController: RouteCollection {

    struct CreateRequest: Content {
        let title: String
        let url: String?
        let price: Double?
        let ownerNote: String?
        let quantity: Int?
        let linkedWishlistIDs: [UUID]?
        let itemType: String?
        let contributionGoal: Double?
    }

    struct UpdateRequest: Content {
        let title: String?
        let url: String?
        let price: Double?
        let ownerNote: String?
        let quantity: Int?
        let linkedWishlistIDs: [UUID]?
        let itemType: String?
        let contributionGoal: Double?
    }

    struct ReorderRequest: Content { let ids: [UUID] }
    struct LinksResponse: Content { let wishlistIDs: [UUID] }

    func boot(routes: any RoutesBuilder) throws {
        // Owner-only endpoints (mounted under /wishlists)
        routes.get(":wishlistID", "items", use: listForWishlist)
        routes.post(":wishlistID", "items", use: createForWishlist)
        routes.put(":wishlistID", "items", "order", use: reorder)
        routes.get(":wishlistID", "items", ":itemID", "links", use: links)

        // Item-level endpoints under /wishlists
        routes.put(":wishlistID", "items", ":itemID", use: replace)
        routes.patch(":wishlistID", "items", ":itemID", use: update)
        routes.delete(":wishlistID", "items", ":itemID", use: delete)
    }

    // PUT /wishlists/:wishlistID/items/:itemID
    // Replaces all owner-editable fields, allowing optional values to be cleared.
    func replace(req: Request) async throws -> WishlistItem {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let itemID = req.parameters.get("itemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlist or item ID.")
        }

        guard let item = try await WishlistItem.find(itemID, on: req.db),
              try await membership(itemID: itemID, wishlistID: wishlistID, on: req.db) != nil else {
            throw Abort(.notFound)
        }

        guard let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else { throw Abort(.notFound) }

        let body = try req.content.decode(CreateRequest.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw Abort(.badRequest, reason: "Title is required.")
        }
        if let price = body.price, price < 0 {
            throw Abort(.badRequest, reason: "price cannot be negative.")
        }
        guard (body.quantity ?? 1) > 0 else { throw Abort(.badRequest, reason: "quantity must be at least 1.") }
        let itemType = try validatedType(body.itemType, url: body.url, goal: body.contributionGoal)

        item.title = title
        item.url = body.url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        item.price = body.price
        item.ownerNote = body.ownerNote?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        item.quantity = body.quantity ?? 1
        item.itemType = itemType
        item.contributionGoal = itemType == "cash_fund" ? body.contributionGoal : nil
        try await item.save(on: req.db)
        if let linked = body.linkedWishlistIDs {
            try await syncMemberships(item: item, userID: userId, requestedIDs: Set(linked + [wishlistID]), on: req.db)
        }
        try await ActivityService.notifyRecipients(wishlistID: wishlistID, actorID: userId, kind: "wishlist_updated", title: "Shared wishlist updated", message: "An item changed in “\(wishlist.title)”.", on: req.db, client: req.client, logger: req.logger)
        return item
    }

    // GET /wishlists/:wishlistID/items
    func listForWishlist(req: Request) async throws -> [WishlistItem] {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        // Ownership check
        guard try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else { throw Abort(.notFound) }

        return try await WishlistItemMembership.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .sort(\.$position, .ascending)
            .with(\.$item)
            .all()
            .map(\.item)
    }

    // POST /wishlists/:wishlistID/items
    func createForWishlist(req: Request) async throws -> WishlistItem {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        // Ownership check
        guard let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else { throw Abort(.notFound) }

        let body = try req.content.decode(CreateRequest.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Abort(.badRequest, reason: "Title is required.") }

        if let price = body.price, price < 0 {
            throw Abort(.badRequest, reason: "price cannot be negative.")
        }
        guard (body.quantity ?? 1) > 0 else { throw Abort(.badRequest, reason: "quantity must be at least 1.") }
        let itemType = try validatedType(body.itemType, url: body.url, goal: body.contributionGoal)

        let item = WishlistItem(
            wishlistId: wishlistID,
            title: title,
            url: body.url,
            price: body.price,
            ownerNote: body.ownerNote,
            quantity: body.quantity ?? 1,
            itemType: itemType,
            contributionGoal: itemType == "cash_fund" ? body.contributionGoal : nil
        )
        try await item.save(on: req.db)
        try await syncMemberships(item: item, userID: userId, requestedIDs: Set((body.linkedWishlistIDs ?? []) + [wishlistID]), on: req.db)
        try await ActivityService.notifyRecipients(wishlistID: wishlistID, actorID: userId, kind: "wishlist_updated", title: "New wishlist item", message: "A new item was added to “\(wishlist.title)”.", on: req.db, client: req.client, logger: req.logger)
        return item
    }

    func reorder(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userID, on: req.db) else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(ReorderRequest.self)
        let memberships = try await WishlistItemMembership.query(on: req.db).filter(\.$wishlist.$id == wishlistID).all()
        let existingIDs = Set(memberships.map(\.$item.id))
        guard body.ids.count == existingIDs.count, Set(body.ids) == existingIDs else {
            throw Abort(.badRequest, reason: "The order must include each item exactly once.")
        }
        let byID = Dictionary(uniqueKeysWithValues: memberships.map { ($0.$item.id, $0) })
        for (position, id) in body.ids.enumerated() {
            guard let membership = byID[id] else { continue }
            membership.position = position
            try await membership.save(on: req.db)
        }
        return .noContent
    }

    func links(req: Request) async throws -> LinksResponse {
        let userID = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let itemID = req.parameters.get("itemID", as: UUID.self),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userID, on: req.db),
              try await membership(itemID: itemID, wishlistID: wishlistID, on: req.db) != nil else { throw Abort(.notFound) }
        let memberships = try await WishlistItemMembership.query(on: req.db).filter(\.$item.$id == itemID).all()
        return .init(wishlistIDs: memberships.map(\.$wishlist.id))
    }

    // PATCH /wishlists/:wishlistID/items/:itemID
    func update(req: Request) async throws -> WishlistItem {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        guard let itemID = req.parameters.get("itemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid itemID.")
        }

        guard let item = try await WishlistItem.find(itemID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Ensure item belongs to the wishlist in the route
        guard try await membership(itemID: itemID, wishlistID: wishlistID, on: req.db) != nil else { throw Abort(.notFound) }

        // Ownership check via parent wishlist
        guard let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else { throw Abort(.notFound) }

        let body = try req.content.decode(UpdateRequest.self)

        if let title = body.title {
            let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw Abort(.badRequest, reason: "Title cannot be empty.") }
            item.title = t
        }
        if let url = body.url { item.url = url }
        if let price = body.price {
            guard price >= 0 else { throw Abort(.badRequest, reason: "price cannot be negative.") }
            item.price = price
        }
        if let note = body.ownerNote { item.ownerNote = note }
        if let quantity = body.quantity {
            guard quantity > 0 else { throw Abort(.badRequest, reason: "quantity must be at least 1.") }
            item.quantity = quantity
        }
        if body.itemType != nil || body.contributionGoal != nil {
            let type = try validatedType(body.itemType ?? item.itemType, url: body.url ?? item.url, goal: body.contributionGoal ?? item.contributionGoal)
            item.itemType = type
            item.contributionGoal = type == "cash_fund" ? (body.contributionGoal ?? item.contributionGoal) : nil
        }

        try await item.save(on: req.db)
        if let linked = body.linkedWishlistIDs {
            try await syncMemberships(item: item, userID: userId, requestedIDs: Set(linked + [wishlistID]), on: req.db)
        }
        try await ActivityService.notifyRecipients(wishlistID: wishlistID, actorID: userId, kind: "wishlist_updated", title: "Shared wishlist updated", message: "An item changed in “\(wishlist.title)”.", on: req.db, client: req.client, logger: req.logger)
        return item
    }

    // DELETE /wishlists/:wishlistID/items/:itemID
    func delete(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        guard let itemID = req.parameters.get("itemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid itemID.")
        }

        guard let item = try await WishlistItem.find(itemID, on: req.db) else {
            throw Abort(.notFound)
        }

        // Ensure item belongs to the wishlist in the route
        guard let currentMembership = try await membership(itemID: itemID, wishlistID: wishlistID, on: req.db) else { throw Abort(.notFound) }

        guard let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else { throw Abort(.notFound) }

        let allMemberships = try await WishlistItemMembership.query(on: req.db).filter(\.$item.$id == itemID).all()
        if allMemberships.count > 1 {
            if item.$wishlist.id == wishlistID, let replacement = allMemberships.first(where: { $0.$wishlist.id != wishlistID }) {
                item.$wishlist.id = replacement.$wishlist.id
                try await item.save(on: req.db)
            }
            try await currentMembership.delete(on: req.db)
        } else {
            try await item.delete(on: req.db)
        }
        try await ActivityService.notifyRecipients(wishlistID: wishlistID, actorID: userId, kind: "wishlist_updated", title: "Shared wishlist updated", message: "An item was removed from “\(wishlist.title)”.", on: req.db, client: req.client, logger: req.logger)
        return .noContent
    }

    private func membership(itemID: UUID, wishlistID: UUID, on database: any Database) async throws -> WishlistItemMembership? {
        try await WishlistItemMembership.query(on: database)
            .filter(\.$item.$id == itemID)
            .filter(\.$wishlist.$id == wishlistID)
            .first()
    }

    private func syncMemberships(item: WishlistItem, userID: UUID, requestedIDs: Set<UUID>, on database: any Database) async throws {
        for wishlistID in requestedIDs {
            guard try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userID, on: database) else {
                throw Abort(.forbidden, reason: "Items can only be linked to wishlists you can edit.")
            }
        }
        let itemID = try item.requireID()
        let existing = try await WishlistItemMembership.query(on: database).filter(\.$item.$id == itemID).all()
        let existingIDs = Set(existing.map(\.$wishlist.id))
        for membership in existing where !requestedIDs.contains(membership.$wishlist.id) { try await membership.delete(on: database) }
        for wishlistID in requestedIDs.subtracting(existingIDs) {
            let memberships = try await WishlistItemMembership.query(on: database).filter(\.$wishlist.$id == wishlistID).all()
            for membership in memberships { membership.position += 1; try await membership.save(on: database) }
            try await WishlistItemMembership(itemID: itemID, wishlistID: wishlistID, position: 0).save(on: database)
        }
    }

    private func validatedType(_ value: String?, url: String?, goal: Double?) throws -> String {
        let type = value ?? "wish"
        guard type == "wish" || type == "cash_fund" else { throw Abort(.badRequest, reason: "Invalid item type.") }
        if let goal, goal <= 0 { throw Abort(.badRequest, reason: "Contribution goal must be greater than zero.") }
        if type == "cash_fund" {
            guard let value = url?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let parsed = URL(string: value), parsed.scheme?.lowercased() == "https" else {
                throw Abort(.badRequest, reason: "Cash funds require a valid HTTPS payment link.")
            }
        }
        return type
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
