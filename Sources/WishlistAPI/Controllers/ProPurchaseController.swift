import AppStoreServerLibrary
import Fluent
import SQLKit
import Vapor

/// Only Apple-signed purchases bound to the authenticated Hushful account can grant Pro.
struct ProPurchaseController: RouteCollection {
    struct PurchaseRequest: Content { let signedTransaction: String }
    struct NotificationRequest: Content { let signedPayload: String }

    /// App Review and TestFlight use Apple’s sandbox, while App Store customers
    /// use production. Both are independently signed by Apple; Xcode and local
    /// StoreKit testing are deliberately not accepted by the public API.
    static let supportedEnvironments: [AppStoreEnvironment] = [.production, .sandbox]

    private struct VerificationContext {
        let environment: AppStoreEnvironment
        let verifier: SignedDataVerifier
    }

    private struct VerifiedTransaction {
        let payload: JWSTransactionDecodedPayload
        let environment: AppStoreEnvironment
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped(UserTokenAuthenticator()).grouped(User.guardMiddleware())
            .post("me", "pro", "apple", use: sync)
        routes.post("pro", "apple", "notifications", use: notification)
    }

    private static func verificationContexts() throws -> [VerificationContext] {
        let rawID = Environment.get("APPLE_APP_ID") ?? "6805499302"
        guard let appID = Int64(rawID), appID > 0,
              let roots = Environment.get("APPLE_ROOT_CERTIFICATE_PATHS"), !roots.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Purchase syncing is not configured yet. Your purchase remains available in the iOS app.")
        }
        let certificates: [Data]
        do { certificates = try roots.split(separator: ",").map { try Data(contentsOf: URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))) } }
        catch { throw Abort(.serviceUnavailable, reason: "Purchase verification is temporarily unavailable.") }
        return try supportedEnvironments.map { environment in
            VerificationContext(
                environment: environment,
                verifier: try SignedDataVerifier(
                    rootCertificates: certificates,
                    bundleId: "com.bausch.hushful",
                    appAppleId: environment == .production ? appID : nil,
                    environment: environment,
                    enableOnlineChecks: true
                )
            )
        }
    }

    private static func decode(_ signed: String, requireAppAccountToken: Bool = true) async throws -> VerifiedTransaction {
        guard signed.utf8.count <= 32_000 else { throw Abort(.payloadTooLarge) }
        for context in try verificationContexts() {
            guard case .valid(let transaction) = await context.verifier.verifyAndDecodeTransaction(signedTransaction: signed) else {
                continue
            }
            try Self.validatePurchase(transaction, requireAppAccountToken: requireAppAccountToken)
            return VerifiedTransaction(payload: transaction, environment: context.environment)
        }
        throw Abort(.badRequest, reason: "Apple could not verify this Hushful Pro purchase.")
    }

    private static func decode(
        _ signed: String,
        with context: VerificationContext,
        requireAppAccountToken: Bool = true
    ) async throws -> VerifiedTransaction {
        guard signed.utf8.count <= 32_000 else { throw Abort(.payloadTooLarge) }
        guard case .valid(let transaction) = await context.verifier.verifyAndDecodeTransaction(signedTransaction: signed) else {
            throw Abort(.badRequest, reason: "Apple could not verify this Hushful Pro purchase.")
        }
        try Self.validatePurchase(transaction, requireAppAccountToken: requireAppAccountToken)
        return VerifiedTransaction(payload: transaction, environment: context.environment)
    }

    private static func decodeNotification(_ signed: String) async throws -> (payload: ResponseBodyV2DecodedPayload, context: VerificationContext) {
        guard signed.utf8.count <= 64_000 else { throw Abort(.payloadTooLarge) }
        for context in try verificationContexts() {
            if case .valid(let notification) = await context.verifier.verifyAndDecodeNotification(signedPayload: signed) {
                return (notification, context)
            }
        }
        throw Abort(.badRequest, reason: "Invalid Apple notification.")
    }

    static func validatePurchase(
        _ transaction: JWSTransactionDecodedPayload,
        now: Date = Date(),
        requireAppAccountToken: Bool = true
    ) throws {
        guard transaction.productId == "com.bausch.hushful.pro.lifetime",
              transaction.type == .nonConsumable,
              let originalID = transaction.originalTransactionId, !originalID.isEmpty,
              let signedDate = transaction.signedDate,
              signedDate <= now.addingTimeInterval(300) else {
            throw Abort(.badRequest, reason: "Apple could not verify this Hushful Pro purchase.")
        }
        if requireAppAccountToken, transaction.appAccountToken == nil {
            throw Abort(.badRequest, reason: "Apple could not verify this Hushful Pro purchase.")
        }
    }

    /// Verifies a support-submitted transaction without granting or moving it.
    /// Legacy/unbound Apple purchases are intentionally accepted for evidence
    /// review, while the normal sync path still requires an account token.
    static func verifyForEvidence(_ signed: String, on request: Request) async throws -> JWSTransactionDecodedPayload {
        try await decode(signed, requireAppAccountToken: false).payload
    }

    func sync(req: Request) async throws -> User.Public {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(PurchaseRequest.self)
        let transaction = try await Self.decode(body.signedTransaction)
        guard transaction.payload.appAccountToken == userID else {
            throw Abort(.forbidden, reason: "This purchase belongs to a different Hushful account.")
        }
        return try await apply(transaction, userID: userID, on: req.db)
    }

    func notification(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(NotificationRequest.self)
        let notification = try await Self.decodeNotification(body.signedPayload)
        guard let signed = notification.payload.data?.signedTransactionInfo else { return .ok }
        // The nested transaction must validate in the same Apple environment
        // as its notification; this prevents cross-environment substitution.
        let transaction = try await Self.decode(signed, with: notification.context)
        guard let userID = transaction.payload.appAccountToken,
              try await User.find(userID, on: req.db) != nil else { return .ok }
        _ = try await apply(transaction, userID: userID, on: req.db)
        return .ok
    }

    private func apply(_ verifiedTransaction: VerifiedTransaction, userID: UUID, on database: any Database) async throws -> User.Public {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Serialize grants and refund notifications, including retries arriving out of order.
            try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE").run()
            guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound) }
            let transaction = verifiedTransaction.payload
            guard let originalID = transaction.originalTransactionId, let signedAt = transaction.signedDate else { throw Abort(.badRequest) }
            let existing = try await AppleProPurchase.query(on: db).filter(\.$originalTransactionID == originalID).first()
            if let existing {
                guard existing.$user.id == userID,
                      existing.storeEnvironment == verifiedTransaction.environment.rawValue else {
                    throw Abort(.forbidden)
                }
                if signedAt <= existing.signedAt { return user.toPublic() }
            }
            let purchase = existing ?? AppleProPurchase(
                userID: userID,
                originalTransactionID: originalID,
                signedAt: signedAt,
                active: false,
                storeEnvironment: verifiedTransaction.environment.rawValue
            )
            purchase.signedAt = signedAt
            purchase.active = transaction.revocationDate == nil && transaction.isUpgraded != true
            purchase.storeEnvironment = verifiedTransaction.environment.rawValue
            try await purchase.save(on: db)
            // A refund for an older purchase must not cancel a subsequent valid
            // purchase from either store.
            try await ProEntitlementService.refresh(user, on: db)
            return user.toPublic()
        }
    }
}
