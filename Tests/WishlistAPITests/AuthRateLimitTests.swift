@testable import WishlistAPI
import Testing
import Vapor

@Suite("Authentication rate limits")
struct AuthRateLimitTests {
    @Test("A client-controlled forwarding header is ignored by default")
    func forwardedAddressRequiresExplicitProxyTrust() async throws {
        let app = try await Application.make(.testing)
        let request = Request(application: app, on: app.eventLoopGroup.next())
        request.headers.replaceOrAdd(name: "x-forwarded-for", value: "203.0.113.99")

        #expect(AuthRateLimitService.clientKey(request) == "unknown")
        try await app.asyncShutdown()
    }
}
