import Fluent
import Vapor

struct ProfileWishlistDTO: Content {
    let wishlistID: UUID
    let title: String
    let accountShareID: UUID?
}

struct FriendProfileDTO: Content {
    let user: SocialUserDTO
    let publicWishlists: [ProfileWishlistDTO]
    let sharedWishlists: [ProfileWishlistDTO]
}

struct FriendProfileController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("users", ":userID", "profile", use: profile)
        routes.post("public-wishlists", ":wishlistID", "open", use: openPublicWishlist)
    }

    func profile(req: Request) async throws -> FriendProfileDTO {
        let me = try req.auth.require(User.self).requireID()
        guard let otherID = req.parameters.get("userID", as: UUID.self),
              otherID != me,
              let other = try await User.find(otherID, on: req.db),
              try await areFriends(me, otherID, on: req.db),
              let username = other.username else {
            throw Abort(.notFound)
        }

        let publicWishlists = try await Wishlist.query(on: req.db)
            .filter(\.$owner.$id == otherID)
            .filter(\.$visibility == "public")
            .sort(\.$createdAt, .descending)
            .all()
            .map { ProfileWishlistDTO(wishlistID: try $0.requireID(), title: $0.title, accountShareID: nil) }

        let sharedAccess = try await SocialWishlistAccess.query(on: req.db)
            .filter(\.$user.$id == me)
            .with(\.$wishlist)
            .all()
        let sharedWishlists = try sharedAccess
            .filter { $0.wishlist.$owner.id == otherID }
            .map { ProfileWishlistDTO(wishlistID: try $0.wishlist.requireID(), title: $0.wishlist.title, accountShareID: $0.$viewer.id) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        return FriendProfileDTO(
            user: SocialUserDTO(id: otherID, username: username, displayName: other.displayName, hasAvatar: other.avatarData != nil),
            publicWishlists: publicWishlists,
            sharedWishlists: sharedWishlists
        )
    }

    func openPublicWishlist(req: Request) async throws -> AccountShareController.SavedShare {
        let me = try req.auth.require(User.self).requireID()
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let wishlist = try await Wishlist.query(on: req.db)
                .filter(\.$id == wishlistID)
                .filter(\.$visibility == "public")
                .with(\.$owner)
                .first() else { throw Abort(.notFound) }

        if let existing = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == me).first() {
            return try savedShare(existing, wishlist)
        }

        let viewer = WishlistViewer(wishlistId: wishlistID, userId: me)
        try await viewer.save(on: req.db)
        try await PublicWishlistAccess(wishlistID: wishlistID, userID: me, viewerID: viewer.requireID()).save(on: req.db)
        return try savedShare(viewer, wishlist)
    }

    private func areFriends(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        let rows = try await Friendship.query(on: db)
            .group(.or) { group in
                group.group(.and) { $0.filter(\.$requester.$id == first).filter(\.$recipient.$id == second) }
                group.group(.and) { $0.filter(\.$requester.$id == second).filter(\.$recipient.$id == first) }
            }
            .filter(\.$status == "accepted")
            .first()
        return rows != nil
    }

    private func savedShare(_ viewer: WishlistViewer, _ wishlist: Wishlist) throws -> AccountShareController.SavedShare {
        let owner = wishlist.owner
        let configuredName = owner.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = owner.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Someone"
        return .init(id: try viewer.requireID(), wishlistID: try wishlist.requireID(), title: wishlist.title,
                     sharedByName: configuredName?.isEmpty == false ? configuredName! : fallbackName)
    }
}
