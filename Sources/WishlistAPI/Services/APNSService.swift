import Fluent
import JWT
import Vapor

enum APNSService {
    private struct ProviderToken: JWTPayload {
        let iss: IssuerClaim
        let iat: IssuedAtClaim
        func verify(using algorithm: some JWTAlgorithm) async throws {}
    }

    private struct Payload: Content {
        struct APS: Content {
            struct Alert: Content { let title: String; let body: String }
            let alert: Alert
            let sound: String
            let badge: Int
        }
        let aps: APS
        let kind: String
        let wishlistID: UUID?
    }

    private struct ErrorResponse: Content { let reason: String }

    static func send(userID: UUID, kind: String, title: String, message: String, wishlistID: UUID?, on db: any Database, client: any Client, logger: Logger) async {
        guard let keyID = Environment.get("APNS_KEY_ID"),
              let teamID = Environment.get("APNS_TEAM_ID"),
              let bundleID = Environment.get("APNS_BUNDLE_ID"),
              let rawKey = Environment.get("APNS_PRIVATE_KEY") else {
            logger.debug("APNs credentials are not configured; activity was saved without a push.")
            return
        }
        let devices: [PushDevice]
        do { devices = try await PushDevice.query(on: db).filter(\.$user.$id == userID).all() }
        catch { logger.warning("Could not load push devices: \(error)"); return }
        guard !devices.isEmpty else { return }

        do {
            let unreadCount = try await ActivityNotification.query(on: db)
                .filter(\.$user.$id == userID)
                .filter(\.$readAt == nil)
                .count()
            let privateKey = try ES256PrivateKey(pem: rawKey.replacingOccurrences(of: "\\n", with: "\n"))
            let keys = JWTKeyCollection()
            await keys.add(ecdsa: privateKey, kid: JWKIdentifier(string: keyID))
            let token = try await keys.sign(
                ProviderToken(iss: IssuerClaim(value: teamID), iat: IssuedAtClaim(value: Date())),
                kid: JWKIdentifier(string: keyID)
            )
            let payload = Payload(
                aps: .init(alert: .init(title: title, body: message), sound: "default", badge: unreadCount),
                kind: kind,
                wishlistID: wishlistID
            )
            for device in devices {
                let host = device.environment == "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com"
                var headers = HTTPHeaders()
                headers.bearerAuthorization = .init(token: token)
                headers.add(name: "apns-topic", value: bundleID)
                headers.add(name: "apns-push-type", value: "alert")
                headers.add(name: "apns-priority", value: "10")
                let response = try await client.post(URI(string: "https://\(host)/3/device/\(device.token)"), headers: headers, content: payload).get()
                let reason = try? response.content.decode(ErrorResponse.self).reason
                if response.status == .gone || ["BadDeviceToken", "DeviceTokenNotForTopic", "Unregistered"].contains(reason) {
                    try? await device.delete(on: db)
                } else if response.status != .ok {
                    logger.warning("APNs rejected a push with status \(response.status.code): \(reason ?? "unknown reason").")
                }
            }
        } catch {
            logger.warning("APNs delivery failed: \(error)")
        }
    }
}
