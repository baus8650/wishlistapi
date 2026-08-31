import Fluent
import Vapor

struct PushDeviceController: RouteCollection {
    private struct Registration: Content {
        let token: String
        let environment: String
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.put("push-devices", use: register)
        routes.delete("push-devices", ":token", use: unregister)
    }

    private func register(req: Request) async throws -> HTTPStatus {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(Registration.self)
        let token = body.token.lowercased()
        guard token.range(of: #"^[0-9a-f]{64,200}$"#, options: .regularExpression) != nil,
              ["sandbox", "production"].contains(body.environment) else {
            throw Abort(.badRequest, reason: "Invalid push registration.")
        }
        if let existing = try await PushDevice.query(on: req.db).filter(\.$token == token).first() {
            existing.$user.id = try user.requireID()
            existing.environment = body.environment
            try await existing.save(on: req.db)
        } else {
            try await PushDevice(userID: try user.requireID(), token: token, environment: body.environment).save(on: req.db)
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
