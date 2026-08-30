import Fluent
import Vapor

struct PinsDTO: Content {
    let wishlistIDs: [UUID]
    let userIDs: [UUID]
    let groupIDs: [UUID]
}

struct PinController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("pins", use: list)
        routes.put("pins", ":targetType", ":targetID", use: pin)
        routes.delete("pins", ":targetType", ":targetID", use: unpin)
    }

    func list(req: Request) async throws -> PinsDTO {
        let me = try req.auth.require(User.self).requireID()
        let pins = try await UserPin.query(on: req.db).filter(\.$user.$id == me).sort(\.$position).sort(\.$createdAt).all()
        var valid: [UserPin] = []
        for pin in pins {
            if try await canPin(type: pin.targetType, id: pin.targetID, userID: me, on: req.db) { valid.append(pin) }
            else { try await pin.delete(on: req.db) }
        }
        return .init(wishlistIDs: valid.filter { $0.targetType == "wishlist" }.map(\.targetID), userIDs: valid.filter { $0.targetType == "user" }.map(\.targetID), groupIDs: valid.filter { $0.targetType == "group" }.map(\.targetID))
    }

    func pin(req: Request) async throws -> PinsDTO {
        let me = try req.auth.require(User.self).requireID()
        guard let type = req.parameters.get("targetType"), ["wishlist", "user", "group"].contains(type),
              let id = req.parameters.get("targetID", as: UUID.self),
              try await canPin(type: type, id: id, userID: me, on: req.db) else { throw Abort(.notFound) }
        if try await UserPin.query(on: req.db).filter(\.$user.$id == me).filter(\.$targetType == type).filter(\.$targetID == id).first() == nil {
            let count = try await UserPin.query(on: req.db).filter(\.$user.$id == me).count()
            try await UserPin(userID: me, targetType: type, targetID: id, position: count).save(on: req.db)
        }
        return try await list(req: req)
    }

    func unpin(req: Request) async throws -> PinsDTO {
        let me = try req.auth.require(User.self).requireID()
        guard let type = req.parameters.get("targetType"), let id = req.parameters.get("targetID", as: UUID.self) else { throw Abort(.badRequest) }
        if let pin = try await UserPin.query(on: req.db).filter(\.$user.$id == me).filter(\.$targetType == type).filter(\.$targetID == id).first() { try await pin.delete(on: req.db) }
        return try await list(req: req)
    }

    private func canPin(type: String, id: UUID, userID: UUID, on db: any Database) async throws -> Bool {
        switch type {
        case "wishlist":
            guard let wishlist = try await Wishlist.find(id, on: db) else { return false }
            if wishlist.$owner.id == userID || wishlist.visibility == "public" { return true }
            if try await SocialWishlistAccess.query(on: db).filter(\.$wishlist.$id == id).filter(\.$user.$id == userID).first() != nil { return true }
            return try await WishlistViewer.query(on: db).filter(\.$wishlist.$id == id).filter(\.$user.$id == userID).first() != nil
        case "user":
            return try await Friendship.query(on: db).filter(\.$status == "accepted").group(.or) { group in
                group.group(.and) { $0.filter(\.$requester.$id == userID).filter(\.$recipient.$id == id) }
                group.group(.and) { $0.filter(\.$requester.$id == id).filter(\.$recipient.$id == userID) }
            }.first() != nil
        case "group":
            return try await FriendGroup.query(on: db).filter(\.$id == id).filter(\.$owner.$id == userID).first() != nil
        default: return false
        }
    }
}
