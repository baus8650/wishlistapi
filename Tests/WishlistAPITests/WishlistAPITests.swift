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
}
