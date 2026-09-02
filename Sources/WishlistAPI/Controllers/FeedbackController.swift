import Fluent
import Vapor

struct FeedbackController: RouteCollection {
    struct SubmitRequest: Content {
        let category: String
        let message: String
        let platform: String
    }

    struct Response: Content {
        let id: UUID
        let category: String
        let message: String
        let platform: String
        let userID: UUID
        let userEmail: String
        let userDisplayName: String?
        let createdAt: Date?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.post("feedback", use: submit)
        routes.get("admin", "feedback", use: list)
    }

    func submit(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(SubmitRequest.self)
        let category = body.category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let message = body.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = body.platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["general", "idea", "problem", "praise"].contains(category) else {
            throw Abort(.badRequest, reason: "Choose a valid feedback category.")
        }
        guard !message.isEmpty, message.count <= 4_000 else {
            throw Abort(.badRequest, reason: "Feedback must be between 1 and 4,000 characters.")
        }
        guard ["ios", "web"].contains(platform) else { throw Abort(.badRequest, reason: "Invalid platform.") }
        let feedback = UserFeedback(userID: try user.requireID(), category: category, message: message, platform: platform)
        try await feedback.save(on: req.db)
        return try response(feedback, user)
    }

    func list(req: Request) async throws -> [Response] {
        let admin = try req.auth.require(User.self)
        let allowed = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        guard allowed.contains(admin.email.lowercased()) else { throw Abort(.forbidden) }
        return try await UserFeedback.query(on: req.db)
            .with(\.$user)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
            .map { try response($0, $0.user) }
    }

    private func response(_ feedback: UserFeedback, _ user: User) throws -> Response {
        .init(id: try feedback.requireID(), category: feedback.category, message: feedback.message,
              platform: feedback.platform, userID: try user.requireID(), userEmail: user.email,
              userDisplayName: user.displayName, createdAt: feedback.createdAt)
    }
}
