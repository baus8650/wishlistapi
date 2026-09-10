import Fluent
import Vapor

struct FeedbackController: RouteCollection {
    struct SubmitRequest: Content {
        let category: String
        let message: String
        let platform: String
        let shareName: Bool?
    }

    struct Response: Content {
        let id: UUID
        let category: String
        let message: String
        let platform: String
        let userID: UUID
        let userEmail: String?
        let userDisplayName: String?
        let shareName: Bool
        let createdAt: Date?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.post("feedback", use: submit)
        routes.get("admin", "feedback", use: list)
    }

    func submit(req: Request) async throws -> Response {
        let user = try req.auth.require(User.self)
        try await AuthRateLimitService.enforce(req, scope: "feedback:\(try user.requireID())", limit: 8, window: 24 * 60 * 60)
        try await AuthRateLimitService.enforce(req, scope: "feedback-ip:\(AuthRateLimitService.clientKey(req))", limit: 30, window: 24 * 60 * 60)
        let body = try req.content.decode(SubmitRequest.self)

        let category = body.category
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let message = body.message
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let platform = body.platform
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard ["general", "idea", "problem", "praise"].contains(category) else {
            throw Abort(.badRequest, reason: "Choose a valid feedback category.")
        }

        guard !message.isEmpty, message.count <= 4_000 else {
            throw Abort(
                .badRequest,
                reason: "Feedback must be between 1 and 4,000 characters."
            )
        }

        guard ["ios", "android", "web"].contains(platform) else {
            throw Abort(.badRequest, reason: "Invalid platform.")
        }

        let feedback = UserFeedback(
            userID: try user.requireID(),
            category: category,
            message: message,
            platform: platform,
            shareName: body.shareName ?? false
        )

        try await feedback.save(on: req.db)
        await notifyAdmins(of: feedback, submittedBy: user, req: req)

        return try response(feedback, user)
    }

    func list(req: Request) async throws -> [Response] {
        let admin = try AdminAccessService.require(req)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_feedback", targetType: "feedback")

        return try await UserFeedback.query(on: req.db)
            .with(\.$user)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
            .map {
                try response($0, $0.user)
            }
    }

    private func notifyAdmins(
        of feedback: UserFeedback,
        submittedBy user: User,
        req: Request
    ) async {
        do {
            let admins = try await AdminAccessService.all(req.db)
            let userID = try user.requireID()
            let sharedName = user.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let submitter = feedback.shareName && sharedName?.isEmpty == false
                ? sharedName!
                : nil
            let summary = submitter.map {
                "\($0) submitted \(feedback.category) feedback on \(feedback.platform)."
            } ?? "New \(feedback.category) feedback was submitted on \(feedback.platform)."

            for admin in admins {
                try await ActivityService.create(
                    userID: try admin.requireID(),
                    actorID: userID,
                    kind: "feedback_submitted",
                    title: "New feedback received",
                    message: summary,
                    on: req.db,
                    client: req.client,
                    logger: req.logger
                )
            }
        } catch {
            req.logger.warning("Feedback was saved, but administrators could not be notified: \(error)")
        }
    }

    private func response(
        _ feedback: UserFeedback,
        _ user: User
    ) throws -> Response {
        .init(
            id: try feedback.requireID(),
            category: feedback.category,
            message: feedback.message,
            platform: feedback.platform,
            userID: try user.requireID(),
            userEmail: feedback.shareName ? user.email : nil,
            userDisplayName: feedback.shareName ? user.displayName : nil,
            shareName: feedback.shareName,
            createdAt: feedback.createdAt
        )
    }
}
