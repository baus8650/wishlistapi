import Fluent
import Vapor

struct PushDeviceController: RouteCollection {
    private struct Registration: Content {
        let token: String
        let environment: String
        let platform: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.put("push-devices", use: register)
        routes.delete("push-devices", ":token", use: unregister)
    }

    private func register(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(Registration.self)
        let platform = body.platform ?? "ios"
        let token = platform == "android" ? body.token : body.token.lowercased()
        let validToken = platform == "android" ? token.count >= 32 : token.range(of: #"^[0-9a-f]{64,200}$"#, options: .regularExpression) != nil
        guard validToken, ["ios", "android"].contains(platform), ["sandbox", "production"].contains(body.environment) else {
            throw Abort(.badRequest, reason: "Invalid push registration.")
        }
        if let existing = try await PushDevice.query(on: req.db).filter(\.$token == token).first() {
            existing.$user.id = try user.requireID()
            existing.environment = body.environment
            existing.platform = platform
            try await existing.save(on: req.db)
        } else {
            try await PushDevice(userID: try user.requireID(), token: token, environment: body.environment, platform: platform).save(on: req.db)
        }
        return .noContent
    }

    private func unregister(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let token = req.parameters.get("token") else { throw Abort(.badRequest) }
        try await PushDevice.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$token == token.lowercased())
            .delete()
        return .noContent
    }
}
