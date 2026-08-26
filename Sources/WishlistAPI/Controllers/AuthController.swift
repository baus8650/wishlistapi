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
}
