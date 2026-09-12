import Fluent
import Vapor

struct AdminProController: RouteCollection {
    struct GrantRequest: Content {
        let userID: UUID
        let reason: String
    }

    struct GrantResponse: Content {
        let id: UUID
        let userID: UUID
        let userEmail: String
        let userDisplayName: String?
        let reason: String
        let active: Bool
        let grantedAt: Date?
        let revokedAt: Date?
        let grantedByEmail: String?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get("admin", "pro", "grants", use: list)
        routes.post("admin", "pro", "grants", use: grant)
        routes.post("admin", "pro", "grants", ":grantID", "revoke", use: revoke)
    }

    func list(req: Request) async throws -> [GrantResponse] {
        let admin = try AdminAccessService.require(req)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_pro_grants", targetType: "pro_grants")

        let grants = try await AdminProGrant.query(on: req.db)
            .with(\.$user)
            .with(\.$grantedBy)
            .sort(\.$createdAt, .descending)
            .limit(500)
            .all()
        return grants.map(response)
    }

    func grant(req: Request) async throws -> GrantResponse {
        let admin = try AdminAccessService.require(req)
        let body = try req.content.decode(GrantRequest.self)
        let reason = body.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reason.count >= 5, reason.count <= 500 else {
            throw Abort(.badRequest, reason: "Enter a reason between 5 and 500 characters.")
        }
        let adminID = try admin.requireID()

        let result: GrantResponse = try await req.db.transaction { db in
            guard let user = try await User.find(body.userID, on: db) else {
                throw Abort(.notFound, reason: "That Hushful account could not be found.")
            }
            guard user.emailVerifiedAt != nil else {
                throw Abort(.forbidden, reason: "Pro access cannot be granted until this account verifies its email address.")
            }

            if let existing = try await AdminProGrant.query(on: db)
                .filter(\.$user.$id == body.userID)
                .filter(\.$active == true)
                .with(\.$user)
                .with(\.$grantedBy)
                .first() {
                return response(existing)
            }

            let grant = AdminProGrant(userID: body.userID, grantedByID: adminID, reason: reason)
            try await grant.save(on: db)
            try await ProEntitlementService.refresh(user, on: db)
            return GrantResponse(
                id: try grant.requireID(), userID: body.userID, userEmail: user.email,
                userDisplayName: user.displayName, reason: reason, active: true,
                grantedAt: grant.createdAt, revokedAt: nil, grantedByEmail: admin.email
            )
        }

        await AdminAuditService.record(
            req, adminID: adminID,
            action: "grant_pro_access",
            targetType: "user",
            targetID: body.userID,
            metadata: "reason=\(reason.replacingOccurrences(of: "\n", with: " "))"
        )
        return result
    }

    func revoke(req: Request) async throws -> GrantResponse {
        let admin = try AdminAccessService.require(req)
        guard let grantID = req.parameters.get("grantID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid Pro grant ID.")
        }
        let adminID = try admin.requireID()

        let result: GrantResponse = try await req.db.transaction { db in
            guard let grant = try await AdminProGrant.find(grantID, on: db) else {
                throw Abort(.notFound, reason: "That Pro grant could not be found.")
            }
            let user = try await grant.$user.get(on: db)
            let grantedBy = try await grant.$grantedBy.get(on: db)
            guard grant.active else {
                return GrantResponse(
                    id: try grant.requireID(), userID: try user.requireID(), userEmail: user.email,
                    userDisplayName: user.displayName, reason: grant.reason, active: false,
                    grantedAt: grant.createdAt, revokedAt: grant.revokedAt, grantedByEmail: grantedBy?.email
                )
            }
            grant.active = false
            grant.revokedAt = Date()
            grant.$revokedBy.id = adminID
            try await grant.save(on: db)
            try await ProEntitlementService.refresh(user, on: db)
            return GrantResponse(
                id: try grant.requireID(), userID: try user.requireID(), userEmail: user.email,
                userDisplayName: user.displayName, reason: grant.reason, active: false,
                grantedAt: grant.createdAt, revokedAt: grant.revokedAt, grantedByEmail: grantedBy?.email
            )
        }

        await AdminAuditService.record(
            req, adminID: adminID,
            action: "revoke_pro_access",
            targetType: "user",
            targetID: result.userID
        )
        return result
    }

    private func response(_ grant: AdminProGrant) -> GrantResponse {
        .init(
            id: (try? grant.requireID()) ?? UUID(),
            userID: grant.$user.id,
            userEmail: grant.user.email,
            userDisplayName: grant.user.displayName,
            reason: grant.reason,
            active: grant.active,
            grantedAt: grant.createdAt,
            revokedAt: grant.revokedAt,
            grantedByEmail: grant.grantedBy?.email
        )
    }
}
