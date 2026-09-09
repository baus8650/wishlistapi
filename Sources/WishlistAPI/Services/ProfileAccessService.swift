import Foundation
import Fluent

enum ProfileAccessService {
    static func areFriends(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        try await Friendship.query(on: db)
            .group(.or) { group in
                group.group(.and) { $0.filter(\.$requester.$id == first).filter(\.$recipient.$id == second) }
                group.group(.and) { $0.filter(\.$requester.$id == second).filter(\.$recipient.$id == first) }
            }
            .filter(\.$status == "accepted")
            .first() != nil
    }

    static func isBlocked(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        try await UserBlock.query(on: db)
            .group(.or) { group in
                group.group(.and) { $0.filter(\.$blocker.$id == first).filter(\.$blocked.$id == second) }
                group.group(.and) { $0.filter(\.$blocker.$id == second).filter(\.$blocked.$id == first) }
            }
            .first() != nil
    }

    static func canViewProfile(viewerID: UUID, target: User, on db: any Database) async throws -> Bool {
        guard let targetID = target.id, viewerID != targetID else { return true }
        if target.isAgeRestrictedProfile {
            guard let viewer = try await User.find(viewerID, on: db), viewer.derivedAgeBand == "adult" else {
                return false
            }
        }
        guard try await !isBlocked(viewerID, targetID, on: db) else { return false }
        if target.isDiscoverable { return true }
        return try await areFriends(viewerID, targetID, on: db)
    }

    static func canViewWishlist(viewer: User, wishlist: Wishlist, owner: User, on db: any Database) async throws -> Bool {
        guard let viewerID = viewer.id, let ownerID = owner.id else { return false }
        if viewerID == ownerID { return true }
        guard try await !isBlocked(viewerID, ownerID, on: db) else { return false }
        if wishlist.matureContentEnabled || owner.isAgeRestrictedProfile {
            return viewer.derivedAgeBand == "adult"
        }
        return true
    }

    /// Removes saved account access that has become invalid after an age,
    /// profile, list, audience, or block change. Audience grants may remain,
    /// but synchronization will not recreate access while it is ineligible.
    static func revokeIneligibleWishlistAccess(wishlistID: UUID, on db: any Database) async throws {
        guard let wishlist = try await Wishlist.query(on: db)
            .filter(\.$id == wishlistID).with(\.$owner).first() else { return }
        let viewers = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID).with(\.$user).all()
        for viewer in viewers {
            guard let account = viewer.user,
                  !(try await canViewWishlist(viewer: account, wishlist: wishlist, owner: wishlist.owner, on: db)) else { continue }
            if let viewerID = viewer.id {
                try await SocialWishlistAccess.query(on: db).filter(\.$viewer.$id == viewerID).delete()
                try await PublicWishlistAccess.query(on: db).filter(\.$viewer.$id == viewerID).delete()
            }
            try await viewer.delete(on: db)
        }
    }

    static func canViewBirthday(viewerID: UUID, target: User, on db: any Database) async throws -> Bool {
        guard let targetID = target.id else { return false }
        guard target.birthdayMonth != nil, target.birthdayDay != nil else { return false }
        let profileVisible: Bool
        if viewerID == targetID {
            profileVisible = true
        } else {
            profileVisible = try await canViewProfile(viewerID: viewerID, target: target, on: db)
        }
        guard profileVisible else { return false }
        switch target.birthdayVisibility {
        case "public": return true
        case "friends":
            if viewerID == targetID { return true }
            return try await areFriends(viewerID, targetID, on: db)
        default: return viewerID == targetID
        }
    }

    static func canViewAttribute(_ attribute: UserProfileAttribute, viewerID: UUID, target: User, on db: any Database) async throws -> Bool {
        guard let targetID = target.id else { return false }
        if viewerID == targetID { return true }
        guard try await canViewProfile(viewerID: viewerID, target: target, on: db) else { return false }
        switch attribute.visibility {
        case "public": return true
        case "friends": return try await areFriends(viewerID, targetID, on: db)
        default: return false
        }
    }
}
