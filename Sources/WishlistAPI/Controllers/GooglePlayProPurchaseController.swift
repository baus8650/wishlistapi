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

    struct SyncResponse: Content {
        let user: User.Public
        let state: String
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped(UserTokenAuthenticator()).grouped(User.guardMiddleware())
            .post("me", "pro", "google", use: sync)
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
}
