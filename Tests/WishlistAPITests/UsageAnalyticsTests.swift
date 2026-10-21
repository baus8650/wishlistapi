@testable import WishlistAPI
import Foundation
import Testing
import Vapor

@Suite("Usage analytics privacy")
struct UsageAnalyticsTests {
    @Test("Geolocation trusts forwarded client IPs only when explicitly enabled")
    func forwardedAddresses() {
        let headers: HTTPHeaders = ["X-Real-IP": " 8.8.8.8 ", "X-Forwarded-For": "1.1.1.1, 10.0.0.2"]
        #expect(usageIPAddress(headers: headers, peer: "10.0.0.1", trustProxy: false) == "10.0.0.1")
        #expect(usageIPAddress(headers: headers, peer: "10.0.0.1", trustProxy: true) == "8.8.8.8")
        #expect(usageIPAddress(headers: ["X-Forwarded-For": "8.8.8.8, 10.0.0.2"], peer: "10.0.0.1", trustProxy: true) == "8.8.8.8")
        #expect(usageIPAddress(headers: ["X-Real-IP": " "], peer: "10.0.0.1", trustProxy: true) == "10.0.0.1")
        #expect(OfflineLocationLookup.shared.isAvailable)
        let ip = usageIPAddress(headers: headers, peer: "10.0.0.1", trustProxy: true)
        #expect(OfflineLocationLookup.shared.location(for: ip)?.city != nil)
    }

    @Test("Details are absent without consent, including after withdrawal")
    func consentAndWithdrawal() {
        let id = UUID(), session = UUID()
        let input = UsageEventRequest(id: id, source: "web", kind: "page_view", path: "/", consented: true, sessionID: session, device: "Mobile", browser: "Safari\n", os: "iOS", version: "1.3", language: "en", timezone: "America/New_York", referrer: "https://shop.example/private?secret=token", campaign: "launch")
        let detailed = makeUsageEvent(input, headers: [:], ip: "8.8.8.8")
        #expect(detailed.country == "US")
        #expect(detailed.region != nil && detailed.city != nil)
        #expect(detailed.browser == "Safari")
        #expect(detailed.referrer == "shop.example")
        #expect(detailed.sessionID == session)
        for headers: HTTPHeaders in [[:], ["DNT": "1"], ["Sec-GPC": "1"]] {
            let consented = !headers.isEmpty
            let denied = UsageEventRequest(id: id, source: "web", kind: "page_view", path: "/", consented: consented, sessionID: session, device: "Mobile", browser: "Safari", os: "iOS", language: "en", timezone: "America/New_York", referrer: "https://shop.example/private", campaign: "launch")
            let event = makeUsageEvent(denied, headers: headers, ip: "8.8.8.8", existing: detailed)
            #expect(!event.consented)
            #expect(event.country == nil && event.region == nil && event.city == nil)
            #expect(event.sessionID == nil && event.device == nil && event.browser == nil && event.os == nil)
            #expect(event.language == nil && event.timezone == nil && event.referrer == nil && event.campaign == nil)
            #expect(event.id == id)
        }
    }
    @Test("Paths exclude private tokens and dimensions reject invalid campaigns")
    func sanitization() {
        #expect(!usagePaths.contains("/share/private-token"))
        #expect(!usagePaths.contains("/reset-password?token=secret"))
        #expect(!usagePaths.contains("/wishlist/private-title"))
        let event = makeUsageEvent(.init(id: UUID(), source: "ios", kind: "app_open", path: "home", consented: true, campaign: "email@example.com"), headers: [:], ip: "127.0.0.1")
        #expect(event.campaign == nil && event.country == nil)
        #expect(usageText(String(repeating: "x", count: 200))?.count == 80)
        #expect(OfflineCountryLookup.shared.country(for: "::ffff:8.8.8.8") == "US")
        #expect(OfflineLocationLookup.shared.location(for: "not-an-ip") == nil)
    }
    @Test("Administrative metrics require admin access and configured MFA")
    func access() async throws {
        let app = try await Application.make(.testing)
        do {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            #expect(throws: Abort.self) { try AdminAccessService.require(req) }
            let user = User(id: UUID(), email: "metrics-reader@example.com", passwordHash: "unused")
            req.auth.login(user)
            #expect(!usageEventIsExcluded(for: req))
            #expect(throws: Abort.self) { try AdminAccessService.require(req) }
            user.role = "admin"
            #expect(usageEventIsExcluded(for: req))
            #expect(try AdminAccessService.require(req).id == user.id)
            user.adminTOTPEnabled = true
            #expect(throws: Abort.self) { try AdminAccessService.require(req) }
            req.storage[AdminMFAStorageKey.self] = true
            #expect(try AdminAccessService.require(req).id == user.id)
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
