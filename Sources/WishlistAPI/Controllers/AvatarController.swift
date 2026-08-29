import Fluent
import Foundation
import Vapor

struct AvatarController: RouteCollection {
    static let allowedTypes: Set<String> = ["image/jpeg", "image/png", "image/webp"]

    func boot(routes: any RoutesBuilder) throws {
        routes.get("users", ":userID", "avatar", use: show)
    }

    func show(req: Request) async throws -> Response {
        guard let userID = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(userID, on: req.db),
              let data = user.avatarData,
              let contentType = user.avatarContentType else {
            throw Abort(.notFound)
        }
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: contentType)
        headers.replaceOrAdd(name: .cacheControl, value: "public, max-age=300")
        return Response(status: .ok, headers: headers, body: .init(data: data))
    }
}

struct AccountAvatarController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.on(.PUT, "me", "avatar", body: .collect(maxSize: "2mb"), use: upload)
        routes.delete("me", "avatar", use: remove)
    }

    func upload(req: Request) async throws -> User.Public {
        let user = try req.auth.require(User.self)
        guard let contentType = req.headers.contentType?.description.lowercased(),
              AvatarController.allowedTypes.contains(contentType) else {
            throw Abort(.unsupportedMediaType, reason: "Use a JPEG, PNG, or WebP image.")
        }
        guard let buffer = req.body.data, buffer.readableBytes > 0 else {
            throw Abort(.badRequest, reason: "Image data is required.")
        }
        user.avatarData = Data(buffer.readableBytesView)
        user.avatarContentType = contentType
        try await user.save(on: req.db)
        return user.toPublic()
    }

    func remove(req: Request) async throws -> User.Public {
        let user = try req.auth.require(User.self)
        user.avatarData = nil
        user.avatarContentType = nil
        try await user.save(on: req.db)
        return user.toPublic()
    }
}
