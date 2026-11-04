import Fluent
import Vapor

struct GiftRecipientsController: RouteCollection {
    struct Body: Content { let recipients: [GiftRecipient] }
    func boot(routes: any RoutesBuilder) throws {
        routes.get(":wishlistID", "gift-recipients", use: list)
        routes.put(":wishlistID", "gift-recipients", use: update)
    }
    private func authorize(_ req: Request) async throws -> Wishlist {
        let userID = try req.auth.require(User.self).requireID()
        let wishlist = try await WishlistPermissionService.editableWishlist(req: req)
        guard wishlist.$owner.id == userID else { throw Abort(.notFound) }
        return wishlist
    }
    func list(req: Request) async throws -> [GiftRecipient] {
        let wishlist = try await authorize(req)
        return try await WishlistGiftRecipients.query(on: req.db)
            .filter(\.$wishlist.$id == wishlist.requireID()).first()?.recipients ?? []
    }
    func update(req: Request) async throws -> [GiftRecipient] {
        let wishlist = try await authorize(req)
        guard try await WishlistPermissionService.giftsAreForOthers(wishlist: wishlist, on: req.db) else {
            throw Abort(.badRequest, reason: "Choose Gifts for others before adding gift recipients.")
        }
        let body = try req.content.decode(Body.self)
        let recipients = try await Self.validated(body.recipients, userID: req.auth.require(User.self).requireID(), on: req.db)
        let record = try await WishlistGiftRecipients.query(on: req.db)
            .filter(\.$wishlist.$id == wishlist.requireID()).first()
            ?? WishlistGiftRecipients(wishlistID: wishlist.requireID(), recipients: [])
        record.recipients = recipients
        try await record.save(on: req.db)
        return recipients
    }
    static func validated(_ entries: [GiftRecipient], userID: UUID, on db: any Database) async throws -> [GiftRecipient] {
        guard entries.count <= 50 else { throw Abort(.badRequest, reason: "Choose up to 50 people.") }
        var recipients: [GiftRecipient] = []
        for entry in entries {
            var name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if let id = entry.userID {
                let friendship = try await Friendship.query(on: db)
                    .group(.or) { group in
                        group.group(.and) { $0.filter(\.$requester.$id == userID).filter(\.$recipient.$id == id) }
                        group.group(.and) { $0.filter(\.$requester.$id == id).filter(\.$recipient.$id == userID) }
                    }
                    .filter(\.$status == "accepted").first()
                guard friendship != nil else {
                    throw Abort(.forbidden, reason: "Only friends can be selected as gift recipients. You can enter a name instead.")
                }
                guard let user = try await User.find(id, on: db),
                      try await !ProfileAccessService.isBlocked(userID, id, on: db) else { throw Abort(.notFound) }
                name = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
                    ?? user.username.map { "@\($0)" } ?? "Hushful user"
            }
            guard !name.isEmpty, name.count <= 100 else { throw Abort(.badRequest, reason: "Names must be between 1 and 100 characters.") }
            try ContentSafetyService.validate(name, field: "recipient name")
            if !recipients.contains(where: { entry.userID != nil ? $0.userID == entry.userID : $0.userID == nil && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                recipients.append(.init(userID: entry.userID, name: name))
            }
        }
        return recipients
    }

}
private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
