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
        let requiresAdultConfirmation: Bool
    }

    struct ConfirmAdultShareRequest: Content {
        let confirmedAdult: Bool
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
        let purchasedQuantity: Int?
    }

    struct RecipientNote: Content {
        let note: String
        let authorDisplayName: String?
        let updatedAt: Date?
        let isMine: Bool
    }

    struct DiscussionCommentResponse: Content {
        let id: UUID
        let message: String
        let authorDisplayName: String?
        let createdAt: Date?
        let isMine: Bool
    }

    struct CreateDiscussionCommentRequest: Content {
        let message: String
        let displayName: String?
        let shareName: Bool?
    }

    struct ItemWithRecipientInfo: Content {
        let item: WishlistItem
        let purchased: Bool          // purchased by anyone
        let purchasedByMe: Bool      // purchased by this viewer
        let purchasedByOthers: Bool  // purchased by another viewer
        let purchasedQuantity: Int   // total quantity claimed by all viewers
        let purchasedQuantityByMe: Int
        let purchasedByNames: [String]? // named planners who purchased (gift planning only)
        let notes: [RecipientNote]   // notes from all recipients
    }

    func boot(routes: any RoutesBuilder) throws {
        // Recipient: view list by share token (creates/returns viewerToken)
        routes.get("shares", ":shareToken", use: viewSharedWishlist)
        routes.post("shares", ":shareToken", "confirm-adult", use: confirmAdultShare)

        // Recipient: get items + their state (requires viewer token)
        routes.get("shares", ":shareToken", "items", use: listItemsWithState)

        // Recipient: set purchased/note (requires viewer token; requires displayName when purchased=true and name missing)
        routes.put("shares", ":shareToken", "items", ":itemID", "state", use: upsertState)
        routes.get("shares", ":shareToken", "discussion", use: listDiscussion)
        routes.post("shares", ":shareToken", "discussion", use: createDiscussionComment)
        routes.delete("shares", ":shareToken", "discussion", ":commentID", use: deleteDiscussionComment)
        routes.get("shares", ":shareToken", "mention-candidates", use: listMentionCandidates)
    }

    func listMentionCandidates(req: Request) async throws -> [SocialUserDTO] {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        try await ensureDiscussionAccess(wishlist: wishlist, viewer: viewer, req: req)
        guard viewer.$user.id != nil else { return [] }
        return try await MentionService.candidates(
            for: try wishlist.requireID(),
            excluding: viewer.$user.id,
            on: req.db
        )
    }

    func listDiscussion(req: Request) async throws -> [DiscussionCommentResponse] {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        try await ensureDiscussionAccess(wishlist: wishlist, viewer: viewer, req: req)
        let wishlistID = try wishlist.requireID()
        let viewerID = try viewer.requireID()
        let comments = try await WishlistDiscussionComment.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .sort(\.$createdAt, .ascending)
            .all()
        let viewerIDs = Array(Set(comments.map(\.$viewer.id)))
        let viewers = try await WishlistViewer.query(on: req.db).filter(\.$id ~~ viewerIDs).all()
        let names = Dictionary(uniqueKeysWithValues: viewers.compactMap { item -> (UUID, String)? in
            guard let id = item.id else { return nil }
            let name = (item.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (id, name)
        })
        return comments.compactMap { comment in
            guard let id = comment.id else { return nil }
            return .init(
                id: id,
                message: comment.message,
                authorDisplayName: comment.shareName ? names[comment.$viewer.id] : nil,
                createdAt: comment.createdAt,
                isMine: comment.$viewer.id == viewerID
            )
        }
    }

    func createDiscussionComment(req: Request) async throws -> DiscussionCommentResponse {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        try await ensureDiscussionAccess(wishlist: wishlist, viewer: viewer, req: req)
        let body = try req.content.decode(CreateDiscussionCommentRequest.self)
        let message = body.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 1_000 else {
            throw Abort(.badRequest, reason: "Comments must be between 1 and 1,000 characters.")
        }
        if let actorID = viewer.$user.id {
            try await MentionService.validateMentions(
                in: message,
                wishlistID: try wishlist.requireID(),
                actorID: actorID,
                on: req.db
            )
        }
        let shareName = body.shareName == true
        if shareName {
            let submittedName = body.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedName = viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard submittedName?.isEmpty == false || savedName?.isEmpty == false else {
                throw Abort(.badRequest, reason: "A display name is required to share your name.")
            }
            if let submittedName, !submittedName.isEmpty, submittedName != savedName {
                guard submittedName.count <= 80 else { throw Abort(.badRequest, reason: "Display name is too long.") }
                viewer.displayName = submittedName
                try await viewer.save(on: req.db)
            }
        }
        let comment = WishlistDiscussionComment(
            wishlistID: try wishlist.requireID(),
            viewerID: try viewer.requireID(),
            message: message,
            shareName: shareName
        )
        try await comment.save(on: req.db)
        if let actorID = viewer.$user.id {
          do {
            let configuredName = viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let actorName = configuredName?.isEmpty == false ? configuredName! : "Someone"
            try await MentionService.notifyNewMentions(
                in: message,
                wishlistID: try wishlist.requireID(),
                actorID: actorID,
                actorName: actorName,
                context: "in a wishlist comment.",
                on: req.db,
                client: req.client,
                logger: req.logger
            )
          } catch {
            req.logger.warning("Comment was saved, but mention notifications could not be created: \(error)")
          }
        }
        return .init(
            id: try comment.requireID(),
            message: comment.message,
            authorDisplayName: shareName ? viewer.displayName : nil,
            createdAt: comment.createdAt,
            isMine: true
        )
    }

    func deleteDiscussionComment(req: Request) async throws -> HTTPStatus {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        try await ensureDiscussionAccess(wishlist: wishlist, viewer: viewer, req: req)
        let wishlistID = try wishlist.requireID()
        let viewerID = try viewer.requireID()
        guard let commentID = req.parameters.get("commentID", as: UUID.self),
              let comment = try await WishlistDiscussionComment.query(on: req.db)
                .filter(\.$id == commentID)
                .filter(\.$wishlist.$id == wishlistID)
                .filter(\.$viewer.$id == viewerID)
                .first()
        else { throw Abort(.notFound) }
        try await comment.delete(on: req.db)
        return .noContent
    }

    // MARK: Recipient views shared wishlist (creates viewer token silently)
    func viewSharedWishlist(req: Request) async throws -> ShareViewResponse {
        let (wishlist, owner, viewer, viewerToken) = try await resolveShareForGuest(req: req, createViewerIfNeeded: true)
        let wishlistID = try wishlist.requireID()
        let requiresAdultConfirmation = requiresAdultConfirmation(for: wishlist, owner: owner)
        let guestConfirmed = isRecentAdultConfirmation(viewer.adultConfirmedAt)
        let account = req.auth.get(User.self)
        if requiresAdultConfirmation, let account, account.derivedAgeBand != "adult" {
            throw Abort(.forbidden, reason: "This content is not available to your account.")
        }
        let contentAllowed = !requiresAdultConfirmation || account?.derivedAgeBand == "adult" || guestConfirmed
        let items = try await sharedItems(
            wishlistID: wishlistID,
            on: req.db,
            includeContent: contentAllowed
        )

        return .init(
            wishlist: try publicWishlist(wishlist: wishlist, owner: owner, includeIdentifyingContent: contentAllowed),
            items: items,
            viewerToken: viewerToken,
            requiresAdultConfirmation: requiresAdultConfirmation && account == nil && !guestConfirmed
        )
    }

    func confirmAdultShare(req: Request) async throws -> ShareViewResponse {
        let body = try req.content.decode(ConfirmAdultShareRequest.self)
        guard body.confirmedAdult else {
            throw Abort(.forbidden, reason: "This list is available only to adults 18 and older.")
        }

        let (wishlist, owner, viewer, _) = try await resolveShareForGuest(req: req)
        guard requiresAdultConfirmation(for: wishlist, owner: owner) else {
            return try await viewSharedWishlist(req: req)
        }
        if let account = req.auth.get(User.self) {
            guard account.derivedAgeBand == "adult" else {
                throw Abort(.forbidden, reason: "This content is not available to your account.")
            }
            return try await viewSharedWishlist(req: req)
        }
        viewer.adultConfirmedAt = Date()
        try await viewer.save(on: req.db)
        return try await viewSharedWishlist(req: req)
    }

    // MARK: Recipient lists items + their state
    func listItemsWithState(req: Request) async throws -> [ItemWithRecipientInfo] {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        return try await listItemsWithState(req: req, wishlist: wishlist, viewer: viewer)
    }

    func listItemsWithState(req: Request, wishlist: Wishlist, viewer: WishlistViewer) async throws -> [ItemWithRecipientInfo] {
        let wishlistId = try wishlist.requireID()
        let viewerId = try viewer.requireID()

        let items = try await WishlistItemMembership.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistId)
            .sort(\.$position, .ascending)
            .with(\.$item)
            .all()
            .map(\.item)

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
        let viewerWishlistByID = Dictionary(uniqueKeysWithValues: viewers.compactMap { viewer in
            viewer.id.map { ($0, viewer.$wishlist.id) }
        })

        // Group states by item
        var statesByItem: [UUID: [ItemViewerState]] = [:]
        statesByItem.reserveCapacity(itemIds.count)
        for s in states {
            let itemId = s.$item.id
            statesByItem[itemId, default: []].append(s)
        }

        return items.map { item in
            guard let id = item.id else {
                return ItemWithRecipientInfo(item: item, purchased: false, purchasedByMe: false, purchasedByOthers: false, purchasedQuantity: 0, purchasedQuantityByMe: 0, purchasedByNames: nil, notes: [])
            }

            let itemStates = statesByItem[id] ?? []

            let purchasedQuantity = itemStates.reduce(0) { $0 + $1.purchasedQuantity }
            let purchasedByAnyone = purchasedQuantity > 0
            let myState = itemStates.first(where: { $0.$viewer.id == viewerId })
            let purchasedQuantityByMe = myState?.purchasedQuantity ?? 0
            let purchasedByMe = purchasedQuantityByMe > 0

            // Notes from all recipients (if enabled). Only show author's display name if:
            // - wishlist allows purchaser names AND
            // - that viewer opted in via shareName.
            let notes: [RecipientNote]
            if wishlist.allowNotes {
                notes = itemStates.compactMap { s in
                    guard viewerWishlistByID[s.$viewer.id] == wishlistId else { return nil }
                    let raw = (s.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !raw.isEmpty else { return nil }

                    let authorName: String?
                    if s.shareName {
                        authorName = displayNameByViewerId[s.$viewer.id]
                    } else {
                        authorName = nil
                    }

                    return RecipientNote(note: raw, authorDisplayName: authorName, updatedAt: s.updatedAt, isMine: s.$viewer.id == viewerId)
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

            let purchasedByNames: [String]?
            if wishlist.collaborationMode == "gift_planning" {
                var names: [String] = []
                for state in itemStates where state.$viewer.id != viewerId && state.purchasedQuantity > 0 && viewerWishlistByID[state.$viewer.id] == wishlistId {
                    guard let name = displayNameByViewerId[state.$viewer.id], !names.contains(name) else { continue }
                    names.append(name)
                }
                purchasedByNames = names
            } else {
                purchasedByNames = nil
            }

            return ItemWithRecipientInfo(
                item: item,
                purchased: purchasedByAnyone,
                purchasedByMe: purchasedByMe,
                purchasedByOthers: purchasedQuantity > purchasedQuantityByMe,
                purchasedQuantity: purchasedQuantity,
                purchasedQuantityByMe: purchasedQuantityByMe,
                purchasedByNames: purchasedByNames,
                notes: notes
            )
        }
    }

    // MARK: Recipient updates state
    func upsertState(req: Request) async throws -> ItemWithRecipientInfo {
        let (wishlist, viewer) = try await resolveWishlistAndViewer(req: req)
        return try await upsertState(req: req, wishlist: wishlist, viewer: viewer)
    }

    func upsertState(req: Request, wishlist: Wishlist, viewer: WishlistViewer) async throws -> ItemWithRecipientInfo {
        let body = try req.content.decode(UpsertStateRequest.self)
        let wishlistId = try wishlist.requireID()
        let viewerId = try viewer.requireID()

        // Enforce wishlist settings: notes can be disabled
        if body.note != nil && !wishlist.allowNotes {
            throw Abort(.forbidden, reason: "Notes are disabled for this wishlist.")
        }

        let wantsShareName = (body.shareName == true)
        if wantsShareName {
            let submittedName = body.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let savedName = viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard submittedName?.isEmpty == false || savedName?.isEmpty == false else {
                throw Abort(.badRequest, reason: "displayName is required to share your name.")
            }
            if let submittedName, !submittedName.isEmpty, submittedName != savedName {
                viewer.displayName = submittedName
                try await viewer.save(on: req.db)
            }
        }

        guard let itemID = req.parameters.get("itemID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid itemID.")
        }

        // Ensure item belongs to wishlist
        guard try await WishlistItemMembership.query(on: req.db)
            .filter(\.$item.$id == itemID)
            .filter(\.$wishlist.$id == wishlistId)
            .first() != nil,
              let item = try await WishlistItem.find(itemID, on: req.db)
        else { throw Abort(.notFound) }

        let state = try await ItemViewerState.query(on: req.db)
            .filter(\.$item.$id == itemID)
            .filter(\.$viewer.$id == viewerId)
            .first()
        let previousNote = state?.note

        let desiredQuantity: Int? = body.purchasedQuantity ?? body.purchased.map {
            $0 ? max(state?.purchasedQuantity ?? 0, 1) : 0
        }
        if let desiredQuantity {
            guard desiredQuantity >= 0 && desiredQuantity <= item.quantity else {
                throw Abort(.badRequest, reason: "Purchased quantity must be between 0 and \(item.quantity).")
            }
            let otherStates = try await ItemViewerState.query(on: req.db)
                .filter(\.$item.$id == itemID)
                .filter(\.$viewer.$id != viewerId)
                .all()
            let claimedByOthers = otherStates.reduce(0) { $0 + $1.purchasedQuantity }
            guard claimedByOthers + desiredQuantity <= item.quantity else {
                throw Abort(.conflict, reason: "Only \(max(0, item.quantity - claimedByOthers)) remain available.")
            }
        }

        // If turning purchased ON and viewer has no name, require displayName
        let turningPurchasedOn = (desiredQuantity ?? 0) > 0
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

        if let note = body.note, wishlist.allowNotes, let actorID = viewer.$user.id {
            try await MentionService.validateMentions(
                in: note,
                wishlistID: wishlistId,
                actorID: actorID,
                on: req.db
            )
        }

        if let state {
            if let desiredQuantity {
                state.purchasedQuantity = desiredQuantity
                state.purchased = desiredQuantity > 0
            }
            if wishlist.allowNotes, let note = body.note { state.note = note }
            if let shareName = body.shareName { state.shareName = shareName }
            try await state.save(on: req.db)
            if let note = body.note, let actorID = viewer.$user.id {
                do {
                    let configuredName = viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let actorName = configuredName?.isEmpty == false ? configuredName! : "Someone"
                    try await MentionService.notifyNewMentions(
                        in: note,
                        previousText: previousNote,
                        wishlistID: wishlistId,
                        actorID: actorID,
                        actorName: actorName,
                        context: "in an item note.",
                        on: req.db,
                        client: req.client,
                        logger: req.logger
                    )
                } catch {
                    req.logger.warning("Item state was saved, but note mention notifications could not be created: \(error)")
                }
            }

            // purchased by anyone (not just this viewer)
            let allStates = try await ItemViewerState.query(on: req.db).filter(\.$item.$id == itemID).all()
            let purchasedQuantity = allStates.reduce(0) { $0 + $1.purchasedQuantity }
            let purchasedByAnyone = purchasedQuantity > 0
            let purchasedByNames = try await namedPurchasers(
                in: allStates,
                excluding: viewerId,
                wishlist: wishlist,
                on: req.db
            )

            let purchasedByMe = state.purchased
            let notes: [RecipientNote] = {
                guard wishlist.allowNotes else { return [] }
                let raw = (state.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return [] }
                let author = state.shareName ? viewer.displayName : nil
                return [RecipientNote(note: raw, authorDisplayName: author, updatedAt: state.updatedAt, isMine: true)]
            }()

            return ItemWithRecipientInfo(item: item, purchased: purchasedByAnyone, purchasedByMe: purchasedByMe, purchasedByOthers: purchasedQuantity > state.purchasedQuantity, purchasedQuantity: purchasedQuantity, purchasedQuantityByMe: state.purchasedQuantity, purchasedByNames: purchasedByNames, notes: notes)
        } else {
            let purchasedQuantity = desiredQuantity ?? 0
            let purchased = purchasedQuantity > 0
            let shareName = body.shareName ?? false
            let newState = ItemViewerState(itemId: itemID, viewerId: viewerId, purchased: purchased, purchasedQuantity: purchasedQuantity, note: wishlist.allowNotes ? body.note : nil, shareName: shareName)
            try await newState.save(on: req.db)
            if let note = body.note, let actorID = viewer.$user.id {
                do {
                    let configuredName = viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let actorName = configuredName?.isEmpty == false ? configuredName! : "Someone"
                    try await MentionService.notifyNewMentions(
                        in: note,
                        wishlistID: wishlistId,
                        actorID: actorID,
                        actorName: actorName,
                        context: "in an item note.",
                        on: req.db,
                        client: req.client,
                        logger: req.logger
                    )
                } catch {
                    req.logger.warning("Item state was saved, but note mention notifications could not be created: \(error)")
                }
            }

            let notes: [RecipientNote] = {
                guard wishlist.allowNotes else { return [] }
                let raw = (newState.note ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !raw.isEmpty else { return [] }
                let author = newState.shareName ? viewer.displayName : nil
                return [RecipientNote(note: raw, authorDisplayName: author, updatedAt: newState.updatedAt, isMine: true)]
            }()

            let allStates = try await ItemViewerState.query(on: req.db).filter(\.$item.$id == itemID).all()
            let totalPurchasedQuantity = allStates.reduce(0) { $0 + $1.purchasedQuantity }
            let purchasedByAnyone = totalPurchasedQuantity > 0
            let purchasedByNames = try await namedPurchasers(
                in: allStates,
                excluding: viewerId,
                wishlist: wishlist,
                on: req.db
            )

            return ItemWithRecipientInfo(item: item, purchased: purchasedByAnyone, purchasedByMe: purchased, purchasedByOthers: totalPurchasedQuantity > purchasedQuantity, purchasedQuantity: totalPurchasedQuantity, purchasedQuantityByMe: purchasedQuantity, purchasedByNames: purchasedByNames, notes: notes)
        }
    }

    // MARK: Helpers
    private func resolveShareForGuest(
        req: Request,
        createViewerIfNeeded: Bool = false
    ) async throws -> (wishlist: Wishlist, owner: User, viewer: WishlistViewer, viewerToken: String) {
        guard let shareToken = req.parameters.get("shareToken") else {
            throw Abort(.badRequest, reason: "Missing share token.")
        }

        guard let link = try await WishlistShareLink.query(on: req.db)
            .filter(\.$tokenHash == Tokens.sha256Hex(shareToken))
            .first()
        else { throw Abort(.notFound) }

        let wishlist = try await link.$wishlist.get(on: req.db)
        let owner = try await wishlist.$owner.get(on: req.db)
        let wishlistID = try wishlist.requireID()
        let suppliedToken = req.headers.first(name: "X-Viewer-Token")

        if let account = req.auth.get(User.self),
           try await !ProfileAccessService.canViewWishlist(viewer: account, wishlist: wishlist, owner: owner, on: req.db) {
            throw Abort(.notFound)
        }

        if let suppliedToken, !suppliedToken.isEmpty,
           let viewer = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$viewerTokenHash == Tokens.sha256Hex(suppliedToken))
            .first() {
            return (wishlist, owner, viewer, suppliedToken)
        }

        guard createViewerIfNeeded else {
            throw Abort(.unauthorized, reason: "Missing or invalid viewer token.")
        }

        let viewerToken = try Tokens.randomURLSafeToken()
        let viewer = WishlistViewer(
            wishlistId: wishlistID,
            viewerTokenHash: Tokens.sha256Hex(viewerToken),
            displayName: nil,
            userId: req.auth.get(User.self)?.id
        )
        try await viewer.save(on: req.db)
        return (wishlist, owner, viewer, viewerToken)
    }

    private func publicWishlist(wishlist: Wishlist, owner: User, includeIdentifyingContent: Bool = true) throws -> SharedWishlistPublic {
        guard includeIdentifyingContent else {
            return .init(id: try wishlist.requireID(), title: "Age-limited wishlist", sharedByName: "Hushful member")
        }
        let configuredName = owner.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = owner.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Someone"
        return .init(
            id: try wishlist.requireID(),
            title: wishlist.title,
            sharedByName: configuredName?.isEmpty == false ? configuredName! : fallbackName
        )
    }

    private func sharedItems(
        wishlistID: UUID,
        on db: any Database,
        includeContent: Bool
    ) async throws -> [WishlistItem] {
        guard includeContent else { return [] }
        return try await WishlistItemMembership.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .sort(\.$position, .ascending)
            .with(\.$item)
            .all()
            .map(\.item)
    }

    private func requiresAdultConfirmation(for wishlist: Wishlist, owner: User) -> Bool {
        wishlist.matureContentEnabled || owner.isAgeRestrictedProfile
    }

    private func isRecentAdultConfirmation(_ date: Date?) -> Bool {
        guard let date else { return false }
        let now = Date()
        return date <= now && date >= now.addingTimeInterval(-30 * 24 * 60 * 60)
    }

    private func namedPurchasers(
        in states: [ItemViewerState],
        excluding viewerID: UUID,
        wishlist: Wishlist,
        on db: any Database
    ) async throws -> [String]? {
        guard wishlist.collaborationMode == "gift_planning" else { return nil }
        let wishlistID = try wishlist.requireID()

        let viewerIDs = Array(Set(states
            .filter { $0.$viewer.id != viewerID && $0.purchasedQuantity > 0 }
            .map { $0.$viewer.id }))
        guard !viewerIDs.isEmpty else { return [] }

        let viewers = try await WishlistViewer.query(on: db)
            .filter(\.$id ~~ viewerIDs)
            .filter(\.$wishlist.$id == wishlistID)
            .all()

        let displayNameByViewerID: [UUID: String] = Dictionary(
            uniqueKeysWithValues: viewers.compactMap { viewer in
                guard let id = viewer.id else { return nil }
                let name = (viewer.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? nil : (id, name)
            }
        )
        var names: [String] = []
        for state in states {
            guard state.$viewer.id != viewerID,
                  state.purchasedQuantity > 0,
                  let name = displayNameByViewerID[state.$viewer.id],
                  !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    private func resolveWishlistAndViewer(req: Request) async throws -> (Wishlist, WishlistViewer) {
        if let accountShareID = req.parameters.get("accountShareID", as: UUID.self),
           let user = req.auth.get(User.self) {
            let userID = try user.requireID()
            guard let viewer = try await WishlistViewer.query(on: req.db)
                .filter(\.$id == accountShareID)
                .filter(\.$user.$id == userID)
                .first() else {
                throw Abort(.notFound)
            }
            let wishlist = try await viewer.$wishlist.get(on: req.db)
            let owner = try await wishlist.$owner.get(on: req.db)
            guard try await ProfileAccessService.canViewWishlist(viewer: user, wishlist: wishlist, owner: owner, on: req.db) else {
                throw Abort(.notFound)
            }
            try await ensureAgeAccess(wishlist: wishlist, user: user, includeOwnerProfile: true, req: req)
            return (wishlist, viewer)
        }

        let (wishlist, _, viewer, _) = try await resolveShareForGuest(req: req)

        try await ensureAgeAccess(
            wishlist: wishlist,
            user: nil,
            includeOwnerProfile: true,
            guestAdultConfirmedAt: viewer.adultConfirmedAt,
            req: req
        )

        return (wishlist, viewer)
    }

    private func ensureAgeAccess(
        wishlist: Wishlist,
        user: User?,
        includeOwnerProfile: Bool = false,
        guestAdultConfirmedAt: Date? = nil,
        req: Request
    ) async throws {
        let owner = try await wishlist.$owner.get(on: req.db)
        guard wishlist.matureContentEnabled || (includeOwnerProfile && owner.isAgeRestrictedProfile) else { return }
        if let user {
            guard user.derivedAgeBand == "adult" else {
                throw Abort(.forbidden, reason: "This content is not available to your account.")
            }
            return
        }
        guard isRecentAdultConfirmation(guestAdultConfirmedAt) else {
            throw Abort(.forbidden, reason: "This content is available only to adults 18 and older.")
        }
    }

    private func ensureDiscussionAccess(wishlist: Wishlist, viewer: WishlistViewer, req: Request) async throws {
        guard let userID = viewer.$user.id else { return }
        let wishlistID = try wishlist.requireID()
        if wishlist.$owner.id == userID {
            throw Abort(.forbidden, reason: "Wishlist owners cannot view the private gift-planning discussion.")
        }
        let isCollaborator = try await WishlistCollaborator.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == userID)
            .first() != nil
        if isCollaborator {
            throw Abort(.forbidden, reason: "Wishlist owners cannot view the private gift-planning discussion.")
        }
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

        guard let wishlist = try await Wishlist.query(on: req.db)
            .filter(\.$id == wishlistID)
            .filter(\.$owner.$id == userId)
            .first()
        else { throw Abort(.notFound) }

        if wishlist.matureContentEnabled || user.matureProfileEnabled {
            guard user.derivedAgeBand == "adult" else {
                throw Abort(.badRequest, reason: "Only adult accounts can create links for age-limited content.")
            }
        }

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
        try await revokeGuestLinkAccess(wishlistID: wishlistID, on: req.db)
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
        try await revokeGuestLinkAccess(wishlistID: wishlistID, on: req.db)

        return .init(shareToken: newToken)
    }

    private func revokeGuestLinkAccess(wishlistID: UUID, on db: any Database) async throws {
        let viewers = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$viewerTokenHash != nil)
            .all()
        for viewer in viewers {
            guard let viewerID = viewer.id else { continue }
            let hasSocialAccess = try await SocialWishlistAccess.query(on: db)
                .filter(\.$viewer.$id == viewerID).first() != nil
            let hasPublicAccess = try await PublicWishlistAccess.query(on: db)
                .filter(\.$viewer.$id == viewerID).first() != nil
            let isExplicit = hasSocialAccess || hasPublicAccess
            if !isExplicit { try await viewer.delete(on: db) }
        }
    }
}
