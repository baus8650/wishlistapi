//
//  ShareController.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//


import Vapor
import Fluent

// -----------------------------------------------------------------------------
// ROUTES (all are mounted under /v1)
// -----------------------------------------------------------------------------
// Recipient (public, anonymous share link):
//   GET  /v1/shares/:shareToken
//   GET  /v1/shares/:shareToken/items                 (requires X-Viewer-Token)
//   PUT  /v1/shares/:shareToken/items/:itemID/state   (requires X-Viewer-Token)
//
// Owner (protected, mounted under /v1/wishlists):
//   POST   /v1/wishlists/:wishlistID/shares
//   GET    /v1/wishlists/:wishlistID/shares
//   DELETE /v1/wishlists/:wishlistID/shares/:shareID
//   POST   /v1/wishlists/:wishlistID/shares/:shareID/rotate
// -----------------------------------------------------------------------------

// Example cURL (owner creates share link):
//   curl -s -X POST \
//     -H "Authorization: Bearer $TOKEN" \
//     http://127.0.0.1:8080/v1/wishlists/$WISHLIST_ID/shares
//
// Example cURL (recipient opens share link, gets viewer token):
//   curl -s http://127.0.0.1:8080/v1/shares/$SHARE_TOKEN
//
// Example cURL (recipient lists items with state):
//   curl -s \
//     -H "X-Viewer-Token: $VIEWER_TOKEN" \
//     http://127.0.0.1:8080/v1/shares/$SHARE_TOKEN/items
//
// Example cURL (recipient marks purchased):
//   curl -s -X PUT \
//     -H "Content-Type: application/json" \
//     -H "X-Viewer-Token: $VIEWER_TOKEN" \
//     -d '{"purchased":true,"displayName":"Alex","shareName":true}' \
//     http://127.0.0.1:8080/v1/shares/$SHARE_TOKEN/items/$ITEM_ID/state
// -----------------------------------------------------------------------------

struct RecipientShareController: RouteCollection {

    // Returned when someone opens a share link
    struct ShareViewResponse: Content {
        let wishlist: SharedWishlistPublic
        let items: [WishlistItem]
        let viewerToken: String
    }

    struct SharedWishlistPublic: Content {
        let id: UUID
        let title: String
        let sharedByName: String
    }

    struct UpsertStateRequest: Content {
        let purchased: Bool?
        let note: String?
        let displayName: String?
        let shareName: Bool?
    }

    struct RecipientNote: Content {
        let note: String
        let authorDisplayName: String?
        let updatedAt: Date?
    }

    struct ItemWithRecipientInfo: Content {
        let item: WishlistItem
        let purchased: Bool          // purchased by anyone
        let purchasedByMe: Bool      // purchased by this viewer
        let notes: [RecipientNote]   // notes from all recipients
    }

    func boot(routes: any RoutesBuilder) throws {
        // Recipient: view list by share token (creates/returns viewerToken)
        routes.get("shares", ":shareToken", use: viewSharedWishlist)

        // Recipient: get items + their state (requires viewer token)
        routes.get("shares", ":shareToken", "items", use: listItemsWithState)

        // Recipient: set purchased/note (requires viewer token; requires displayName when purchased=true and name missing)
        routes.put("shares", ":shareToken", "items", ":itemID", "state", use: upsertState)
    }

    // MARK: Recipient views shared wishlist (creates viewer token silently)
    func viewSharedWishlist(req: Request) async throws -> ShareViewResponse {
        guard let shareToken = req.parameters.get("shareToken") else {
            throw Abort(.badRequest, reason: "Missing share token.")
        }

        let linkHash = Tokens.sha256Hex(shareToken)

        guard let link = try await WishlistShareLink.query(on: req.db)
            .filter(\.$tokenHash == linkHash)
            .first()
        else { throw Abort(.notFound) }

        let wishlist = try await link.$wishlist.get(on: req.db)
        let wishlistId = try wishlist.requireID()
        let owner = try await wishlist.$owner.get(on: req.db)
        let configuredName = owner.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = owner.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Someone"
        let publicWishlist = SharedWishlistPublic(
            id: wishlistId,
            title: wishlist.title,
            sharedByName: configuredName?.isEmpty == false ? configuredName! : fallbackName
        )

        let items = try await WishlistItem.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistId)
            .sort(\.$createdAt, .ascending)
            .all()

        // Viewer token comes from header if they already have it
        let headerToken = req.headers.first(name: "X-Viewer-Token")

        if let existingToken = headerToken, !existingToken.isEmpty {
            let viewerHash = Tokens.sha256Hex(existingToken)
            let existingViewer = try await WishlistViewer.query(on: req.db)
                .filter(\.$wishlist.$id == wishlistId)
                .filter(\.$viewerTokenHash == viewerHash)
                .first()

            if existingViewer != nil {
                return .init(wishlist: publicWishlist, items: items, viewerToken: existingToken)
            }
        }

        // Otherwise create a new anonymous viewer (no display name yet)
        let viewerToken = try Tokens.randomURLSafeToken()
        let viewerHash = Tokens.sha256Hex(viewerToken)

        let viewer = WishlistViewer(
            wishlistId: wishlistId,
            viewerTokenHash: viewerHash,
            displayName: nil,
            userId: nil
        )
        try await viewer.save(on: req.db)

        return .init(wishlist: publicWishlist, items: items, viewerToken: viewerToken)
    }

    // MARK: Recipient lists items + their state
    func listItemsWithState(req: Request) async throws -> [ItemWithRecipientInfo] {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)

        let wishlistId = try wishlist.requireID()
        let viewerId = try viewer.requireID()

        let items = try await WishlistItem.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistId)
            .sort(\.$createdAt, .ascending)
            .all()

        let itemIds: [UUID] = items.compactMap { $0.id }
        if itemIds.isEmpty { return [] }

        // Pull ALL states for items in this wishlist (shared among recipients)
        let states = try await ItemViewerState.query(on: req.db)
            .filter(\.$item.$id ~~ itemIds)
            .all()

        // Collect viewer IDs referenced by those states so we can fetch display names in bulk
        let viewerIds = Array(Set(states.map { $0.$viewer.id }))
        let viewers = try await WishlistViewer.query(on: req.db)
            .filter(\.$id ~~ viewerIds)
            .all()

        let displayNameByViewerId: [UUID: String] = Dictionary(
            uniqueKeysWithValues: viewers.compactMap { v in
                guard let id = v.id else { return nil }
                let name = (v.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                return (id, name)
            }
        )

        // Group states by item
        var statesByItem: [UUID: [ItemViewerState]] = [:]
        statesByItem.reserveCapacity(itemIds.count)
        for s in states {
            let itemId = s.$item.id
            statesByItem[itemId, default: []].append(s)
        }

        return items.map { item in
            guard let id = item.id else {
                return ItemWithRecipientInfo(item: item, purchased: false, purchasedByMe: false, notes: [])
            }

            let itemStates = statesByItem[id] ?? []

            let purchasedByAnyone = itemStates.contains(where: { $0.purchased })
            let myState = itemStates.first(where: { $0.$viewer.id == viewerId })
            let purchasedByMe = myState?.purchased ?? false

            // Notes from all recipients (if enabled). Only show author's display name if:
            // - wishlist allows purchaser names AND
            // - that viewer opted in via shareName.
            let notes: [RecipientNote]
            if wishlist.allowNotes {
                notes = itemStates.compactMap { s in
                    let raw = (s.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return nil }

                    let authorName: String?
                    if wishlist.showPurchaserNames && s.shareName {
                        authorName = displayNameByViewerId[s.$viewer.id]
                    } else {
                        authorName = nil
                    }

                    return RecipientNote(note: raw, authorDisplayName: authorName, updatedAt: s.updatedAt)
                }
                .sorted { (a, b) in
                    // newest first if timestamps exist
                    switch (a.updatedAt, b.updatedAt) {
                    case let (x?, y?): return x > y
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: return false
                    }
                }
            } else {
                notes = []
            }

            return ItemWithRecipientInfo(
                item: item,
                purchased: purchasedByAnyone,
                purchasedByMe: purchasedByMe,
                notes: notes
            )
        }
    }

    // MARK: Recipient updates state
    func upsertState(req: Request) async throws -> ItemWithRecipientInfo {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        let body = try req.content.decode(UpsertStateRequest.self)
        let wishlistId = try wishlist.requireID()
        let viewerId = try viewer.requireID()

        // Enforce wishlist settings: notes can be disabled
        if body.note != nil && !wishlist.allowNotes {
            throw Abort(.forbidden, reason: "Notes are disabled for this wishlist.")
        }

        let wantsShareName = (body.shareName == true)
        if wantsShareName && (viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            let name = (body.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw Abort(.badRequest, reason: "displayName is required to share your name.")
            }
            viewer.displayName = name
            try await viewer.save(on: req.db)
        }

        guard let itemID = req.parameters.get("itemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid itemID.")
        }

        // Ensure item belongs to wishlist
        guard let item = try await WishlistItem.query(on: req.db)
            .filter(\.$id == itemID)
            .filter(\.$wishlist.$id == wishlistId)
            .first()
        else { throw Abort(.notFound) }

        // If turning purchased ON and viewer has no name, require displayName
        let turningPurchasedOn = (body.purchased == true)
        // Enforce wishlist settings: prevent multiple purchasers when configured.
        if turningPurchasedOn && (wishlist.autoLockOnPurchase || !wishlist.allowMultiplePurchases) {
            // If SOMEONE ELSE already has purchased=true for this item, reject.
            let existingOtherPurchase = try await ItemViewerState.query(on: req.db)
                .filter(\.$item.$id == itemID)
                .filter(\.$purchased == true)
                .filter(\.$viewer.$id != viewerId)
                .first()

            if existingOtherPurchase != nil {
                throw Abort(.conflict, reason: "Item is already marked as purchased.")
            }
        }
        if turningPurchasedOn && (viewer.displayName == nil || viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true) {
            let name = (body.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw Abort(.badRequest, reason: "displayName is required to mark an item as purchased.")
            }
            viewer.displayName = name
            try await viewer.save(on: req.db)
        }


        let state = try await ItemViewerState.query(on: req.db)
            .filter(\.$item.$id == itemID)
            .filter(\.$viewer.$id == viewerId)
            .first()

        if let state {
            if let purchased = body.purchased { state.purchased = purchased }
            if wishlist.allowNotes, let note = body.note { state.note = note }
            if let shareName = body.shareName { state.shareName = shareName }
            try await state.save(on: req.db)

            // purchased by anyone (not just this viewer)
            let purchasedByAnyone = (try await ItemViewerState.query(on: req.db)
                .filter(\.$item.$id == itemID)
                .filter(\.$purchased == true)
                .first()) != nil

            let purchasedByMe = state.purchased
            let notes: [RecipientNote] = {
                guard wishlist.allowNotes else { return [] }
                let raw = (state.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return [] }
                let author = (wishlist.showPurchaserNames && state.shareName) ? viewer.displayName : nil
                return [RecipientNote(note: raw, authorDisplayName: author, updatedAt: state.updatedAt)]
            }()

            return ItemWithRecipientInfo(item: item, purchased: purchasedByAnyone, purchasedByMe: purchasedByMe, notes: notes)
        } else {
            let purchased = body.purchased ?? false
            let shareName = body.shareName ?? false
            let newState = ItemViewerState(itemId: itemID, viewerId: viewerId, purchased: purchased, note: wishlist.allowNotes ? body.note : nil, shareName: shareName)
            try await newState.save(on: req.db)

            let notes: [RecipientNote] = {
                guard wishlist.allowNotes else { return [] }
                let raw = (newState.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return [] }
                let author = (wishlist.showPurchaserNames && newState.shareName) ? viewer.displayName : nil
                return [RecipientNote(note: raw, authorDisplayName: author, updatedAt: newState.updatedAt)]
            }()

            let purchasedByAnyone = (try await ItemViewerState.query(on: req.db)
                .filter(\.$item.$id == itemID)
                .filter(\.$purchased == true)
                .first()) != nil

            return ItemWithRecipientInfo(item: item, purchased: purchasedByAnyone, purchasedByMe: purchased, notes: notes)
        }
    }

    // MARK: Helpers
    private func resolveWishlistAndViewer(req: Request) async throws -> (Wishlist, WishlistViewer) {
        guard let shareToken = req.parameters.get("shareToken") else {
            throw Abort(.badRequest, reason: "Missing share token.")
        }
        let linkHash = Tokens.sha256Hex(shareToken)

        guard let link = try await WishlistShareLink.query(on: req.db)
            .filter(\.$tokenHash == linkHash)
            .first()
        else { throw Abort(.notFound) }

        let wishlist = try await link.$wishlist.get(on: req.db)
        let wishlistId = try wishlist.requireID()

        guard let viewerToken = req.headers.first(name: "X-Viewer-Token"), !viewerToken.isEmpty else {
            throw Abort(.unauthorized, reason: "Missing X-Viewer-Token.")
        }
        let viewerHash = Tokens.sha256Hex(viewerToken)

        guard let viewer = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistId)
            .filter(\.$viewerTokenHash == viewerHash)
            .first()
        else { throw Abort(.unauthorized, reason: "Invalid viewer token.") }

        return (wishlist, viewer)
    }
}

struct OwnerShareController: RouteCollection {

    struct CreateShareLinkResponse: Content {
        let shareToken: String
    }

    struct ShareLinkResponse: Content {
        let id: UUID
        let createdAt: Date?
    }

    func boot(routes: any RoutesBuilder) throws {
        // Owner: create a share link (mounted under /wishlists)
        routes.post(":wishlistID", "shares", use: createShareLink)

        // Owner: list share links for a wishlist
        routes.get(":wishlistID", "shares", use: listShareLinks)

        // Owner: revoke a share link
        routes.delete(":wishlistID", "shares", ":shareID", use: deleteShareLink)

        // Owner: rotate a share link token (invalidates the old token)
        routes.post(":wishlistID", "shares", ":shareID", "rotate", use: rotateShareLink)
    }

    func createShareLink(req: Request) async throws -> CreateShareLinkResponse {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        guard let _ = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        let shareToken = try Tokens.randomURLSafeToken()
        let tokenHash = Tokens.sha256Hex(shareToken)

        let link = WishlistShareLink(wishlistId: wishlistID, tokenHash: tokenHash)
        try await link.save(on: req.db)

        return .init(shareToken: shareToken)
    }

    func listShareLinks(req: Request) async throws -> [ShareLinkResponse] {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid wishlistID.")
        }

        // Ensure the wishlist belongs to this user
        guard let _ = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        let links = try await WishlistShareLink.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .sort(\.$createdAt, .descending)
            .all()

        // id is non-nil for persisted models, but guard defensively
        return links.compactMap { link in
            guard let id = link.id else { return nil }
            return ShareLinkResponse(id: id, createdAt: link.createdAt)
        }
    }

    func deleteShareLink(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard
            let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
            let shareID = req.parameters.get("shareID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid wishlistID or shareID.")
        }

        // Ensure the wishlist belongs to this user
        guard let _ = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        guard let link = try await WishlistShareLink.query(on: req.db)
            .filter(\.$id == shareID)
            .filter(\.$wishlist.$id == wishlistID)
            .first()
        else { throw Abort(.notFound) }

        try await link.delete(on: req.db)
        return .noContent
    }

    func rotateShareLink(req: Request) async throws -> CreateShareLinkResponse {
        let user = try req.auth.require(User.self)
        let userId = try user.requireID()

        guard
            let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
            let shareID = req.parameters.get("shareID", as: UUID.self)
        else {
            throw Abort(.badRequest, reason: "Invalid wishlistID or shareID.")
        }

        // Ensure the wishlist belongs to this user
        guard let _ = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        guard let link = try await WishlistShareLink.query(on: req.db)
            .filter(\.$id == shareID)
            .filter(\.$wishlist.$id == wishlistID)
            .first()
        else { throw Abort(.notFound) }

        let newToken = try Tokens.randomURLSafeToken()
        link.tokenHash = Tokens.sha256Hex(newToken)
        try await link.save(on: req.db)

        return .init(shareToken: newToken)
    }
}
