import Fluent
import Vapor

final class AuthRateLimitEvent: Model, @unchecked Sendable {
    static let schema = "auth_rate_limit_events"

    @ID(key: .id) var id: UUID?
    @Field(key: "scope") var scope: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(scope: String) {
        self.scope = scope
    }
}

enum AuthRateLimitService {
    /// New accounts are much more expensive to abuse than ordinary sign-in
    /// attempts: they create database records and trigger email delivery. Keep
    /// the budget separate so existing users can continue signing in normally.
    static func enforceNewAccountCreation(_ req: Request) async throws {
        let clientKey = clientKey(req)
        // A household can set up a few accounts together, but a rapid burst is
        // a strong signal of scripted registration. The screenshot that
        // prompted this protection would be stopped by the fourth attempt.
        try await enforce(req, scope: "new-account-burst:\(clientKey)", limit: 3, window: 10 * 60)
        // The daily ceiling limits slower, deliberate automation without
        // affecting ordinary single-account registration.
        try await enforce(req, scope: "new-account-day:\(clientKey)", limit: 10, window: 24 * 60 * 60)
    }

    static func enforce(_ req: Request, scope: String, limit: Int, window: TimeInterval) async throws {
        let cutoff = Date().addingTimeInterval(-window)
        // Keep the rate-limit table bounded while each scope is active. This
        // also prevents old attempts from becoming an operational data leak.
        try await AuthRateLimitEvent.query(on: req.db)
            .filter(\.$scope == scope)
            .filter(\.$createdAt <= cutoff)
            .delete()
        let recent = try await AuthRateLimitEvent.query(on: req.db)
            .filter(\.$scope == scope)
            .filter(\.$createdAt > cutoff)
            .count()
        guard recent < limit else {
            throw Abort(.tooManyRequests, reason: "Too many attempts. Please wait a few minutes and try again.")
        }
        try await AuthRateLimitEvent(scope: scope).save(on: req.db)
    }

    static func clientKey(_ req: Request) -> String {
        let directAddress = req.remoteAddress?.ipAddress

        // A client can forge X-Forwarded-For when it reaches the API directly.
        // Only use it when the deployment explicitly confirms that every
        // request passes through a proxy which strips client supplied values
        // and writes the header itself.
        guard Environment.get("TRUST_PROXY_CLIENT_IP")?.lowercased() == "true",
              let forwarded = req.headers.first(name: "x-forwarded-for")?.split(separator: ",").first,
              let clientAddress = String(forwarded).trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfInvalidIPAddress
        else {
            return directAddress ?? "unknown"
        }
        return clientAddress
    }
}

private extension String {
    /// Keeps a malicious header from becoming an unbounded database scope.
    /// This deliberately permits IPv4 and IPv6 textual forms only.
    var nilIfInvalidIPAddress: String? {
        guard !isEmpty, count <= 45,
              range(of: #"^[0-9A-Fa-f:.]+$"#, options: .regularExpression) != nil
        else { return nil }
        return self
    }
}
