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

        let feedback = UserFeedback(
            userID: try user.requireID(),
            category: category,
            message: message,
            platform: platform,
            shareName: body.shareName ?? false,
            purchaseEvidence: purchaseEvidence?.status,
            purchaseEvidenceDetails: purchaseEvidence?.details
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
            // Purchase claims are support cases, so administrators need to
            // identify the account that submitted the claim even when the
            // general-feedback name-sharing toggle is off.
            userEmail: feedback.shareName || feedback.category == "purchase" ? user.email : nil,
            userDisplayName: feedback.shareName || feedback.category == "purchase" ? user.displayName : nil,
            shareName: feedback.shareName,
            purchaseEvidence: feedback.purchaseEvidence,
            purchaseEvidenceDetails: feedback.purchaseEvidenceDetails,
            createdAt: feedback.createdAt
        )
    }

    private struct PurchaseEvidence {
        let status: String
        let details: String
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
        do {
            if let apple = try await AppleProPurchase.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$active == true)
                .first() {
                _ = apple
                return .init(status: "verified_current_account", details: "Verified active Apple purchase is linked to this Hushful account.")
            }
            if let google = try await GooglePlayProPurchase.query(on: req.db)
                .filter(\.$user.$id == userID)
                .filter(\.$active == true)
                .first() {
                _ = google
                return .init(status: "verified_current_account", details: "Verified active Google Play purchase is linked to this Hushful account.")
            }
        } catch {
            req.logger.warning("Could not inspect existing Pro purchases for feedback: \(error)")
        }

        guard let proof else {
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
                    return .init(status: "verified_current_account", details: "Apple verified a Pro purchase linked to this Hushful account.")
                }
                if transaction.appAccountToken != nil {
                    return .init(status: "verified_other_account", details: "Apple verified a Pro purchase linked to a different Hushful account.")
                }
                return .init(status: "verified_unbound_purchase", details: "Apple verified a Pro purchase, but it has no Hushful account binding.")
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
                        return .init(status: "verified_current_account", details: "Google Play verified a Pro purchase linked to this Hushful account.")
                    }
                    return .init(status: "verified_other_account", details: "Google Play verified a Pro purchase linked to a different Hushful account.")
                }
                return .init(status: "verified_unbound_purchase", details: "Google Play verified a Pro purchase, but it has no Hushful account binding.")
            } catch {
                req.logger.info("Google Play purchase evidence could not be verified: \(error)")
                return .init(status: "unverified_claim", details: "Google Play could not verify the submitted purchase proof.")
            }

        default:
            return .init(status: "unverified_claim", details: "Purchase verification is available from the iOS or Android app.")
        }
    }
}
