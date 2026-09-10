//
//  JWTPayloads.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/23/26.
//

import JWT

struct AccessTokenPayload: JWTPayload {
    let sub: SubjectClaim
    let exp: ExpirationClaim
    let ver: Int?
    let adminMFA: Bool?

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }
}
