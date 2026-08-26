//
//  WishlistController.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Vapor
import Fluent

struct WishlistController: RouteCollection {

    struct CreateRequest: Content {
        let title: String
    }

    struct UpdateRequest: Content {
        let title: String
    }

    struct SettingsResponse: Content {
        let showPurchaserNames: Bool
        let allowMultiplePurchases: Bool
        let allowNotes: Bool
        let autoLockOnPurchase: Bool
    }

    struct UpdateSettingsRequest: Content {
        let showPurchaserNames: Bool?
        let allowMultiplePurchases: Bool?
        let allowNotes: Bool?
        let autoLockOnPurchase: Bool?
    }

    func boot(routes: any RoutesBuilder) throws {
        // This controller expects to be mounted under an authenticated/protected group.
        routes.get(use: index)
        routes.post(use: create)
        routes.patch(":wishlistID", use: update)
        routes.get(":wishlistID", "settings", use: getSettings)
        routes.patch(":wishlistID", "settings", use: updateSettings)
        routes.delete(":wishlistID", use: delete)
    }

    // GET /wishlists
    func index(req: Request) async throws -> [Wishlist] {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        return try await Wishlist.query(on: req.db)
            .filter(\.$owner.$id == userId)
            .sort(\.$createdAt, .descending)
            .all()
    }

    // POST /wishlists
    func create(req: Request) async throws -> Wishlist {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()
        let body = try req.content.decode(CreateRequest.self)

        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw Abort(.badRequest, reason: "Title is required.")
        }

        let wishlist = Wishlist(ownerUserId: userId, title: title)
        try await wishlist.save(on: req.db)
        return wishlist
    }

    // PATCH /wishlists/:wishlistID
    func update(req: Request) async throws -> Wishlist {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()
        let body = try req.content.decode(UpdateRequest.self)

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

        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw Abort(.badRequest, reason: "Title is required.")
        }

        wishlist.title = title
        try await wishlist.save(on: req.db)
        return wishlist
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

        guard let wishlist = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        return .init(
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

        try await wishlist.save(on: req.db)

        return .init(
            showPurchaserNames: wishlist.showPurchaserNames,
            allowMultiplePurchases: wishlist.allowMultiplePurchases,
            allowNotes: wishlist.allowNotes,
            autoLockOnPurchase: wishlist.autoLockOnPurchase
        )
    }
}
