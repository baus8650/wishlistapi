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
    }

    struct UpdateRequest: Content {
        let title: String?
        let url: String?
        let price: Double?
        let ownerNote: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        // Owner-only endpoints (mounted under /wishlists)
        routes.get(":wishlistID", "items", use: listForWishlist)
        routes.post(":wishlistID", "items", use: createForWishlist)

        // Item-level endpoints under /wishlists
        routes.patch(":wishlistID", "items", ":itemID", use: update)
        routes.delete(":wishlistID", "items", ":itemID", use: delete)
    }

    // GET /wishlists/:wishlistID/items
    func listForWishlist(req: Request) async throws -> [WishlistItem] {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        // Ownership check
        let ownsWishlist = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first() != nil

        guard ownsWishlist else { throw Abort(.notFound) }

        return try await WishlistItem.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .sort(\.$createdAt, .ascending)
            .all()
    }

    // POST /wishlists/:wishlistID/items
    func createForWishlist(req: Request) async throws -> WishlistItem {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        // Ownership check
        guard let _ = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        let body = try req.content.decode(CreateRequest.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Abort(.badRequest, reason: "Title is required.") }

        if let price = body.price, price < 0 {
            throw Abort(.badRequest, reason: "price cannot be negative.")
        }

        let item = WishlistItem(
            wishlistId: wishlistID,
            title: title,
            url: body.url,
            price: body.price,
            ownerNote: body.ownerNote
        )
        try await item.save(on: req.db)
        return item
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
        guard item.$wishlist.id == wishlistID else { throw Abort(.notFound) }

        // Ownership check via parent wishlist
        let wishlist = try await item.$wishlist.get(on: req.db)
        guard wishlist.$owner.id == userId else { throw Abort(.notFound) }

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

        try await item.save(on: req.db)
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
        guard item.$wishlist.id == wishlistID else { throw Abort(.notFound) }

        let wishlist = try await item.$wishlist.get(on: req.db)
        guard wishlist.$owner.id == userId else { throw Abort(.notFound) }

        try await item.delete(on: req.db)
        return .noContent
    }
}
