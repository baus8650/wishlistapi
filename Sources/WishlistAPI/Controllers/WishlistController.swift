//
//  WishlistController.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Vapor
import Fluent

struct WishlistController: RouteCollection {

    struct Summary: Content {
        let id: UUID
        let title: String
        let visibility: String
        let collaborationMode: String
        let isPrimaryOwner: Bool
        let isCollaborative: Bool
    }

    struct CreateRequest: Content {
        let title: String
        let visibility: String?
        let collaborationMode: String?
    }

    struct UpdateRequest: Content {
        let title: String
    }

    struct ReorderRequest: Content {
        let ids: [UUID]
    }

    struct SettingsResponse: Content {
        let visibility: String
        let showPurchaserNames: Bool
        let allowMultiplePurchases: Bool
        let allowNotes: Bool
        let autoLockOnPurchase: Bool
    }

    struct UpdateSettingsRequest: Content {
        let visibility: String?
        let showPurchaserNames: Bool?
        let allowMultiplePurchases: Bool?
        let allowNotes: Bool?
        let autoLockOnPurchase: Bool?
    }

    func boot(routes: any RoutesBuilder) throws {
        // This controller expects to be mounted under an authenticated/protected group.
        routes.get(use: index)
        routes.post(use: create)
        routes.put("order", use: reorder)
        routes.patch(":wishlistID", use: update)
        routes.get(":wishlistID", "settings", use: getSettings)
        routes.patch(":wishlistID", "settings", use: updateSettings)
        routes.delete(":wishlistID", use: delete)
    }

    // GET /wishlists
    func index(req: Request) async throws -> [Summary] {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        let collaboratorIDs = try await WishlistCollaborator.query(on: req.db)
            .filter(\.$user.$id == userId).all().map(\.$wishlist.id)
        let ownedIDs = try await Wishlist.query(on: req.db)
            .filter(\.$owner.$id == userId).all().compactMap(\.id)
        let visibleIDs = Array(Set(ownedIDs + collaboratorIDs))
        let collaborativeIDs = Set(try await WishlistCollaborator.query(on: req.db)
            .filter(\.$wishlist.$id ~~ visibleIDs).all().map(\.$wishlist.id))
        return try await Wishlist.query(on: req.db)
            .filter(\.$id ~~ visibleIDs)
            .sort(\.$position, .ascending)
            .sort(\.$createdAt, .descending)
            .all()
            .map { try summary($0, for: userId, isCollaborative: collaborativeIDs.contains(try $0.requireID())) }
    }

    // POST /wishlists
    func create(req: Request) async throws -> Summary {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()
        let body = try req.content.decode(CreateRequest.self)

        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw Abort(.badRequest, reason: "Title is required.")
        }

        let visibility = body.visibility ?? "public"
        guard ["public", "private"].contains(visibility) else {
            throw Abort(.badRequest, reason: "Visibility must be public or private.")
        }
        let wishlist = Wishlist(ownerUserId: userId, title: title)
        wishlist.visibility = visibility
        if let mode = body.collaborationMode {
            guard ["our_wishlist", "gift_planning"].contains(mode) else { throw Abort(.badRequest, reason: "Invalid collaboration mode.") }
            wishlist.collaborationMode = mode
        }
        let existing = try await Wishlist.query(on: req.db).filter(\.$owner.$id == userId).all()
        for item in existing {
            item.position += 1
            try await item.save(on: req.db)
        }
        try await wishlist.save(on: req.db)
        return try summary(wishlist, for: userId, isCollaborative: false)
    }

    func reorder(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(ReorderRequest.self)
        let collaboratorIDs = try await WishlistCollaborator.query(on: req.db).filter(\.$user.$id == userID).all().map(\.$wishlist.id)
        let ownedIDs = try await Wishlist.query(on: req.db).filter(\.$owner.$id == userID).all().compactMap(\.id)
        let wishlists = try await Wishlist.query(on: req.db).filter(\.$id ~~ Array(Set(ownedIDs + collaboratorIDs))).all()
        let existingIDs = Set(try wishlists.map { try $0.requireID() })
        guard body.ids.count == existingIDs.count, Set(body.ids) == existingIDs else {
            throw Abort(.badRequest, reason: "The order must include each wishlist exactly once.")
        }
        let byID = Dictionary(uniqueKeysWithValues: try wishlists.map { (try $0.requireID(), $0) })
        for (position, id) in body.ids.enumerated() {
            guard let wishlist = byID[id] else { continue }
            wishlist.position = position
            try await wishlist.save(on: req.db)
        }
        return .noContent
    }

    // PATCH /wishlists/:wishlistID
    func update(req: Request) async throws -> Summary {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()
        let body = try req.content.decode(UpdateRequest.self)

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        guard let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else {
            throw Abort(.notFound)
        }

        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw Abort(.badRequest, reason: "Title is required.")
        }

        wishlist.title = title
        try await wishlist.save(on: req.db)
        try await ActivityService.notifyRecipients(wishlistID: wishlistID, actorID: userId, kind: "wishlist_updated", title: "Shared wishlist updated", message: "A shared wishlist was renamed to “\(title)”.", on: req.db)
        let isCollaborative = try await WishlistCollaborator.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID).first() != nil
        return try summary(wishlist, for: userId, isCollaborative: isCollaborative)
    }

    // DELETE /wishlists/:wishlistID
    func delete(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        guard let wishlist = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId) // ownership enforcement
            .first()
        else {
            throw Abort(.notFound)
        }

        // Preserve canonical items that are also linked to another wishlist.
        let primaryItems = try await WishlistItem.query(on: req.db).filter(\.$wishlist.$id == wishlistID).all()
        for item in primaryItems {
            let itemID = try item.requireID()
            if let replacement = try await WishlistItemMembership.query(on: req.db)
                .filter(\.$item.$id == itemID)
                .filter(\.$wishlist.$id != wishlistID)
                .first() {
                item.$wishlist.id = replacement.$wishlist.id
                try await item.save(on: req.db)
            }
        }
        try await wishlist.delete(on: req.db)
        return .noContent
    }

    // GET /wishlists/:wishlistID/settings
    func getSettings(req: Request) async throws -> SettingsResponse {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        guard let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userId, on: req.db) else { throw Abort(.notFound) }

        return .init(
            visibility: wishlist.visibility,
            showPurchaserNames: wishlist.showPurchaserNames,
            allowMultiplePurchases: wishlist.allowMultiplePurchases,
            allowNotes: wishlist.allowNotes,
            autoLockOnPurchase: wishlist.autoLockOnPurchase
        )
    }

    // PATCH /wishlists/:wishlistID/settings
    func updateSettings(req: Request) async throws -> SettingsResponse {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        let body = try req.content.decode(UpdateSettingsRequest.self)

        guard let wishlist = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        if let v = body.showPurchaserNames { wishlist.showPurchaserNames = v }
        if let v = body.allowMultiplePurchases { wishlist.allowMultiplePurchases = v }
        if let v = body.allowNotes { wishlist.allowNotes = v }
        if let v = body.autoLockOnPurchase { wishlist.autoLockOnPurchase = v }
        if let visibility = body.visibility {
            guard ["private", "public"].contains(visibility) else {
                throw Abort(.badRequest, reason: "Visibility must be private or public.")
            }
            if wishlist.visibility == "public", visibility == "private" {
                try await revokePublicAccess(wishlistID: wishlistID, on: req.db)
            }
            wishlist.visibility = visibility
        }

        try await wishlist.save(on: req.db)

        return .init(
            visibility: wishlist.visibility,
            showPurchaserNames: wishlist.showPurchaserNames,
            allowMultiplePurchases: wishlist.allowMultiplePurchases,
            allowNotes: wishlist.allowNotes,
            autoLockOnPurchase: wishlist.autoLockOnPurchase
        )
    }

    private func revokePublicAccess(wishlistID: UUID, on db: any Database) async throws {
        let accesses = try await PublicWishlistAccess.query(on: db)
            .filter(\.$wishlist.$id == wishlistID).all()
        for access in accesses {
            let viewerID = access.$viewer.id
            try await access.delete(on: db)
            let isExplicitlyShared = try await SocialWishlistAccess.query(on: db)
                .filter(\.$viewer.$id == viewerID).first() != nil
            if !isExplicitlyShared,
               let viewer = try await WishlistViewer.find(viewerID, on: db) {
                try await viewer.delete(on: db)
            }
        }
    }

    private func summary(_ wishlist: Wishlist, for userID: UUID, isCollaborative: Bool) throws -> Summary {
        .init(id: try wishlist.requireID(), title: wishlist.title, visibility: wishlist.visibility,
              collaborationMode: wishlist.collaborationMode, isPrimaryOwner: wishlist.$owner.id == userID,
              isCollaborative: isCollaborative)
    }
}
