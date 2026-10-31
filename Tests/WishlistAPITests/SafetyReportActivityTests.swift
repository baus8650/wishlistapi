@testable import WishlistAPI
import Foundation
import Testing
import Vapor

struct SafetyReportActivityTests {
    @Test func activityDestinationRoundTripsAndOlderPayloadsDecode() throws {
        let reportID = UUID()
        let activity = ActivityDTO(id: UUID(), kind: "safety_report_submitted", title: "New safety report", message: "A item_note was reported for other.", actorID: nil, wishlistID: nil, reportID: reportID, readAt: nil, createdAt: Date())
        let decoded = try JSONDecoder().decode(ActivityDTO.self, from: JSONEncoder().encode(activity))
        #expect(decoded.reportID == reportID)
        let old = "{\"id\":\"\(UUID())\",\"kind\":\"safety_report_submitted\",\"title\":\"New safety report\",\"message\":\"Report received\"}"
        #expect(try JSONDecoder().decode(ActivityDTO.self, from: Data(old.utf8)).reportID == nil)
    }

    @Test func individualReportRequiresAdministrator() async throws {
        let app = try await Application.make(.testing)
        do {
            let req = Request(application: app, on: app.eventLoopGroup.next())
            do { _ = try await UserReportController().show(req: req); Issue.record("Anonymous request accessed a report") }
            catch let error as Abort { #expect(error.status == .unauthorized) }
            let user = User(email: "ordinary-\(UUID())@example.com", passwordHash: "unused")
            req.auth.login(user)
            do { _ = try await UserReportController().show(req: req); Issue.record("Non-admin accessed a report") }
            catch let error as Abort { #expect(error.status == .forbidden) }
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
}
