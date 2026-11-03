import Fluent
import Vapor

enum CommentNotificationService {
    static func recipientIDs(wishlist: Wishlist, actorID: UUID?, on db: any Database) async throws -> Set<UUID> {
        let viewers = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlist.requireID()).all()
        let enabledIDs = Set(viewers.filter { $0.notificationsEnabled }.compactMap(\.$user.id))
        let owner = try await wishlist.$owner.get(on: db)
        var recipients = Set<UUID>()
        for userID in enabledIDs where userID != wishlist.$owner.id && userID != actorID {
            guard let user = try await User.find(userID, on: db),
                  try await !ProfileAccessService.isBlocked(wishlist.$owner.id, userID, on: db) else { continue }
            if wishlist.matureContentEnabled || owner.isAgeRestrictedProfile {
                guard user.derivedAgeBand == "adult" else { continue }
            }
            recipients.insert(userID)
        }
        return recipients
    }

    static func notify(wishlist: Wishlist, actorID: UUID?, itemID: UUID? = nil,
                       text: String, previousText: String? = nil, req: Request) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != previousText?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        do {
            for userID in try await recipientIDs(wishlist: wishlist, actorID: actorID, on: req.db) {
                try await ActivityService.create(userID: userID, actorID: actorID,
                    wishlistID: wishlist.requireID(), itemID: itemID,
                    kind: "wishlist_comment", title: itemID == nil ? "New wishlist comment" : "New item comment",
                    message: "Open Hushful to view the comment.",
                    on: req.db, client: req.client, logger: req.logger)
            }
        } catch {
            req.logger.warning("Comment was saved, but notifications could not be created: \(error)")
        }
    }
}

enum AccountRegistrationNotificationService {
    static func notify(user: User, req: Request) async {
        do {
            for admin in try await AdminAccessService.all(req.db) {
                try await ActivityService.create(userID: admin.requireID(), actorID: user.requireID(),
                    kind: "account_created", title: "New account",
                    message: "A new Hushful account was created.",
                    on: req.db, client: req.client, logger: req.logger)
            }
        } catch {
            req.logger.warning("Account was created, but admin notifications could not be created: \(error)")
        }
    }
}
