import Foundation
import Fluent
import SQLKit
import Vapor

/// Verifies Google Play purchases on the server before granting the shared
/// account-level Hushful Pro entitlement.
struct GooglePlayProPurchaseController: RouteCollection {
    struct PurchaseRequest: Content {
        let productID: String
        let purchaseToken: String
    }

    private struct PubSubRequest: Content {
        let message: PubSubMessage
    }

    private struct PubSubMessage: Content {
        let data: String
    }

    private struct DeveloperNotification: Decodable {
        let packageName: String
        let oneTimeProductNotification: OneTimeProductNotification?
    }

    private struct OneTimeProductNotification: Decodable {
        let notificationType: Int
        let purchaseToken: String
        let sku: String
    }

    struct SyncResponse: Content {
        let user: User.Public
        let state: String
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped(UserTokenAuthenticator()).grouped(User.guardMiddleware())
            .post("me", "pro", "google", use: sync)
        routes.on(.POST, "pro", "google", "notifications", body: .collect(maxSize: "128kb"), use: notification)
    }

    /// Handles Google Play Real-time Developer Notifications delivered through
    /// a Pub/Sub push subscription. Configure the push endpoint with the
    /// `GOOGLE_PLAY_RTDN_TOKEN` query parameter; refusing requests without it
    /// is intentional because Pub/Sub delivery itself is not a purchase proof.
    func notification(req: Request) async throws -> HTTPStatus {
        guard let expectedToken = Environment.get("GOOGLE_PLAY_RTDN_TOKEN"),
              !expectedToken.isEmpty,
              req.query[String.self, at: "token"] == expectedToken else {
            throw Abort(.unauthorized)
        }

        let envelope = try req.content.decode(PubSubRequest.self)
        guard let payload = Self.decodeBase64(envelope.message.data) else {
            throw Abort(.badRequest, reason: "Google Play notification data could not be decoded.")
        }
        let notification = try JSONDecoder().decode(DeveloperNotification.self, from: payload)
        guard notification.packageName == GooglePlayPurchaseService.packageName,
              let oneTime = notification.oneTimeProductNotification,
              oneTime.notificationType == 1 || oneTime.notificationType == 2,
              oneTime.sku == GooglePlayPurchaseService.productID,
              oneTime.purchaseToken.count >= 20,
              oneTime.purchaseToken.count <= 4_096 else {
            // A shared Pub/Sub topic can carry unrelated notifications. Ack
            // those messages after validating the envelope so they do not
            // retry forever.
            return .ok
        }

        let purchase = try await GooglePlayPurchaseService.verify(
            productID: oneTime.sku,
            purchaseToken: oneTime.purchaseToken,
            on: req
        )
        guard purchase.productID == GooglePlayPurchaseService.productID else { return .ok }
        let active = purchase.purchaseState == 0
        try await reconcile(
            purchase: purchase,
            purchaseToken: oneTime.purchaseToken,
            active: active,
            on: req.db
        )
        return .ok
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    func sync(req: Request) async throws -> SyncResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let body = try req.content.decode(PurchaseRequest.self)
        guard body.productID == GooglePlayPurchaseService.productID,
              body.purchaseToken.count >= 20,
              body.purchaseToken.count <= 4_096 else {
            throw Abort(.badRequest, reason: "That Hushful Pro purchase could not be recognized.")
        }

        let purchase = try await GooglePlayPurchaseService.verify(
            productID: body.productID,
            purchaseToken: body.purchaseToken,
            on: req
        )
        guard purchase.productID == body.productID,
              purchase.purchaseToken == nil || purchase.purchaseToken == body.purchaseToken,
              let obfuscatedAccountID = purchase.obfuscatedExternalAccountID,
              GooglePlayPurchaseService.acceptedObfuscatedAccountIDs(for: userID).contains(obfuscatedAccountID) else {
            throw Abort(.forbidden, reason: "This purchase belongs to a different Hushful account.")
        }

        switch purchase.purchaseState ?? -1 {
        case 2:
            return .init(user: user.toPublic(), state: "pending")
        case 0:
            guard let purchasedAt = purchase.purchasedAt,
                  purchasedAt <= Date().addingTimeInterval(300) else {
                throw Abort(.badRequest, reason: "Google Play returned an invalid purchase date.")
            }
            let updated = try await apply(
                purchase: purchase,
                purchaseToken: body.purchaseToken,
                userID: userID,
                on: req.db
            )
            if purchase.acknowledgementState != 1 {
                try await GooglePlayPurchaseService.acknowledge(
                    productID: body.productID,
                    purchaseToken: body.purchaseToken,
                    on: req
                )
            }
            return .init(user: updated, state: "active")
        default:
            throw Abort(.badRequest, reason: "This Google Play purchase is no longer active.")
        }
    }

    private func apply(
        purchase: GooglePlayPurchaseService.ProductPurchase,
        purchaseToken: String,
        userID: UUID,
        on database: any Database
    ) async throws -> User.Public {
        try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE").run()
            guard let user = try await User.find(userID, on: db) else { throw Abort(.notFound) }

            if let existing = try await GooglePlayProPurchase.query(on: db)
                .filter(\.$purchaseToken == purchaseToken)
                .first() {
                guard existing.$user.id == userID else { throw Abort(.forbidden) }
                existing.productID = GooglePlayPurchaseService.productID
                existing.orderID = purchase.orderID
                existing.purchasedAt = purchase.purchasedAt ?? Date()
                existing.active = true
                existing.acknowledged = purchase.acknowledgementState == 1
                try await existing.save(on: db)
            } else {
                let record = GooglePlayProPurchase(
                    userID: userID,
                    purchaseToken: purchaseToken,
                    productID: GooglePlayPurchaseService.productID,
                    orderID: purchase.orderID,
                    purchasedAt: purchase.purchasedAt ?? Date(),
                    active: true,
                    acknowledged: purchase.acknowledgementState == 1
                )
                try await record.save(on: db)
            }

            try await ProEntitlementService.refresh(user, on: db)
            return user.toPublic()
        }
    }

    private func reconcile(
        purchase: GooglePlayPurchaseService.ProductPurchase,
        purchaseToken: String,
        active: Bool,
        on database: any Database
    ) async throws {
        try await database.transaction { db in
            guard let existing = try await GooglePlayProPurchase.query(on: db)
                .filter(\.$purchaseToken == purchaseToken)
                .first(),
                  let user = try await User.find(existing.$user.id, on: db) else {
                return
            }
            let userID = existing.$user.id
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM users WHERE id = \(bind: userID) FOR UPDATE").run()
            existing.active = active
            existing.orderID = purchase.orderID ?? existing.orderID
            existing.acknowledged = purchase.acknowledgementState == 1
            try await existing.save(on: db)
            try await ProEntitlementService.refresh(user, on: db)
        }
    }
}
