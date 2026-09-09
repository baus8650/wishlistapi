import Fluent
import Vapor

/// Purchase coordination for joint wishlists whose owners are gift planners.
/// "Our Wishlist" keeps purchase state hidden from every owner to avoid spoilers.
struct GiftPlanningController: RouteCollection {
    private let recipient = RecipientShareController()

    func boot(routes: any RoutesBuilder) throws {
        routes.get(":wishlistID", "planning-items", use: listItems)
        routes.put(":wishlistID", "planning-items", ":itemID", "state", use: updateItem)
    }

    func listItems(req: Request) async throws -> [RecipientShareController.ItemWithRecipientInfo] {
        let (wishlist, viewer) = try await resolvePlanningViewer(req: req)
        return try await recipient.listItemsWithState(req: req, wishlist: wishlist, viewer: viewer)
    }

    func updateItem(req: Request) async throws -> RecipientShareController.ItemWithRecipientInfo {
        let (wishlist, viewer) = try await resolvePlanningViewer(req: req)
        return try await recipient.upsertState(req: req, wishlist: wishlist, viewer: viewer)
    }

    private func resolvePlanningViewer(req: Request) async throws -> (Wishlist, WishlistViewer) {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let wishlist = try await Wishlist.find(wishlistID, on: req.db),
              wishlist.collaborationMode == "gift_planning",
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userID, on: req.db) else {
            throw Abort(.notFound)
        }

        if let viewer = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == userID)
            .first() {
            return (wishlist, viewer)
        }

        let suppliedName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = suppliedName?.isEmpty == false ? suppliedName : (user.username.map { "@\($0)" } ?? "Hushful user")
        let viewer = WishlistViewer(
            wishlistId: wishlistID,
            viewerTokenHash: Tokens.sha256Hex(try Tokens.randomURLSafeToken()),
            displayName: displayName,
            userId: userID
        )
        try await viewer.save(on: req.db)
        return (wishlist, viewer)
    }
}
