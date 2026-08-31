import Fluent
import Vapor

struct AccountShareController: RouteCollection {
    struct SavedShare: Content {
        let id: UUID
        let wishlistID: UUID
        let title: String
        let sharedByName: String
        let notificationsEnabled: Bool
        let removable: Bool
        let recipientDueDate: Date?
        let recipientReminderEnabled: Bool
        let recipientReminderOffsets: [Int]
    }
    struct SettingsRequest: Content {
        let notificationsEnabled: Bool?
        let recipientDueDate: Date?
        let clearRecipientDueDate: Bool?
        let recipientReminderEnabled: Bool?
        let recipientReminderOffsets: [Int]?
    }

    private let recipient = RecipientShareController()

    func boot(routes: any RoutesBuilder) throws {
        routes.get(use: list)
        routes.post("open", ":shareToken", use: open)
        routes.delete(":accountShareID", use: remove)
        routes.get(":accountShareID", "settings", use: settings)
        routes.patch(":accountShareID", "settings", use: updateSettings)
        routes.get(":accountShareID", "items", use: recipient.listItemsWithState)
        routes.put(":accountShareID", "items", ":itemID", "state", use: recipient.upsertState)
    }

    func list(req: Request) async throws -> [SavedShare] {
        let userID = try req.auth.require(User.self).requireID()
        let viewers = try await WishlistViewer.query(on: req.db)
            .filter(\.$user.$id == userID)
            .with(\.$wishlist) { wishlist in
                wishlist.with(\.$owner)
            }
            .all()

        let socialViewerIDs = Set(try await SocialWishlistAccess.query(on: req.db).filter(\.$user.$id == userID).all().map(\.$viewer.id))
        return try viewers.map { viewer in
            try savedShare(viewer: viewer, wishlist: viewer.wishlist, owner: viewer.wishlist.owner, removable: !socialViewerIDs.contains(try viewer.requireID()))
        }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func open(req: Request) async throws -> SavedShare {
        let userID = try req.auth.require(User.self).requireID()
        guard let shareToken = req.parameters.get("shareToken") else {
            throw Abort(.badRequest, reason: "Missing share token.")
        }

        guard let link = try await WishlistShareLink.query(on: req.db)
            .filter(\.$tokenHash == Tokens.sha256Hex(shareToken))
            .first() else {
            throw Abort(.notFound)
        }

        let wishlist = try await link.$wishlist.get(on: req.db)
        let wishlistID = try wishlist.requireID()
        let owner = try await wishlist.$owner.get(on: req.db)

        if let existing = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == userID)
            .first() {
            let removable = try await SocialWishlistAccess.query(on: req.db).filter(\.$viewer.$id == existing.requireID()).first() == nil
            return try savedShare(viewer: existing, wishlist: wishlist, owner: owner, removable: removable)
        }

        var viewer: WishlistViewer?
        if let viewerToken = req.headers.first(name: "X-Viewer-Token"), !viewerToken.isEmpty {
            viewer = try await WishlistViewer.query(on: req.db)
                .filter(\.$wishlist.$id == wishlistID)
                .filter(\.$viewerTokenHash == Tokens.sha256Hex(viewerToken))
                .first()
        }

        let linkedViewer: WishlistViewer
        if let viewer, viewer.$user.id == nil {
            viewer.$user.id = userID
            try await viewer.save(on: req.db)
            linkedViewer = viewer
        } else {
            let generatedToken = try Tokens.randomURLSafeToken()
            let created = WishlistViewer(
                wishlistId: wishlistID,
                viewerTokenHash: Tokens.sha256Hex(generatedToken),
                userId: userID
            )
            try await created.save(on: req.db)
            linkedViewer = created
        }

        return try savedShare(viewer: linkedViewer, wishlist: wishlist, owner: owner, removable: true)
    }

    func remove(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let shareID = req.parameters.get("accountShareID", as: UUID.self),
              let viewer = try await WishlistViewer.query(on: req.db)
                .filter(\.$id == shareID)
                .filter(\.$user.$id == userID)
                .first() else {
            throw Abort(.notFound)
        }

        if try await SocialWishlistAccess.query(on: req.db).filter(\.$viewer.$id == shareID).first() != nil {
            throw Abort(.forbidden, reason: "This wishlist is shared with you by a friend. Ask the owner to change its audience.")
        }

        if let publicAccess = try await PublicWishlistAccess.query(on: req.db)
            .filter(\.$viewer.$id == shareID).first() {
            try await publicAccess.delete(on: req.db)
        }

        // Keep recipient state intact, but detach this list from the account.
        viewer.$user.id = nil
        try await viewer.save(on: req.db)
        return .noContent
    }

    func settings(req: Request) async throws -> SavedShare {
        let userID = try req.auth.require(User.self).requireID()
        guard let shareID = req.parameters.get("accountShareID", as: UUID.self),
              let viewer = try await WishlistViewer.query(on: req.db).filter(\.$id == shareID).filter(\.$user.$id == userID)
                .with(\.$wishlist) { $0.with(\.$owner) }.first() else { throw Abort(.notFound) }
        let removable = try await SocialWishlistAccess.query(on: req.db).filter(\.$viewer.$id == shareID).first() == nil
        return try savedShare(viewer: viewer, wishlist: viewer.wishlist, owner: viewer.wishlist.owner, removable: removable)
    }

    func updateSettings(req: Request) async throws -> SavedShare {
        let userID = try req.auth.require(User.self).requireID()
        guard let shareID = req.parameters.get("accountShareID", as: UUID.self),
              let viewer = try await WishlistViewer.query(on: req.db).filter(\.$id == shareID).filter(\.$user.$id == userID)
                .with(\.$wishlist) { $0.with(\.$owner) }.first() else { throw Abort(.notFound) }
        let body = try req.content.decode(SettingsRequest.self)
        if let value = body.notificationsEnabled { viewer.notificationsEnabled = value }
        if body.clearRecipientDueDate == true { viewer.recipientDueDate = nil }
        else if let value = body.recipientDueDate { viewer.recipientDueDate = value }
        if let value = body.recipientReminderEnabled { viewer.recipientReminderEnabled = value }
        if let offsets = body.recipientReminderOffsets {
            guard offsets.allSatisfy({ (0...365).contains($0) }) else { throw Abort(.badRequest, reason: "Reminder offsets must be between 0 and 365 days.") }
            viewer.recipientReminderOffsets = Array(Set(offsets)).sorted(by: >)
        }
        try await viewer.save(on: req.db)
        let removable = try await SocialWishlistAccess.query(on: req.db).filter(\.$viewer.$id == shareID).first() == nil
        return try savedShare(viewer: viewer, wishlist: viewer.wishlist, owner: viewer.wishlist.owner, removable: removable)
    }

    private func savedShare(viewer: WishlistViewer, wishlist: Wishlist, owner: User, removable: Bool) throws -> SavedShare {
        let configuredName = owner.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = owner.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Someone"
        return SavedShare(
            id: try viewer.requireID(),
            wishlistID: try wishlist.requireID(),
            title: wishlist.title,
            sharedByName: configuredName?.isEmpty == false ? configuredName! : fallbackName,
            notificationsEnabled: viewer.notificationsEnabled,
            removable: removable,
            recipientDueDate: viewer.recipientDueDate,
            recipientReminderEnabled: viewer.recipientReminderEnabled,
            recipientReminderOffsets: viewer.recipientReminderOffsets
        )
    }
}
