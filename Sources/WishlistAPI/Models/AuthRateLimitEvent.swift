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
    static func enforce(_ req: Request, scope: String, limit: Int, window: TimeInterval) async throws {
        let cutoff = Date().addingTimeInterval(-window)
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
        req.headers.first(name: "x-forwarded-for")?.split(separator: ",").first.map(String.init)
            ?? req.remoteAddress?.ipAddress
            ?? "unknown"
    }
}
