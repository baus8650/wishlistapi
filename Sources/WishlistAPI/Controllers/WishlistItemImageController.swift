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
        return Response(
            status: .ok,
            headers: [
                "Content-Type": image.contentType,
                "Cache-Control": "public, max-age=3600"
            ],
            body: .init(data: image.data)
        )
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
