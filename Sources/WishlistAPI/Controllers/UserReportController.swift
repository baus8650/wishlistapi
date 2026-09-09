import Fluent
import Vapor

struct UserReportController: RouteCollection {
    struct CreateRequest: Content {
        let reason: String
        let details: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.post("reports", "users", ":userID", use: create)
        routes.get("admin", "reports", use: list)
    }

    func create(req: Request) async throws -> HTTPStatus {
        let reporter = try req.auth.require(User.self)
        let reporterID = try reporter.requireID()
        guard let reportedID = req.parameters.get("userID", as: UUID.self), reportedID != reporterID,
              try await User.find(reportedID, on: req.db) != nil else { throw Abort(.notFound) }
        let body = try req.content.decode(CreateRequest.self)
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let details = (body.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["spam", "harassment", "impersonation", "other"].contains(reason) else { throw Abort(.badRequest, reason: "Choose a valid report reason.") }
        guard details.count <= 2_000 else { throw Abort(.badRequest, reason: "Report details must be 2,000 characters or fewer.") }

        let recent = try await UserReport.query(on: req.db)
            .filter(\.$reporter.$id == reporterID)
            .filter(\.$reported.$id == reportedID)
            .filter(\.$createdAt > Date().addingTimeInterval(-7 * 24 * 60 * 60))
            .first()
        guard recent == nil else { throw Abort(.conflict, reason: "You already reported this account recently.") }

        try await UserReport(reporterID: reporterID, reportedID: reportedID, reason: reason, details: details).save(on: req.db)
        return .noContent
    }

    func list(req: Request) async throws -> [UserReportDTO] {
        try requireAdmin(req)
        return try await UserReport.query(on: req.db)
            .with(\.$reporter)
            .with(\.$reported)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
            .map {
                .init(id: try $0.requireID(), reporterID: $0.$reporter.id, reporterEmail: $0.reporter.email, reportedID: $0.$reported.id, reportedEmail: $0.reported.email, reason: $0.reason, details: $0.details, createdAt: $0.createdAt)
            }
    }

    private func requireAdmin(_ req: Request) throws {
        let user = try req.auth.require(User.self)
        let admins = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard admins.contains(user.email.lowercased()) else { throw Abort(.forbidden) }
    }
}
