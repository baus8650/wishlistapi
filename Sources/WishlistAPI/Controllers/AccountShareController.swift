import Fluent
import Vapor

struct AccountShareController: RouteCollection {
    struct SavedShare: Content {
        let id: UUID
        let wishlistID: UUID
        let title: String
        let sharedByName: String
    }

    private let recipient = RecipientShareController()

    func boot(routes: any RoutesBuilder) throws {
        routes.get(use: list)
        routes.post("open", ":shareToken", use: open)
        routes.delete(":accountShareID", use: remove)
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

        return try viewers.map { viewer in
            try savedShare(viewer: viewer, wishlist: viewer.wishlist, owner: viewer.wishlist.owner)
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
            return try savedShare(viewer: existing, wishlist: wishlist, owner: owner)
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

        return try savedShare(viewer: linkedViewer, wishlist: wishlist, owner: owner)
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

        // Keep recipient state intact, but detach this list from the account.
        viewer.$user.id = nil
        try await viewer.save(on: req.db)
        return .noContent
    }

    private func savedShare(viewer: WishlistViewer, wishlist: Wishlist, owner: User) throws -> SavedShare {
        let configuredName = owner.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = owner.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Someone"
        return SavedShare(
            id: try viewer.requireID(),
            wishlistID: try wishlist.requireID(),
            title: wishlist.title,
            sharedByName: configuredName?.isEmpty == false ? configuredName! : fallbackName
        )
    }
}
