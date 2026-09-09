import Fluent
import Vapor

struct WishlistItemImageController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("items", ":itemID", "image", use: show)
    }

    func show(req: Request) async throws -> Response {
        guard let itemID = req.parameters.get("itemID", as: UUID.self),
              let image = try await WishlistItemImage.query(on: req.db)
                .filter(\.$item.$id == itemID).first() else { throw Abort(.notFound) }
        guard try await canView(itemID: itemID, req: req) else { throw Abort(.notFound) }
        return Response(
            status: .ok,
            headers: [
                "Content-Type": image.contentType,
                "Cache-Control": "private, no-store"
            ],
            body: .init(data: image.data)
        )
    }

    private func canView(itemID: UUID, req: Request) async throws -> Bool {
        let memberships = try await WishlistItemMembership.query(on: req.db)
            .filter(\.$item.$id == itemID).with(\.$wishlist) { $0.with(\.$owner) }.all()
        guard !memberships.isEmpty else { return false }

        if let account = req.auth.get(User.self), let accountID = account.id {
            for membership in memberships {
                let wishlist = membership.wishlist
                guard try await ProfileAccessService.canViewWishlist(viewer: account, wishlist: wishlist, owner: wishlist.owner, on: req.db) else { continue }
                let isOwner = wishlist.$owner.id == accountID
                let isCollaborator = try await WishlistCollaborator.query(on: req.db)
                    .filter(\.$wishlist.$id == wishlist.id!)
                    .filter(\.$user.$id == accountID)
                    .first() != nil
                let hasSavedAccess = try await WishlistViewer.query(on: req.db)
                    .filter(\.$wishlist.$id == wishlist.id!)
                    .filter(\.$user.$id == accountID)
                    .first() != nil
                if isOwner || wishlist.visibility == "public" || isCollaborator || hasSavedAccess {
                    return true
                }
            }
        }

        guard let token = req.headers.first(name: "X-Viewer-Token"), !token.isEmpty else { return false }
        let hash = Tokens.sha256Hex(token)
        for membership in memberships {
            let wishlist = membership.wishlist
            guard let viewer = try await WishlistViewer.query(on: req.db)
                .filter(\.$wishlist.$id == wishlist.id!)
                .filter(\.$viewerTokenHash == hash).first() else { continue }
            if wishlist.matureContentEnabled || wishlist.owner.isAgeRestrictedProfile {
                guard let confirmed = viewer.adultConfirmedAt,
                      confirmed <= Date(),
                      confirmed >= Date().addingTimeInterval(-30 * 24 * 60 * 60) else { continue }
            }
            return true
        }
        return false
    }
}

struct AccountWishlistItemImageController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.on(.PUT, ":wishlistID", "items", ":itemID", "image", body: .collect(maxSize: "5mb"), use: upload)
        routes.delete(":wishlistID", "items", ":itemID", "image", use: remove)
    }

    func upload(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let (wishlistID, itemID) = try ids(req)
        try await authorize(wishlistID: wishlistID, itemID: itemID, userID: userID, req: req)
        let type = req.headers.contentType?.description.lowercased() ?? ""
        guard ["image/jpeg", "image/png", "image/webp"].contains(type) else {
            throw Abort(.unsupportedMediaType, reason: "Use a JPEG, PNG, or WebP image.")
        }
        guard var buffer = req.body.data,
              let data = buffer.readData(length: buffer.readableBytes), !data.isEmpty else {
            throw Abort(.badRequest, reason: "Image data is required.")
        }
        if let existing = try await WishlistItemImage.query(on: req.db).filter(\.$item.$id == itemID).first() {
            existing.data = data
            existing.contentType = type
            try await existing.save(on: req.db)
        } else {
            try await WishlistItemImage(itemID: itemID, data: data, contentType: type).save(on: req.db)
        }
        return .noContent
    }

    func remove(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let (wishlistID, itemID) = try ids(req)
        try await authorize(wishlistID: wishlistID, itemID: itemID, userID: userID, req: req)
        if let image = try await WishlistItemImage.query(on: req.db).filter(\.$item.$id == itemID).first() {
            try await image.delete(on: req.db)
        }
        return .noContent
    }

    private func ids(_ req: Request) throws -> (UUID, UUID) {
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let itemID = req.parameters.get("itemID", as: UUID.self) else { throw Abort(.badRequest) }
        return (wishlistID, itemID)
    }

    private func authorize(wishlistID: UUID, itemID: UUID, userID: UUID, req: Request) async throws {
        guard try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userID, on: req.db),
              try await WishlistItemMembership.query(on: req.db)
                .filter(\.$wishlist.$id == wishlistID).filter(\.$item.$id == itemID).first() != nil else {
            throw Abort(.notFound)
        }
    }
}
