import Fluent
import JWT
import Vapor

enum FCMService {
    private struct ServiceAccount: Decodable {
        let projectID: String
        let clientEmail: String
        let privateKey: String
        enum CodingKeys: String, CodingKey { case projectID = "project_id", clientEmail = "client_email", privateKey = "private_key" }
    }
    private struct Assertion: JWTPayload {
        let iss: IssuerClaim
        let scope: String
        let aud: AudienceClaim
        let exp: ExpirationClaim
        let iat: IssuedAtClaim
        func verify(using algorithm: some JWTAlgorithm) async throws { try exp.verifyNotExpired() }
    }
    private struct OAuthResponse: Content { let accessToken: String; enum CodingKeys: String, CodingKey { case accessToken = "access_token" } }
    private struct MessageBody: Content {
        struct Message: Content {
            struct Notification: Content { let title: String; let body: String }
            let token: String
            let notification: Notification
            let data: [String: String]
        }
        let message: Message
    }

    static func send(userID: UUID, kind: String, title: String, message: String, actorID: UUID?, wishlistID: UUID?, on db: any Database, client: any Client, logger: Logger) async {
        guard let account = serviceAccount() else { logger.debug("Firebase credentials are not configured; Android activity was saved without a push."); return }
        let devices: [PushDevice]
        do { devices = try await PushDevice.query(on: db).filter(\.$user.$id == userID).filter(\.$platform == "android").all() }
        catch { logger.warning("Could not load Android push devices: \(error)"); return }
        guard !devices.isEmpty else { return }
        do {
            let now = Date(); let key = try Insecure.RSA.PrivateKey(pem: account.privateKey)
            let keys = JWTKeyCollection(); await keys.add(rsa: key, digestAlgorithm: .sha256)
            let assertion = try await keys.sign(Assertion(iss: .init(value: account.clientEmail), scope: "https://www.googleapis.com/auth/firebase.messaging", aud: .init(value: ["https://oauth2.googleapis.com/token"]), exp: .init(value: now.addingTimeInterval(3600)), iat: .init(value: now)))
            let form = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
            let oauth = try await client.post(URI(string: "https://oauth2.googleapis.com/token"), headers: ["Content-Type": "application/x-www-form-urlencoded"]) { request in request.body = .init(string: form) }.get()
            guard oauth.status == .ok else { logger.warning("Firebase OAuth rejected credentials with status \(oauth.status.code)."); return }
            let accessToken = try oauth.content.decode(OAuthResponse.self).accessToken
            for device in devices {
                var headers = HTTPHeaders(); headers.bearerAuthorization = .init(token: accessToken)
                let payload = MessageBody(message: .init(token: device.token, notification: .init(title: title, body: message), data: ["kind": kind, "actorID": actorID?.uuidString ?? "", "wishlistID": wishlistID?.uuidString ?? ""]))
                let response = try await client.post(URI(string: "https://fcm.googleapis.com/v1/projects/\(account.projectID)/messages:send"), headers: headers, content: payload).get()
                if response.status == .notFound || response.status == .badRequest { try? await device.delete(on: db) }
                else if response.status != .ok { logger.warning("FCM rejected a push with status \(response.status.code).") }
            }
        } catch { logger.warning("FCM delivery failed: \(error)") }
    }

    private static func serviceAccount() -> ServiceAccount? {
        let data: Data?
        if let raw = Environment.get("FIREBASE_SERVICE_ACCOUNT_JSON") { data = raw.data(using: .utf8) }
        else if let encoded = Environment.get("FIREBASE_SERVICE_ACCOUNT_BASE64") { data = Data(base64Encoded: encoded) }
        else { data = nil }
        guard let data else { return nil }
        return try? JSONDecoder().decode(ServiceAccount.self, from: data)
    }
}
