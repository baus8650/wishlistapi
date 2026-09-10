import Fluent
import Vapor

struct UserReportController: RouteCollection {
    struct CreateRequest: Content {
        let reason: String
        let details: String?
    }

    struct AuditResponse: Content {
        let id: UUID
        let adminEmail: String?
        let action: String
        let targetType: String?
        let targetID: UUID?
        let metadata: String?
        let createdAt: Date?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.post("reports", "users", ":userID", use: create)
        routes.post("reports", "wishlists", ":wishlistID", use: createWishlistReport)
        routes.post("reports", "shared-wishlists", ":accountShareID", use: createSavedWishlistReport)
        routes.post("reports", "share-links", ":shareToken", use: createShareLinkReport)
        routes.post("reports", "discussion-comments", ":commentID", use: createDiscussionCommentReport)
        routes.post("reports", "item-notes", ":stateID", use: createItemNoteReport)
        routes.post("public-reports", "share-links", ":shareToken", use: createGuestShareLinkReport)
        routes.get("admin", "reports", use: list)
        routes.get("admin", "audit", use: audit)
        routes.post("admin", "reports", ":reportID", "remove-content", use: removeContent)
        routes.post("admin", "reports", ":reportID", "dismiss", use: dismiss)
        routes.post("admin", "reports", ":reportID", "suspend-reported-user", use: suspendReportedUser)
    }

    func create(req: Request) async throws -> HTTPStatus {
        let reporter = try req.auth.require(User.self)
        let reporterID = try reporter.requireID()
        try await AuthRateLimitService.enforce(req, scope: "report:\(reporterID)", limit: 12, window: 24 * 60 * 60)
        try await AuthRateLimitService.enforce(req, scope: "report-ip:\(AuthRateLimitService.clientKey(req))", limit: 30, window: 24 * 60 * 60)
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
        try await AuthRateLimitService.enforce(req, scope: "report:\(reporterID)", limit: 12, window: 24 * 60 * 60)
        try await AuthRateLimitService.enforce(req, scope: "report-ip:\(AuthRateLimitService.clientKey(req))", limit: 30, window: 24 * 60 * 60)
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

    func createDiscussionCommentReport(req: Request) async throws -> HTTPStatus {
        guard let commentID = req.parameters.get("commentID", as: UUID.self),
              let comment = try await WishlistDiscussionComment.query(on: req.db).filter(\.$id == commentID).first() else { throw Abort(.notFound) }
        return try await createContentReport(targetType: "discussion_comment", targetID: commentID, wishlistID: comment.$wishlist.id, req: req)
    }

    func createGuestShareLinkReport(req: Request) async throws -> HTTPStatus {
        guard let token = req.parameters.get("shareToken"),
              let link = try await WishlistShareLink.query(on: req.db).filter(\.$tokenHash == Tokens.sha256Hex(token)).first(),
              link.expiresAt == nil || link.expiresAt! > Date() else { throw Abort(.notFound) }
        let wishlist = try await link.$wishlist.get(on: req.db)
        let owner = try await wishlist.$owner.get(on: req.db)
        if wishlist.visibility != "public" {
            guard let viewerToken = req.headers.first(name: "X-Viewer-Token"),
                  try await WishlistViewer.query(on: req.db).filter(\.$wishlist.$id == wishlist.requireID()).filter(\.$viewerTokenHash == Tokens.sha256Hex(viewerToken)).first() != nil else { throw Abort(.notFound) }
        }
        try await AuthRateLimitService.enforce(req, scope: "guest-report:\(link.id?.uuidString ?? token)", limit: 12, window: 24 * 60 * 60)
        try await AuthRateLimitService.enforce(req, scope: "guest-report-ip:\(AuthRateLimitService.clientKey(req))", limit: 20, window: 24 * 60 * 60)
        let body = try req.content.decode(CreateRequest.self)
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let details = (body.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["spam", "harassment", "sexual_content", "violence", "illegal_content", "other"].contains(reason), details.count <= 2_000 else { throw Abort(.badRequest, reason: "Choose a valid report reason and provide at most 2,000 characters.") }
        let report = UserReport(reportedID: try owner.requireID(), reason: reason, details: details, targetType: "wishlist", targetID: try wishlist.requireID())
        try await report.save(on: req.db)
        await notifyAdmins(report: report, reporter: nil, req: req)
        return .noContent
    }

    func createItemNoteReport(req: Request) async throws -> HTTPStatus {
        guard let stateID = req.parameters.get("stateID", as: UUID.self),
              let state = try await ItemViewerState.query(on: req.db).filter(\.$id == stateID).first(),
              state.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              let membership = try await WishlistItemMembership.query(on: req.db).filter(\.$item.$id == state.$item.id).first() else { throw Abort(.notFound) }
        return try await createContentReport(targetType: "item_note", targetID: stateID, wishlistID: membership.$wishlist.id, req: req)
    }

    private func createContentReport(targetType: String, targetID: UUID, wishlistID: UUID, req: Request) async throws -> HTTPStatus {
        let reporter = try req.auth.require(User.self)
        let reporterID = try reporter.requireID()
        try await AuthRateLimitService.enforce(req, scope: "report:\(reporterID)", limit: 12, window: 24 * 60 * 60)
        try await AuthRateLimitService.enforce(req, scope: "report-ip:\(AuthRateLimitService.clientKey(req))", limit: 30, window: 24 * 60 * 60)
        guard let wishlist = try await Wishlist.query(on: req.db).filter(\.$id == wishlistID).with(\.$owner).first(),
              wishlist.$owner.id != reporterID,
              try await ProfileAccessService.canViewWishlist(viewer: reporter, wishlist: wishlist, owner: wishlist.owner, on: req.db) else { throw Abort(.notFound) }
        let savedViewer = try await WishlistViewer.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == reporterID)
            .first()
        let hasAccess = wishlist.visibility == "public" || savedViewer != nil
        guard hasAccess else { throw Abort(.notFound) }
        let body = try req.content.decode(CreateRequest.self)
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let details = (body.details ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["spam", "harassment", "sexual_content", "violence", "illegal_content", "other"].contains(reason), details.count <= 2_000 else { throw Abort(.badRequest, reason: "Choose a valid report reason and provide at most 2,000 characters.") }
        guard try await UserReport.query(on: req.db).filter(\.$reporter.$id == reporterID).filter(\.$targetType == targetType).filter(\.$targetID == targetID).filter(\.$createdAt > Date().addingTimeInterval(-7 * 24 * 60 * 60)).first() == nil else { throw Abort(.conflict, reason: "You already reported this content recently.") }
        let report = UserReport(reporterID: reporterID, reportedID: wishlist.$owner.id, reason: reason, details: details, targetType: targetType, targetID: targetID)
        try await report.save(on: req.db)
        await notifyAdmins(report: report, reporter: reporter, req: req)
        return .noContent
    }

    func list(req: Request) async throws -> [UserReportDTO] {
        let admin = try AdminAccessService.require(req)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_reports", targetType: "reports")
        return try await UserReport.query(on: req.db)
            .with(\.$reporter)
            .with(\.$reported)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
            .map {
                .init(id: try $0.requireID(), reporterID: $0.$reporter.id, reporterEmail: $0.reporter?.email, reportedID: $0.$reported.id, reportedEmail: $0.reported.email, reason: $0.reason, details: $0.details, targetType: $0.targetType, targetID: $0.targetID, status: $0.status, resolvedAt: $0.resolvedAt, createdAt: $0.createdAt)
            }
    }

    func audit(req: Request) async throws -> [AuditResponse] {
        _ = try AdminAccessService.require(req)
        return try await AdminAuditEvent.query(on: req.db)
            .with(\.$admin)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
            .map {
                .init(id: try $0.requireID(), adminEmail: $0.admin?.email, action: $0.action, targetType: $0.targetType, targetID: $0.targetID, metadata: $0.metadata, createdAt: $0.createdAt)
            }
    }

    func removeContent(req: Request) async throws -> HTTPStatus {
        let admin = try AdminAccessService.require(req)
        let report = try await requiredReport(req)
        switch report.targetType {
        case "wishlist": if let id = report.targetID, let wishlist = try await Wishlist.find(id, on: req.db) { try await wishlist.delete(on: req.db) }
        case "discussion_comment": if let id = report.targetID, let comment = try await WishlistDiscussionComment.find(id, on: req.db) { try await comment.delete(on: req.db) }
        case "item_note": if let id = report.targetID, let state = try await ItemViewerState.find(id, on: req.db) { state.note = nil; try await state.save(on: req.db) }
        default: break
        }
        report.status = "content_removed"; report.resolvedAt = Date(); report.$moderator.id = try admin.requireID(); try await report.save(on: req.db)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "remove_reported_content", targetType: report.targetType, targetID: report.targetID)
        return .noContent
    }

    func dismiss(req: Request) async throws -> HTTPStatus {
        let admin = try AdminAccessService.require(req); let report = try await requiredReport(req)
        report.status = "dismissed"; report.resolvedAt = Date(); report.$moderator.id = try admin.requireID(); try await report.save(on: req.db)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "dismiss_report", targetType: report.targetType, targetID: report.targetID)
        return .noContent
    }

    func suspendReportedUser(req: Request) async throws -> HTTPStatus {
        let admin = try AdminAccessService.require(req); let report = try await requiredReport(req)
        guard let user = try await User.find(report.$reported.id, on: req.db) else { throw Abort(.notFound) }
        user.suspendedAt = Date(); user.authenticationVersion += 1; try await user.save(on: req.db)
        report.status = "account_suspended"; report.resolvedAt = Date(); report.$moderator.id = try admin.requireID(); try await report.save(on: req.db)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "suspend_reported_user", targetType: "user", targetID: report.$reported.id)
        return .noContent
    }

    private func requiredReport(_ req: Request) async throws -> UserReport {
        guard let id = req.parameters.get("reportID", as: UUID.self), let report = try await UserReport.find(id, on: req.db) else { throw Abort(.notFound) }; return report
    }

    private func notifyAdmins(report: UserReport, reporter: User?, req: Request) async {
        do {
            let admins = try await AdminAccessService.all(req.db)
            for admin in admins {
                try await ActivityService.create(
                    userID: try admin.requireID(), actorID: try reporter?.requireID(),
                    kind: "safety_report_submitted", title: "New safety report",
                    message: "A \(report.targetType ?? "account") was reported for \(report.reason.replacingOccurrences(of: "_", with: " ")).",
                    on: req.db, client: req.client, logger: req.logger
                )
            }
        } catch {
            req.logger.warning("Safety report was saved, but administrators could not be notified: \(error)")
        }
    }

}
