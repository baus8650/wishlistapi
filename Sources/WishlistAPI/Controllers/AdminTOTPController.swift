import Fluent
import Vapor

private struct AdminTOTPCodeRequest: Content {
    let code: String
}

struct AdminTOTPStatusResponse: Content {
    let enabled: Bool
    let recoveryCodesRemaining: Int
}

struct AdminTOTPEnrollmentResponse: Content {
    let secret: String
    let provisioningURI: String
    let recoveryCodes: [String]
}

struct AdminTOTPController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let totp = routes.grouped("admin", "security", "totp")
        totp.get("status", use: status)
        totp.post("enroll", use: enroll)
        totp.post("confirm", use: confirm)
        totp.post("disable", use: disable)
    }

    func status(req: Request) async throws -> AdminTOTPStatusResponse {
        let user = try AdminAccessService.require(req)
        return status(for: user)
    }

    func enroll(req: Request) async throws -> AdminTOTPEnrollmentResponse {
        let user = try AdminAccessService.require(req)
        try await AuthRateLimitService.enforce(req, scope: "admin-totp-enroll:\(try user.requireID())", limit: 5, window: 24 * 60 * 60)
        let secret = TOTPService.generateSecret()
        let recoveryCodes = (0..<8).map { _ in TOTPService.generateRecoveryCode() }
        user.adminTOTPSecret = secret
        user.adminTOTPEnabled = false
        user.adminRecoveryCodes = try TOTPService.hashedRecoveryCodes(recoveryCodes)
        try await user.save(on: req.db)
        await AdminAuditService.record(req, adminID: try user.requireID(), action: "begin_admin_mfa_enrollment", targetType: "admin_security")
        return .init(secret: secret, provisioningURI: TOTPService.provisioningURI(secret: secret, account: user.email), recoveryCodes: recoveryCodes)
    }

    func confirm(req: Request) async throws -> AdminTOTPStatusResponse {
        let user = try AdminAccessService.require(req)
        try await AuthRateLimitService.enforce(req, scope: "admin-totp-confirm:\(try user.requireID())", limit: 10, window: 15 * 60)
        let body = try req.content.decode(AdminTOTPCodeRequest.self)
        guard let secret = user.adminTOTPSecret, TOTPService.isValid(code: body.code, secret: secret) else {
            throw Abort(.unprocessableEntity, reason: "That authenticator code is not valid. Check the time on your device and try again.")
        }
        user.adminTOTPEnabled = true
        try await user.save(on: req.db)
        await AdminAuditService.record(req, adminID: try user.requireID(), action: "enable_admin_mfa", targetType: "admin_security")
        return status(for: user)
    }

    func disable(req: Request) async throws -> AdminTOTPStatusResponse {
        let user = try AdminAccessService.require(req)
        user.adminTOTPSecret = nil
        user.adminTOTPEnabled = false
        user.adminRecoveryCodes = nil
        try await user.save(on: req.db)
        await AdminAuditService.record(req, adminID: try user.requireID(), action: "disable_admin_mfa", targetType: "admin_security")
        return status(for: user)
    }

    private func status(for user: User) -> AdminTOTPStatusResponse {
        let remaining: Int
        if let data = user.adminRecoveryCodes?.data(using: .utf8), let codes = try? JSONDecoder().decode([String].self, from: data) {
            remaining = codes.count
        } else {
            remaining = 0
        }
        return .init(enabled: user.adminTOTPEnabled, recoveryCodesRemaining: remaining)
    }
}
