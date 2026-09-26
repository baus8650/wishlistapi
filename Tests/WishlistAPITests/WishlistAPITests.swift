@testable import WishlistAPI
import Fluent
import Testing
import VaporTesting

@Suite("API smoke tests", .serialized)
struct WishlistAPITests {
    private func withApp(_ test: (Application) async throws -> ()) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            try await test(app)
            try await app.autoRevert()
        } catch {
            try? await app.autoRevert()
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("Hello route is available")
    func helloRoute() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "hello", afterResponse: { response async in
                #expect(response.status == .ok)
                #expect(response.body.string == "Hello, world!")
            })
        }
    }

    @Test("Health route is available")
    func healthRoute() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "health", afterResponse: { response async in
                #expect(response.status == .ok)
            })
        }
    }

    @Test("User public response never exposes the password hash")
    func publicUserShape() async throws {
        let user = User(email: "test@example.com", passwordHash: "not-returned")
        let response = user.toPublic()
        #expect(response.email == "test@example.com")
        #expect(response.onboardingVersion == nil)
    }

    @Test("Dismissing a report leaves the reported account and content untouched")
    func dismissReportOnlyResolvesTheReport() async throws {
        try await withApp { app in
            let admin = User(
                email: "moderator@example.com",
                passwordHash: try Bcrypt.hash("correct-horse-battery-staple")
            )
            admin.role = "admin"
            admin.emailVerifiedAt = Date()
            try await admin.save(on: app.db)
            let adminID = try admin.requireID()

            let reportedUser = User(
                email: "reported@example.com",
                passwordHash: try Bcrypt.hash("correct-horse-battery-staple")
            )
            try await reportedUser.save(on: app.db)
            let reportedUserID = try reportedUser.requireID()

            let wishlist = Wishlist(
                ownerUserId: reportedUserID,
                title: "Keep this list"
            )
            try await wishlist.save(on: app.db)
            let wishlistID = try wishlist.requireID()

            let report = UserReport(
                reporterID: adminID,
                reportedID: reportedUserID,
                reason: "other",
                details: "This report should be dismissed.",
                targetType: "wishlist",
                targetID: wishlistID
            )
            try await report.save(on: app.db)
            let reportID = try report.requireID()

            let loginResponse = try await app.testing().sendRequest(
                .POST,
                "v1/auth/login",
                beforeRequest: { request in
                    try request.content.encode(
                        LoginRequest(
                            email: admin.email,
                            password: "correct-horse-battery-staple",
                            totpCode: nil
                        ),
                        as: .json
                    )
                }
            )
            #expect(loginResponse.status == .ok)
            let token = try loginResponse.content.decode(TokenResponse.self).accessToken

            let dismissalResponse = try await app.testing().sendRequest(
                .POST,
                "v1/admin/reports/\(reportID)/dismiss",
                headers: ["Authorization": "Bearer \(token)"]
            )
            #expect(dismissalResponse.status == .noContent)

            guard let dismissedReport = try await UserReport.find(reportID, on: app.db) else {
                Issue.record("Dismissed report was not found.")
                return
            }
            #expect(dismissedReport.status == "dismissed")
            #expect(dismissedReport.resolvedAt != nil)
            #expect(dismissedReport.$moderator.id == adminID)

            let refreshedReportedUser = try await User.find(reportedUserID, on: app.db)
            #expect(refreshedReportedUser?.suspendedAt == nil)
            let survivingWishlist = try await Wishlist.find(wishlistID, on: app.db)
            #expect(survivingWishlist != nil)
        }
    }
}
