import Fluent
import Vapor

struct FeedbackController: RouteCollection {
    struct SubmitRequest: Content {
        let category: String
        let message: String
        let platform: String
        let shareName: Bool?
        let purchaseProof: PurchaseProof?
    }

    /// A short-lived verification input. It is used only during this request;
    /// the raw token/JWS is never copied into the feedback record or response.
    struct PurchaseProof: Content {
        let productID: String?
        let purchaseToken: String?
        let signedTransaction: String?
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
        let purchaseEvidence: String?
        let purchaseEvidenceDetails: String?
        let purchaseProvider: String?
        let purchaseOrderID: String?
        let purchaseAt: Date?
        let status: String
        let archived: Bool
        let createdAt: Date?
    }

    struct ReplyResponse: Content {
        let id: UUID
        let feedbackID: UUID
        let authorRole: String
        let authorDisplayName: String?
        let message: String
        let createdAt: Date?
    }

    struct ThreadResponse: Content {
        let feedback: Response
        let replies: [ReplyResponse]
    }

    struct ReplyRequest: Content {
        let message: String
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.post("feedback", use: submit)
        routes.get("admin", "feedback", use: list)
        routes.get("feedback", use: mine)
        routes.get("feedback", ":feedbackID", use: userThread)
        routes.post("feedback", ":feedbackID", "replies", use: userReply)
        routes.get("admin", "feedback", ":feedbackID", use: adminThread)
        routes.post("admin", "feedback", ":feedbackID", "replies", use: adminReply)
        routes.post("admin", "feedback", ":feedbackID", "close", use: close)
        routes.post("admin", "feedback", ":feedbackID", "reopen", use: reopen)
        routes.post("admin", "feedback", ":feedbackID", "archive", use: archive)
        routes.post("admin", "feedback", ":feedbackID", "unarchive", use: unarchive)
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

        guard ["general", "idea", "problem", "praise", "purchase"].contains(category) else {
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

        let purchaseEvidence = category == "purchase"
            ? await self.purchaseEvidence(for: body.purchaseProof, platform: platform, userID: try user.requireID(), on: req)
            : nil
        // Purchase claims are support cases, not anonymous feedback. Always
        // retain the authenticated account identity so an administrator can
        // compare the claim with the store evidence and contact the user.
        let shareName = category == "purchase" ? true : (body.shareName ?? false)

        let feedback = UserFeedback(
            userID: try user.requireID(),
            category: category,
            message: message,
            platform: platform,
            shareName: shareName,
            purchaseEvidence: purchaseEvidence?.status,
            purchaseEvidenceDetails: purchaseEvidence?.details,
            purchaseProvider: purchaseEvidence?.provider,
            purchaseOrderID: purchaseEvidence?.orderID,
            purchaseAt: purchaseEvidence?.purchasedAt
        )

        try await feedback.save(on: req.db)
        await notifyAdmins(of: feedback, submittedBy: user, req: req)

        return try response(feedback, user)
    }

    func list(req: Request) async throws -> [Response] {
        let admin = try AdminAccessService.require(req)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_feedback", targetType: "feedback")

        var query = UserFeedback.query(on: req.db)
            .with(\.$user)
        if req.query[Bool.self, at: "includeArchived"] != true {
            query = query.filter(\.$archived == false)
        }
        return try await query.sort(\.$createdAt, .descending).limit(500).all().map { try response($0, $0.user) }
    }

    func mine(req: Request) async throws -> [Response] {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        return try await UserFeedback.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
            .map { try response($0, user) }
    }

    func userThread(req: Request) async throws -> ThreadResponse {
        let user = try req.auth.require(User.self)
        let feedback = try await ownedFeedback(req: req, userID: try user.requireID())
        return try await threadResponse(feedback, user: user, on: req.db)
    }

    func adminThread(req: Request) async throws -> ThreadResponse {
        let admin = try AdminAccessService.require(req)
        guard let id = req.parameters.get("feedbackID", as: UUID.self),
              let feedback = try await UserFeedback.query(on: req.db).filter(\.$id == id).with(\.$user).first()
        else { throw Abort(.notFound) }
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_feedback_thread", targetType: "feedback", targetID: id)
        return try await threadResponse(feedback, user: feedback.user, on: req.db)
    }

    func userReply(req: Request) async throws -> ThreadResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        try await AuthRateLimitService.enforce(req, scope: "feedback-reply:\(userID)", limit: 30, window: 24 * 60 * 60)
        let feedback = try await ownedFeedback(req: req, userID: userID)
        let message = try validatedReplyMessage(req: req)
        let reply = UserFeedbackReply(feedbackID: try feedback.requireID(), authorID: userID, authorRole: "user", message: message)
        try await reply.save(on: req.db)
        feedback.status = "open"
        feedback.archived = false
        try await feedback.save(on: req.db)
        await notifyAdmins(of: feedback, summary: "A user replied to their \(feedback.category) feedback.", actorID: userID, kind: "feedback_reply", title: "Feedback reply received", req: req)
        return try await threadResponse(feedback, user: user, on: req.db)
    }

    func adminReply(req: Request) async throws -> ThreadResponse {
        let admin = try AdminAccessService.require(req)
        let adminID = try admin.requireID()
        guard let id = req.parameters.get("feedbackID", as: UUID.self),
              let feedback = try await UserFeedback.query(on: req.db).filter(\.$id == id).with(\.$user).first()
        else { throw Abort(.notFound) }
        let message = try validatedReplyMessage(req: req)
        let reply = UserFeedbackReply(feedbackID: id, authorID: adminID, authorRole: "admin", message: message)
        try await reply.save(on: req.db)
        feedback.status = "open"
        feedback.archived = false
        try await feedback.save(on: req.db)
        await notifyUser(of: feedback, actorID: adminID, title: "Reply to your feedback", message: "Hushful support replied to your feedback.", req: req)
        await AdminAuditService.record(req, adminID: adminID, action: "reply_feedback", targetType: "feedback", targetID: id)
        return try await threadResponse(feedback, user: feedback.user, on: req.db)
    }

    func close(req: Request) async throws -> Response {
        try await updateStatus(req: req, status: "closed", action: "close_feedback")
    }

    func reopen(req: Request) async throws -> Response {
        try await updateStatus(req: req, status: "open", action: "reopen_feedback")
    }

    func archive(req: Request) async throws -> Response {
        try await updateArchive(req: req, archived: true, action: "archive_feedback")
    }

    func unarchive(req: Request) async throws -> Response {
        try await updateArchive(req: req, archived: false, action: "unarchive_feedback")
    }

    private func ownedFeedback(req: Request, userID: UUID) async throws -> UserFeedback {
        guard let id = req.parameters.get("feedbackID", as: UUID.self),
              let feedback = try await UserFeedback.query(on: req.db)
                .filter(\.$id == id)
                .filter(\.$user.$id == userID)
                .with(\.$user)
                .first()
        else { throw Abort(.notFound) }
        return feedback
    }

    private func validatedReplyMessage(req: Request) throws -> String {
        let message = try req.content.decode(ReplyRequest.self).message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 4_000 else {
            throw Abort(.badRequest, reason: "Reply must be between 1 and 4,000 characters.")
        }
        return message
    }

    private func threadResponse(_ feedback: UserFeedback, user: User, on db: any Database) async throws -> ThreadResponse {
        let feedbackID = try feedback.requireID()
        let replies = try await UserFeedbackReply.query(on: db)
            .filter(\.$feedback.$id == feedbackID)
            .with(\.$author)
            .sort(\.$createdAt, .ascending)
            .all()
            .map(replyResponse)
        return ThreadResponse(feedback: try response(feedback, user), replies: replies)
    }

    private func replyResponse(_ reply: UserFeedbackReply) throws -> ReplyResponse {
        ReplyResponse(
            id: try reply.requireID(),
            feedbackID: reply.$feedback.id,
            authorRole: reply.authorRole,
            // Replies are shown as "You" on the user's device and as the
            // submitter account in the admin console; do not leak a display
            // name from an anonymous feedback submission.
            authorDisplayName: reply.authorRole == "admin" ? "Hushful Support" : nil,
            message: reply.message,
            createdAt: reply.createdAt
        )
    }

    private func updateStatus(req: Request, status: String, action: String) async throws -> Response {
        let admin = try AdminAccessService.require(req)
        let adminID = try admin.requireID()
        guard let id = req.parameters.get("feedbackID", as: UUID.self),
              let feedback = try await UserFeedback.query(on: req.db).filter(\.$id == id).with(\.$user).first()
        else { throw Abort(.notFound) }
        feedback.status = status
        try await feedback.save(on: req.db)
        await AdminAuditService.record(req, adminID: adminID, action: action, targetType: "feedback", targetID: id)
        if status == "closed" {
            await notifyUser(of: feedback, actorID: adminID, title: "Feedback closed", message: "Hushful marked your feedback as resolved. You can reply to reopen it.", req: req)
        }
        return try response(feedback, feedback.user)
    }

    private func updateArchive(req: Request, archived: Bool, action: String) async throws -> Response {
        let admin = try AdminAccessService.require(req)
        let adminID = try admin.requireID()
        guard let id = req.parameters.get("feedbackID", as: UUID.self),
              let feedback = try await UserFeedback.query(on: req.db).filter(\.$id == id).with(\.$user).first()
        else { throw Abort(.notFound) }
        feedback.archived = archived
        try await feedback.save(on: req.db)
        await AdminAuditService.record(req, adminID: adminID, action: action, targetType: "feedback", targetID: id)
        return try response(feedback, feedback.user)
    }

    private func notifyAdmins(
        of feedback: UserFeedback,
        submittedBy user: User,
        req: Request
    ) async {
        do {
            let userID = try user.requireID()
            let sharedName = user.displayName?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let submitter = feedback.shareName && sharedName?.isEmpty == false
                ? sharedName!
                : nil
            let summary = submitter.map {
                "\($0) submitted \(feedback.category) feedback on \(feedback.platform)."
            } ?? "New \(feedback.category) feedback was submitted on \(feedback.platform)."

            await notifyAdmins(of: feedback, summary: summary, actorID: userID, req: req)
        } catch {
            req.logger.warning("Feedback was saved, but administrators could not be notified: \(error)")
        }
    }

    private func notifyAdmins(of feedback: UserFeedback, summary: String, actorID: UUID, kind: String = "feedback_submitted", title: String = "New feedback received", req: Request) async {
        do {
            let admins = try await AdminAccessService.all(req.db)

            for admin in admins {
                try await ActivityService.create(
                    userID: try admin.requireID(),
                    actorID: actorID,
                    kind: kind,
                    title: title,
                    message: summary,
                    on: req.db,
                    client: req.client,
                    logger: req.logger
                )
            }
        } catch {
            req.logger.warning("Feedback update was saved, but administrators could not be notified: \(error)")
        }
    }

    private func notifyUser(of feedback: UserFeedback, actorID: UUID, title: String, message: String, req: Request) async {
        do {
            try await ActivityService.create(
                userID: feedback.$user.id,
                actorID: actorID,
                kind: "feedback_reply",
                title: title,
                message: message,
                on: req.db,
                client: req.client,
                logger: req.logger
            )
        } catch {
            req.logger.warning("Feedback update was saved, but the user could not be notified: \(error)")
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
            // Purchase claims are support cases, so administrators need to
            // identify the account that submitted the claim even when the
            // general-feedback name-sharing toggle is off.
            userEmail: feedback.shareName || feedback.category == "purchase" ? user.email : nil,
            userDisplayName: feedback.shareName || feedback.category == "purchase" ? user.displayName : nil,
            shareName: feedback.shareName,
            purchaseEvidence: feedback.purchaseEvidence,
            purchaseEvidenceDetails: feedback.purchaseEvidenceDetails,
            purchaseProvider: feedback.purchaseProvider,
            purchaseOrderID: feedback.purchaseOrderID,
            purchaseAt: feedback.purchaseAt,
            status: feedback.status,
            archived: feedback.archived,
            createdAt: feedback.createdAt
        )
    }

    private struct PurchaseEvidence {
        let status: String
        let details: String
        let provider: String?
        let orderID: String?
        let purchasedAt: Date?

        init(
            status: String,
            details: String,
            provider: String? = nil,
            orderID: String? = nil,
            purchasedAt: Date? = nil
        ) {
            self.status = status
            self.details = details
            self.provider = provider
            self.orderID = orderID
            self.purchasedAt = purchasedAt
        }
    }

    /// Returns a conservative, server-derived status. An invalid or missing
    /// proof is still accepted as feedback, but it can never justify an admin
    /// Pro grant on its own.
    private func purchaseEvidence(
        for proof: PurchaseProof?,
        platform: String,
        userID: UUID,
        on req: Request
    ) async -> PurchaseEvidence {
        var historicalApple: AppleProPurchase?
        var historicalGoogle: GooglePlayProPurchase?
        do {
            let applePurchases = try await AppleProPurchase.query(on: req.db)
                .filter(\.$user.$id == userID)
                .sort(\.$signedAt, .descending)
                .all()
            let googlePurchases = try await GooglePlayProPurchase.query(on: req.db)
                .filter(\.$user.$id == userID)
                .sort(\.$purchasedAt, .descending)
                .all()
            if let apple = applePurchases.first(where: { $0.active }) {
                return .init(
                    status: "verified_current_account",
                    details: "Verified active Apple purchase is linked to this Hushful account.",
                    provider: "apple",
                    purchasedAt: apple.signedAt
                )
            }
            if let google = googlePurchases.first(where: { $0.active }) {
                return .init(
                    status: "verified_current_account",
                    details: "Verified active Google Play purchase is linked to this Hushful account.",
                    provider: "google_play",
                    orderID: google.orderID,
                    purchasedAt: google.purchasedAt
                )
            }
            historicalApple = applePurchases.first
            historicalGoogle = googlePurchases.first
        } catch {
            req.logger.warning("Could not inspect existing Pro purchases for feedback: \(error)")
        }

        guard let proof else {
            if let apple = historicalApple {
                return .init(
                    status: "verified_current_account_inactive",
                    details: "A verified Apple purchase exists for this Hushful account, but it is not currently active.",
                    provider: "apple",
                    purchasedAt: apple.signedAt
                )
            }
            if let google = historicalGoogle {
                return .init(
                    status: "verified_current_account_inactive",
                    details: "A verified Google Play purchase exists for this Hushful account, but it is not currently active.",
                    provider: "google_play",
                    orderID: google.orderID,
                    purchasedAt: google.purchasedAt
                )
            }
            return .init(status: "unverified_claim", details: "No store verification proof was attached. Do not grant Pro from this claim alone.")
        }

        switch platform {
        case "ios":
            guard let signed = proof.signedTransaction,
                  signed.utf8.count > 0,
                  signed.utf8.count <= 32_000 else {
                return .init(status: "unverified_claim", details: "The Apple purchase proof was missing or too large.")
            }
            do {
                let transaction = try await ProPurchaseController.verifyForEvidence(signed, on: req)
                if transaction.appAccountToken == userID {
                    return .init(status: "verified_current_account", details: "Apple verified a Pro purchase linked to this Hushful account.", provider: "apple", purchasedAt: transaction.signedDate)
                }
                if transaction.appAccountToken != nil {
                    return .init(status: "verified_other_account", details: "Apple verified a Pro purchase linked to a different Hushful account.", provider: "apple", purchasedAt: transaction.signedDate)
                }
                return .init(status: "verified_unbound_purchase", details: "Apple verified a Pro purchase, but it has no Hushful account binding.", provider: "apple", purchasedAt: transaction.signedDate)
            } catch {
                req.logger.info("Apple purchase evidence could not be verified: \(error)")
                return .init(status: "unverified_claim", details: "Apple could not verify the submitted purchase proof.")
            }

        case "android":
            guard proof.productID == GooglePlayPurchaseService.productID,
                  let token = proof.purchaseToken,
                  token.count >= 20,
                  token.count <= 4_096 else {
                return .init(status: "unverified_claim", details: "The Google Play purchase proof was missing or invalid.")
            }
            do {
                let purchase = try await GooglePlayPurchaseService.verify(productID: proof.productID!, purchaseToken: token, on: req)
                guard purchase.productID == GooglePlayPurchaseService.productID,
                      purchase.purchaseState == 0 else {
                    return .init(status: "unverified_claim", details: "Google Play did not report an active Hushful Pro purchase.")
                }
                if let bound = purchase.obfuscatedExternalAccountID {
                    if GooglePlayPurchaseService.acceptedObfuscatedAccountIDs(for: userID).contains(bound) {
                        return .init(status: "verified_current_account", details: "Google Play verified a Pro purchase linked to this Hushful account.", provider: "google_play", orderID: purchase.orderID, purchasedAt: purchase.purchasedAt)
                    }
                    return .init(status: "verified_other_account", details: "Google Play verified a Pro purchase linked to a different Hushful account.", provider: "google_play", orderID: purchase.orderID, purchasedAt: purchase.purchasedAt)
                }
                return .init(status: "verified_unbound_purchase", details: "Google Play verified a Pro purchase, but it has no Hushful account binding.", provider: "google_play", orderID: purchase.orderID, purchasedAt: purchase.purchasedAt)
            } catch {
                req.logger.info("Google Play purchase evidence could not be verified: \(error)")
                return .init(status: "unverified_claim", details: "Google Play could not verify the submitted purchase proof.")
            }

        default:
            return .init(status: "unverified_claim", details: "Purchase verification is available from the iOS or Android app.")
        }
    }
}
