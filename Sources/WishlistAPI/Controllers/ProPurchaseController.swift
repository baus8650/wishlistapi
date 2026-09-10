import AppStoreServerLibrary
import Fluent
import SQLKit
import Vapor

/// Only Apple-signed purchases bound to the authenticated Hushful account can grant Pro.
struct ProPurchaseController: RouteCollection {
    struct PurchaseRequest: Content { let signedTransaction: String }
    struct NotificationRequest: Content { let signedPayload: String }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped(UserTokenAuthenticator()).grouped(User.guardMiddleware())
            .post("me", "pro", "apple", use: sync)
        routes.post("pro", "apple", "notifications", use: notification)
    }

    private func verifier() throws -> SignedDataVerifier {
        let rawID = Environment.get("APPLE_APP_ID") ?? "6805499302"
        guard let appID = Int64(rawID), appID > 0,
              let roots = Environment.get("APPLE_ROOT_CERTIFICATE_PATHS"), !roots.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Purchase syncing is not configured yet. Your purchase remains available in the iOS app.")
        }
        // Sandbox is explicit and must only be enabled on a dedicated test server.
        let environment: AppStoreEnvironment = Environment.get("APPLE_STORE_ENVIRONMENT") == "sandbox" ? .sandbox : .production
        let certificates: [Data]
        do { certificates = try roots.split(separator: ",").map { try Data(contentsOf: URL(fileURLWithPath: $0.trimmingCharacters(in: .whitespaces))) } }
        catch { throw Abort(.serviceUnavailable, reason: "Purchase verification is temporarily unavailable.") }
        return try SignedDataVerifier(rootCertificates: certificates, bundleId: "com.bausch.hushful", appAppleId: appID, environment: environment, enableOnlineChecks: true)
    }

    private func decode(_ signed: String, using verifier: SignedDataVerifier) async throws -> JWSTransactionDecodedPayload {
        guard signed.utf8.count <= 32_000 else { throw Abort(.payloadTooLarge) }
        guard case .valid(let transaction) = await verifier.verifyAndDecodeTransaction(signedTransaction: signed) else {
            throw Abort(.badRequest, reason: "Apple could not verify this Hushful Pro purchase.")
        }
        try Self.validatePurchase(transaction)
        return transaction
    }

    static func validatePurchase(_ transaction: JWSTransactionDecodedPayload, now: Date = Date()) throws {
        guard transaction.productId == "com.bausch.hushful.pro.lifetime",
              transaction.type == .nonConsumable,
              transaction.appAccountToken != nil,
              let originalID = transaction.originalTransactionId, !originalID.isEmpty,
              let signedDate = transaction.signedDate,
              signedDate <= now.addingTimeInterval(300) else {
            throw Abort(.badRequest, reason: "Apple could not verify this Hushful Pro purchase.")
        }
    }

    func sync(req: Request) async throws -> User.Public {
        let userID = try req.auth.require(User.self).requireID()
        let body = try req.content.decode(PurchaseRequest.self)
        let transaction = try await decode(body.signedTransaction, using: verifier())
        guard transaction.appAccountToken == userID else {
            throw Abort(.forbidden, reason: "This purchase belongs to a different Hushful account.")
        }
        return try await apply(transaction, userID: userID, on: req.db)
    }

    func notification(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(NotificationRequest.self)
        guard body.signedPayload.utf8.count <= 64_000 else { throw Abort(.payloadTooLarge) }
        let verifier = try verifier()
        guard case .valid(let notification) = await verifier.verifyAndDecodeNotification(signedPayload: body.signedPayload) else {
            throw Abort(.badRequest, reason: "Invalid Apple notification.")
        }
        guard let signed = notification.data?.signedTransactionInfo else { return .ok }
        let transaction = try await decode(signed, using: verifier)
        guard let userID = transaction.appAccountToken,
              try await User.find(userID, on: req.db) != nil else { return .ok }
        _ = try await apply(transaction, userID: userID, on: req.db)
        return .ok
    }

    private func apply(_ transaction: JWSTransactionDecodedPayload, userID: UUID, on database: any Database) async throws -> User.Public {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Serialize grants and refund notifications, including retries arriving out of order.
            try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE").run()
            guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound) }
            guard let originalID = transaction.originalTransactionId, let signedAt = transaction.signedDate else { throw Abort(.badRequest) }
            let existing = try await AppleProPurchase.query(on: db).filter(\.$originalTransactionID == originalID).first()
            if let existing {
                guard existing.$user.id == userID else { throw Abort(.forbidden) }
                if signedAt <= existing.signedAt { return user.toPublic() }
            }
            let purchase = existing ?? AppleProPurchase(userID: userID, originalTransactionID: originalID, signedAt: signedAt, active: false)
            purchase.signedAt = signedAt
            purchase.active = transaction.revocationDate == nil && transaction.isUpgraded != true
            try await purchase.save(on: db)
            // A refund for an older purchase must not cancel a subsequent valid
            // purchase from either store.
            let appleEntitled = try await AppleProPurchase.query(on: db)
                .filter(\.$user.$id == userID).filter(\.$active == true).count() > 0
            let googleEntitled = try await GooglePlayProPurchase.query(on: db)
                .filter(\.$user.$id == userID).filter(\.$active == true).count() > 0
            user.hasLifetimePro = appleEntitled || googleEntitled
            try await user.save(on: db)
            return user.toPublic()
        }
    }
}
