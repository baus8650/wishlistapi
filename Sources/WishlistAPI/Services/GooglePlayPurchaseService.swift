import Foundation
import JWT
import Vapor

enum GooglePlayPurchaseService {
    static let packageName = "com.hushful.app"
    static let productID = "hushful_pro_lifetime"

    private static let pathSegmentAllowed: CharacterSet = {
        var characters = CharacterSet.urlPathAllowed
        characters.remove(charactersIn: "/")
        return characters
    }()

    private struct ServiceAccount: Decodable {
        let clientEmail: String
        let privateKey: String

        enum CodingKeys: String, CodingKey {
            case clientEmail = "client_email"
            case privateKey = "private_key"
        }
    }

    private struct Assertion: JWTPayload {
        let iss: IssuerClaim
        let scope: String
        let aud: AudienceClaim
        let exp: ExpirationClaim
        let iat: IssuedAtClaim

        func verify(using algorithm: some JWTAlgorithm) async throws {
            try exp.verifyNotExpired()
        }
    }

    private struct OAuthResponse: Content {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "access_token" }
    }

    private struct EmptyBody: Content {}

    struct ProductPurchase: Content, Sendable {
        let purchaseTimeMillis: String?
        let purchaseState: Int?
        let orderID: String?
        let productID: String?
        let acknowledgementState: Int?
        let obfuscatedExternalAccountID: String?
        let purchaseToken: String?

        enum CodingKeys: String, CodingKey {
            case purchaseTimeMillis
            case purchaseState
            case orderID = "orderId"
            case productID = "productId"
            case acknowledgementState
            case obfuscatedExternalAccountID = "obfuscatedExternalAccountId"
            case purchaseToken
        }

        var purchasedAt: Date? {
            guard let purchaseTimeMillis, let milliseconds = Int64(purchaseTimeMillis) else { return nil }
            return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
        }
    }

    static func verify(productID: String, purchaseToken: String, on request: Request) async throws -> ProductPurchase {
        let accessToken = try await accessToken(on: request)
        let encodedProduct = productID.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? productID
        let encodedToken = purchaseToken.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? purchaseToken
        let uri = URI(string: "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/\(packageName)/purchases/products/\(encodedProduct)/tokens/\(encodedToken)")
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: accessToken)
        let response = try await request.client.get(uri, headers: headers).get()
        guard response.status == .ok else {
            request.logger.warning("Google Play purchase verification returned HTTP \(response.status.code).")
            throw Abort(.badRequest, reason: "Google Play could not verify this purchase.")
        }
        return try response.content.decode(ProductPurchase.self)
    }

    static func acknowledge(productID: String, purchaseToken: String, on request: Request) async throws {
        let accessToken = try await accessToken(on: request)
        let encodedProduct = productID.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? productID
        let encodedToken = purchaseToken.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) ?? purchaseToken
        let uri = URI(string: "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/\(packageName)/purchases/products/\(encodedProduct)/tokens/\(encodedToken):acknowledge")
        var headers = HTTPHeaders()
        headers.bearerAuthorization = .init(token: accessToken)
        headers.contentType = .json
        let response = try await request.client.post(uri, headers: headers, content: EmptyBody()).get()
        guard response.status == .ok || response.status == .noContent else {
            request.logger.warning("Google Play purchase acknowledgement returned HTTP \(response.status.code).")
            throw Abort(.serviceUnavailable, reason: "Google Play could not finish processing this purchase yet.")
        }
    }

    static func obfuscatedAccountID(for userID: UUID) -> String {
        // Billing clients should hash the UUID's canonical lowercase form.
        // Keep the single-value helper stable for new purchases.
        Tokens.sha256Hex(userID.uuidString.lowercased())
    }

    static func acceptedObfuscatedAccountIDs(for userID: UUID) -> Set<String> {
        // Older Android builds hashed the UUID exactly as it arrived in JSON,
        // while the server previously hashed UUID.uuidString. UUID casing is
        // not identity-significant, but it does change a SHA-256 result. Accept
        // both representations during migration while still requiring that the
        // purchase is bound to this exact Hushful user.
        [
            Tokens.sha256Hex(userID.uuidString.lowercased()),
            Tokens.sha256Hex(userID.uuidString),
        ]
    }

    private static func accessToken(on request: Request) async throws -> String {
        guard let account = serviceAccount() else {
            throw Abort(.serviceUnavailable, reason: "Google Play purchase verification is not configured yet.")
        }
        let now = Date()
        let key: JWTKit.Insecure.RSA.PrivateKey
        do {
            key = try JWTKit.Insecure.RSA.PrivateKey(pem: account.privateKey.replacingOccurrences(of: "\\n", with: "\n"))
        } catch {
            throw Abort(.serviceUnavailable, reason: "Google Play purchase verification is not configured correctly.")
        }
        let keys = JWTKeyCollection()
        await keys.add(rsa: key, digestAlgorithm: .sha256)
        let assertion = try await keys.sign(
            Assertion(
                iss: .init(value: account.clientEmail),
                scope: "https://www.googleapis.com/auth/androidpublisher",
                aud: .init(value: ["https://oauth2.googleapis.com/token"]),
                exp: .init(value: now.addingTimeInterval(3_600)),
                iat: .init(value: now)
            )
        )
        let form = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
        let response = try await request.client.post(
            URI(string: "https://oauth2.googleapis.com/token"),
            headers: ["Content-Type": "application/x-www-form-urlencoded"]
        ) { outbound in
            outbound.body = .init(string: form)
        }.get()
        guard response.status == .ok else {
            throw Abort(.serviceUnavailable, reason: "Google Play purchase verification is temporarily unavailable.")
        }
        return try response.content.decode(OAuthResponse.self).accessToken
    }

    private static func serviceAccount() -> ServiceAccount? {
        let data: Data?
        if let raw = Environment.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON") {
            data = raw.data(using: .utf8)
        } else if let encoded = Environment.get("GOOGLE_PLAY_SERVICE_ACCOUNT_BASE64") {
            data = Data(base64Encoded: encoded)
        } else {
            data = nil
        }
        guard let data else { return nil }
        return try? JSONDecoder().decode(ServiceAccount.self, from: data)
    }
}
