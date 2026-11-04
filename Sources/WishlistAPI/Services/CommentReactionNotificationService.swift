import Fluent
import Vapor

/// Create activity in the reaction transaction; push is sent only after commit.
enum CommentReactionNotificationService {
    static func shouldNotify(authorID: UUID?, actorID: UUID?, sameViewer: Bool, enabled: Bool) -> Bool {
        guard let authorID, enabled, !sameViewer else { return false }
        return authorID != actorID
    }

    static func record(wishlist: Wishlist, authorViewerID: UUID, actor: WishlistViewer,
                       emoji: String, itemID: UUID?, on db: any Database) async throws -> ActivityNotification? {
        guard let author = try await WishlistViewer.find(authorViewerID, on: db),
              shouldNotify(authorID: author.$user.id, actorID: actor.$user.id,
                           sameViewer: authorViewerID == actor.id, enabled: author.notificationsEnabled),
              let authorID = author.$user.id,
              let user = try await User.find(authorID, on: db) else { return nil }
        let owner = try await wishlist.$owner.get(on: db)
        guard try await ProfileAccessService.canViewWishlist(viewer: user, wishlist: wishlist, owner: owner, on: db) else { return nil }
        if wishlist.matureContentEnabled || owner.isAgeRestrictedProfile {
            guard user.derivedAgeBand == "adult" else { return nil }
        }
        if let actorID = actor.$user.id,
           try await ProfileAccessService.isBlocked(authorID, actorID, on: db) { return nil }
        if try await !WishlistPermissionService.giftsAreForOthers(wishlist: wishlist, on: db) {
            // Never reveal private gift-planning activity to a recipient/owner.
            if authorID == wishlist.$owner.id { return nil }
            if try await WishlistCollaborator.query(on: db)
                .filter(\.$wishlist.$id == wishlist.requireID()).filter(\.$user.$id == authorID).first() != nil { return nil }
        }
        // Reaction counts don't reveal identities. Keep that behavior in activity
        // and lock-screen previews too; don't include the comment or item title.
        let notification = ActivityNotification(userID: authorID, wishlistID: try wishlist.requireID(), itemID: itemID,
            kind: "comment_reaction", title: "New reaction to your comment",
            message: "Someone reacted \(emoji) to your \(itemID == nil ? "comment" : "item comment").")
        try await notification.save(on: db)
        return notification
    }
}
