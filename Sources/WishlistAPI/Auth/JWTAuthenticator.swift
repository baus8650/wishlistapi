//  JWTAuthenticator.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/23/26.
//

import Vapor
import JWT
import Fluent

struct UserTokenAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for req: Request) async throws {
        let payload = try await req.jwt.verify(bearer.token, as: AccessTokenPayload.self)

        guard let userId = UUID(uuidString: payload.sub.value) else { return }
        if let user = try await User.find(userId, on: req.db) {
            req.auth.login(user)
        }
    }
}
