import Fluent
import Vapor

struct UserReportController: RouteCollection {
    struct CreateRequest: Content {
        let reason: String
        let details: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.post("reports", "users", ":userID", use: create)
        routes.post("reports", "wishlists", ":wishlistID", use: createWishlistReport)
        routes.post("reports", "shared-wishlists", ":accountShareID", use: createSavedWishlistReport)
        routes.post("reports", "share-links", ":shareToken", use: createShareLinkReport)
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

        let report = UserReport(reporterID: reporterID, reportedID: reportedID, reason: reason, details: details)
        try await report.save(on: req.db)
        await notifyAdmins(report: report, reporter: reporter, req: req)
        return .noContent
    }

    func createWishlistReport(req: Request) async throws -> HTTPStatus {
        guard let wishlistID = req.parameters.get("wishlistID", as: UUID.self) else { throw Abort(.notFound) }
        return try await createWishlistReport(wishlistID: wishlistID, req: req)
    }

    func createSavedWishlistReport(req: Request) async throws -> HTTPStatus {
        let reporterID = try req.auth.require(User.self).requireID()
        guard let shareID = req.parameters.get("accountShareID", as: UUID.self),
              let viewer = try await WishlistViewer.query(on: req.db)
                .filter(\.$id == shareID).filter(\.$user.$id == reporterID).first() else { throw Abort(.notFound) }
        return try await createWishlistReport(wishlistID: viewer.$wishlist.id, req: req)
    }

    func createShareLinkReport(req: Request) async throws -> HTTPStatus {
        guard let token = req.parameters.get("shareToken"),
              let link = try await WishlistShareLink.query(on: req.db)
                .filter(\.$tokenHash == Tokens.sha256Hex(token)).first() else { throw Abort(.notFound) }
        return try await createWishlistReport(wishlistID: link.$wishlist.id, req: req)
    }

    private func createWishlistReport(wishlistID: UUID, req: Request) async throws -> HTTPStatus {
        let reporter = try req.auth.require(User.self)
        let reporterID = try reporter.requireID()
        guard let wishlist = try await Wishlist.query(on: req.db).filter(\.$id == wishlistID).with(\.$owner).first(),
              wishlist.$owner.id != reporterID else { throw Abort(.notFound) }
        let hasSavedAccess = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID).filter(\.$user.$id == reporterID).first() != nil
        let canOpen = wishlist.visibility == "public" || hasSavedAccess
        guard canOpen,
              try await ProfileAccessService.canViewWishlist(viewer: reporter, wishlist: wishlist, owner: wishlist.owner, on: req.db) else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(CreateRequest.self)
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let details = (body.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["spam", "harassment", "sexual_content", "violence", "illegal_content", "other"].contains(reason) else {
            throw Abort(.badRequest, reason: "Choose a valid report reason.")
        }
        guard details.count <= 2_000 else { throw Abort(.badRequest, reason: "Report details must be 2,000 characters or fewer.") }
        let recent = try await UserReport.query(on: req.db)
            .filter(\.$reporter.$id == reporterID)
            .filter(\.$targetType == "wishlist")
            .filter(\.$targetID == wishlistID)
            .filter(\.$createdAt > Date().addingTimeInterval(-7 * 24 * 60 * 60))
            .first()
        guard recent == nil else { throw Abort(.conflict, reason: "You already reported this wishlist recently.") }
        let report = UserReport(reporterID: reporterID, reportedID: wishlist.$owner.id, reason: reason, details: details, targetType: "wishlist", targetID: wishlistID)
        try await report.save(on: req.db)
        await notifyAdmins(report: report, reporter: reporter, req: req)
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
                .init(id: try $0.requireID(), reporterID: $0.$reporter.id, reporterEmail: $0.reporter.email, reportedID: $0.$reported.id, reportedEmail: $0.reported.email, reason: $0.reason, details: $0.details, targetType: $0.targetType, targetID: $0.targetID, createdAt: $0.createdAt)
            }
    }

    private func notifyAdmins(report: UserReport, reporter: User, req: Request) async {
        do {
            let adminEmails = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
            guard !adminEmails.isEmpty else { return }
            let admins = try await User.query(on: req.db).all().filter { adminEmails.contains($0.email.lowercased()) }
            for admin in admins {
                try await ActivityService.create(
                    userID: try admin.requireID(), actorID: try reporter.requireID(),
                    kind: "safety_report_submitted", title: "New safety report",
                    message: "A \(report.targetType ?? "account") was reported for \(report.reason.replacingOccurrences(of: "_", with: " ")).",
                    on: req.db, client: req.client, logger: req.logger
                )
            }
        } catch {
            req.logger.warning("Safety report was saved, but administrators could not be notified: \(error)")
        }
    }

    private func requireAdmin(_ req: Request) throws {
        let user = try req.auth.require(User.self)
        let admins = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard admins.contains(user.email.lowercased()) else { throw Abort(.forbidden) }
    }
}
