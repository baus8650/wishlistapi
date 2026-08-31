import Fluent
import Vapor

struct ActivityDTO: Content {
    let id: UUID
    let kind: String
    let title: String
    let message: String
    let actorID: UUID?
    let wishlistID: UUID?
    let readAt: Date?
    let createdAt: Date?
}

enum ActivityService {
    static func create(userID: UUID, actorID: UUID? = nil, wishlistID: UUID? = nil, kind: String, title: String, message: String, on db: any Database, client: (any Client)? = nil, logger: Logger? = nil) async throws {
        guard userID != actorID else { return }
        try await ActivityNotification(userID: userID, actorID: actorID, wishlistID: wishlistID, kind: kind, title: title, message: message).save(on: db)
        if let client, let logger {
            await APNSService.send(userID: userID, kind: kind, title: title, message: message, wishlistID: wishlistID, on: db, client: client, logger: logger)
        }
    }

    static func notifyRecipients(wishlistID: UUID, actorID: UUID, kind: String, title: String, message: String, on db: any Database, client: (any Client)? = nil, logger: Logger? = nil) async throws {
        let socialAccess = try await SocialWishlistAccess.query(on: db).filter(\.$wishlist.$id == wishlistID).with(\.$viewer).all()
        let publicAccess = try await PublicWishlistAccess.query(on: db).filter(\.$wishlist.$id == wishlistID).with(\.$viewer).all()
        let socialRecipients = socialAccess.filter { $0.viewer.notificationsEnabled }.map(\.$user.id)
        let publicRecipients = publicAccess.filter { $0.viewer.notificationsEnabled }.compactMap { $0.viewer.$user.id }
        let recipients = Set(socialRecipients + publicRecipients)
        for userID in recipients { try await create(userID: userID, actorID: actorID, wishlistID: wishlistID, kind: kind, title: title, message: message, on: db, client: client, logger: logger) }
    }
}

struct ActivityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("activity", use: list)
        routes.post("activity", "read-all", use: readAll)
        routes.post("activity", ":notificationID", "read", use: read)
        routes.delete("activity", use: clearAll)
        routes.delete("activity", ":notificationID", use: delete)
    }

    func list(req: Request) async throws -> [ActivityDTO] {
        let userID = try req.auth.require(User.self).requireID()
        return try await ActivityNotification.query(on: req.db).filter(\.$user.$id == userID).sort(\.$createdAt, .descending).limit(100).all().map(dto)
    }

    func read(req: Request) async throws -> ActivityDTO {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("notificationID", as: UUID.self), let item = try await ActivityNotification.query(on: req.db).filter(\.$id == id).filter(\.$user.$id == userID).first() else { throw Abort(.notFound) }
        item.readAt = item.readAt ?? Date(); try await item.save(on: req.db); return try dto(item)
    }

    func readAll(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        for item in try await ActivityNotification.query(on: req.db).filter(\.$user.$id == userID).filter(\.$readAt == nil).all() { item.readAt = Date(); try await item.save(on: req.db) }
        return .noContent
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("notificationID", as: UUID.self),
              let item = try await ActivityNotification.query(on: req.db)
                .filter(\.$id == id).filter(\.$user.$id == userID).first()
        else { throw Abort(.notFound) }
        try await item.delete(on: req.db)
        return .noContent
    }

    func clearAll(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        try await ActivityNotification.query(on: req.db).filter(\.$user.$id == userID).delete()
        return .noContent
    }

    private func dto(_ item: ActivityNotification) throws -> ActivityDTO { .init(id: try item.requireID(), kind: item.kind, title: item.title, message: item.message, actorID: item.$actor.id, wishlistID: item.$wishlist.id, readAt: item.readAt, createdAt: item.createdAt) }
}
