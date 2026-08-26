//
//  Tokens.swift
//  WishlistAPI
//
//  Created by Tim Bausch on 2/24/26.
//

import Foundation
import Crypto
import Vapor

enum Tokens {
    static func sha256Hex(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func randomURLSafeToken(byteCount: Int = 32) throws -> String {
        guard byteCount > 0 else {
            throw Abort(.internalServerError, reason: "Token length must be positive.")
        }

        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<byteCount).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        }

        let data = Data(bytes)
        let b64 = data.base64EncodedString()
        // base64url (no + / =)
        return b64
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
