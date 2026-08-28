//
//  AuthController.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/23/26.
//

import Vapor
import Fluent
import JWTKit

struct RegisterRequest: Content {
    let email: String
    let password: String
    let displayName: String?
}

struct LoginRequest: Content {
    let email: String
    let password: String
}

struct ForgotPasswordRequest: Content {
    let email: String
}

struct ResetPasswordRequest: Content {
    let token: String
    let password: String
}

struct PasswordResetMessage: Content {
    let message: String
}

private struct ResendEmailRequest: Content {
    let from: String
    let to: [String]
    let subject: String
    let html: String
}

struct TokenResponse: Content {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
}

struct AuthController: RouteCollection {
    private static let accessTokenTTLSeconds: Int = 60 * 60 * 24 * 30 // 30 days

    func boot(routes: any RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("forgot-password", use: forgotPassword)
        auth.post("reset-password", use: resetPassword)
    }

    func register(req: Request) async throws -> TokenResponse {
        let body = try req.content.decode(RegisterRequest.self)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let displayName = body.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard email.contains("@"), body.password.count >= 8 else {
            throw Abort(.badRequest, reason: "Invalid email or password too short (min 8).")
        }

        let existing = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first()

        if existing != nil {
            throw Abort(.conflict, reason: "Email already registered.")
        }

        let hash = try Bcrypt.hash(body.password)
        let user = User(
            email: email,
            passwordHash: hash,
            displayName: displayName?.isEmpty == false ? displayName : nil
        )
        try await user.save(on: req.db)

        guard let userId = user.id else {
            throw Abort(.internalServerError, reason: "User missing id after registration.")
        }

        let exp = ExpirationClaim(value: Date().addingTimeInterval(TimeInterval(Self.accessTokenTTLSeconds)))
        let payload = AccessTokenPayload(sub: .init(value: userId.uuidString), exp: exp)
        let token = try await req.jwt.sign(payload)

        return TokenResponse(accessToken: token, tokenType: "Bearer", expiresIn: Self.accessTokenTTLSeconds)
    }

    func login(req: Request) async throws -> TokenResponse {
        let body = try req.content.decode(LoginRequest.self)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first()
        else {
            throw Abort(.unauthorized, reason: "Invalid credentials.")
        }

        guard try Bcrypt.verify(body.password, created: user.passwordHash) else {
            throw Abort(.unauthorized, reason: "Invalid credentials.")
        }

        guard let userId = user.id else {
            throw Abort(.internalServerError, reason: "User missing id.")
        }

        let exp = ExpirationClaim(value: Date().addingTimeInterval(TimeInterval(Self.accessTokenTTLSeconds)))
        let payload = AccessTokenPayload(sub: .init(value: userId.uuidString), exp: exp)
        let token = try await req.jwt.sign(payload)

        return TokenResponse(accessToken: token, tokenType: "Bearer", expiresIn: Self.accessTokenTTLSeconds)
    }

    func forgotPassword(req: Request) async throws -> PasswordResetMessage {
        let body = try req.content.decode(ForgotPasswordRequest.self)
        let email = body.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let genericMessage = "If an account exists for that email, a password reset link is on its way."

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == email)
            .first(),
              let userID = user.id
        else {
            return PasswordResetMessage(message: genericMessage)
        }

        let recentCount = try await PasswordResetToken.query(on: req.db)
            .filter(\.$user.$id == userID)
            .filter(\.$createdAt > Date().addingTimeInterval(-15 * 60))
            .count()
        guard recentCount < 3 else {
            return PasswordResetMessage(message: genericMessage)
        }

        var generator = SystemRandomNumberGenerator()
        let secret = (0..<32).map { _ in
            String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator))
        }.joined()
        let reset = PasswordResetToken(
            userID: userID,
            tokenHash: try Bcrypt.hash(secret),
            expiresAt: Date().addingTimeInterval(30 * 60)
        )
        try await reset.save(on: req.db)
        guard let resetID = reset.id else {
            throw Abort(.internalServerError, reason: "Unable to create password reset request.")
        }

        do {
            try await sendPasswordResetEmail(to: user.email, token: "\(resetID.uuidString).\(secret)", req: req)
        } catch {
            req.logger.error("Unable to send password reset email: \(error)")
            try? await reset.delete(on: req.db)
        }

        return PasswordResetMessage(message: genericMessage)
    }

    func resetPassword(req: Request) async throws -> PasswordResetMessage {
        let body = try req.content.decode(ResetPasswordRequest.self)
        guard body.password.count >= 8 else {
            throw Abort(.badRequest, reason: "Password must be at least 8 characters.")
        }

        let parts = body.token.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let tokenID = UUID(uuidString: parts[0]),
              let reset = try await PasswordResetToken.find(tokenID, on: req.db),
              reset.usedAt == nil,
              reset.expiresAt > Date(),
              try Bcrypt.verify(parts[1], created: reset.tokenHash)
        else {
            throw Abort(.badRequest, reason: "This reset link is invalid or has expired.")
        }

        let user = try await reset.$user.get(on: req.db)
        user.passwordHash = try Bcrypt.hash(body.password)
        try await user.save(on: req.db)
        reset.usedAt = Date()
        try await reset.save(on: req.db)

        return PasswordResetMessage(message: "Your password has been updated. You can now sign in.")
    }

    private func sendPasswordResetEmail(to email: String, token: String, req: Request) async throws {
        guard let apiKey = Environment.get("RESEND_API_KEY"), !apiKey.isEmpty,
              let from = Environment.get("PASSWORD_RESET_FROM_EMAIL"), !from.isEmpty,
              let webAppURL = Environment.get("WEB_APP_URL"), !webAppURL.isEmpty
        else {
            throw Abort(.internalServerError, reason: "Password reset email is not configured.")
        }

        let resetURL = "\(webAppURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/?resetToken=\(token)"
        let payload = ResendEmailRequest(
            from: from,
            to: [email],
            subject: "Reset your Hushful password",
            html: """
            <div style="font-family:Arial,sans-serif;color:#302b34;line-height:1.6;max-width:560px;margin:auto">
              <h1 style="color:#786a82">Reset your Hushful password</h1>
              <p>We received a request to reset your password.</p>
              <p><a href="\(resetURL)" style="display:inline-block;background:#786a82;color:white;text-decoration:none;padding:12px 20px;border-radius:999px">Choose a new password</a></p>
              <p>This link expires in 30 minutes and can only be used once.</p>
              <p>If you didn't request this, you can safely ignore this email.</p>
            </div>
            """
        )

        let response = try await req.client.post(URI(string: "https://api.resend.com/emails")) { request in
            request.headers.bearerAuthorization = BearerAuthorization(token: apiKey)
            request.headers.contentType = .json
            try request.content.encode(payload)
        }
        guard response.status.code >= 200, response.status.code < 300 else {
            throw Abort(.badGateway, reason: "Email provider rejected the reset email.")
        }
    }
}
