@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Announcements", .serialized)
struct AnnouncementTests {
    @Test func contentValidation() throws {
        let valid = AnnouncementInput(id: UUID(), title: "  Hello  ", message: " News \n")
        let (title, message) = try valid.validated()
        #expect(title == "Hello")
        #expect(message == "News")
        for (title, message) in [(" ", "News"), ("Hello", "\n"), (String(repeating: "x", count: 81), "News"), ("Hello", String(repeating: "x", count: 501))] {
            #expect(throws: Abort.self) { try AnnouncementInput(id: UUID(), title: title, message: message).validated() }
        }
    }

    @Test(.enabled(if: Environment.get("DATABASE_NAME")?.hasSuffix("_test") == true && Environment.get("DATABASE_URL") == nil))
    func broadcastAuthorizationConsentAndIdempotency() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let admin = User(email: "announcement-\(UUID())@example.com", passwordHash: "unused")
            admin.role = "admin"; admin.emailVerifiedAt = Date()
            let recipient = User(email: "announcement-\(UUID())@example.com", passwordHash: "unused")
            recipient.emailVerifiedAt = Date()
            let unverified = User(email: "announcement-\(UUID())@example.com", passwordHash: "unused")
            let suspended = User(email: "announcement-\(UUID())@example.com", passwordHash: "unused")
            suspended.emailVerifiedAt = Date(); suspended.suspendedAt = Date()
            for user in [admin, recipient, unverified, suspended] { try await user.save(on: app.db) }
            let req = Request(application: app, on: app.eventLoopGroup.next())
            let controller = AnnouncementController()
            req.auth.login(recipient)
            #expect(try controller.preference(req: req).enabled == true)
            try req.content.encode(AnnouncementPreference(enabled: true))
            #expect(try await controller.updatePreference(req: req).enabled)
            try req.content.encode(AnnouncementPreference(enabled: false))
            #expect(try await controller.updatePreference(req: req).enabled == false)
            #expect(try await User.find(recipient.requireID(), on: app.db)?.announcementPushEnabled == false)
            let id = UUID()
            try req.content.encode(AnnouncementInput(id: id, title: "Try a feature", message: "Find it in My Lists."))
            do { _ = try await controller.send(req: req); Issue.record("Non-admin broadcast succeeded") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            req.auth.login(admin)
            admin.adminTOTPEnabled = true
            do { _ = try await controller.send(req: req); Issue.record("MFA bypass succeeded") }
            catch let error as Abort { #expect(error.status == .unauthorized) }
            req.storage[AdminMFAStorageKey.self] = true
            let first = try await controller.send(req: req)
            let retry = try await controller.send(req: req)
            #expect(first.id == retry.id)
            req.auth.login(recipient)
            #expect(try await controller.cards(req: req).contains { $0.id == id })
            req.parameters.set("announcementID", to: id.uuidString)
            #expect(try await controller.dismiss(req: req) == .noContent)
            #expect(try await controller.dismiss(req: req) == .noContent)
            #expect(try await controller.cards(req: req).contains { $0.id == id } == false)
            // A fresh request models another device using the same account.
            let otherDevice = Request(application: app, on: app.eventLoopGroup.next())
            otherDevice.auth.login(recipient)
            #expect(try await controller.cards(req: otherDevice).contains { $0.id == id } == false)
            req.auth.login(unverified)
            do { _ = try await controller.dismiss(req: req); Issue.record("Non-recipient dismissed an announcement") }
            catch let error as Abort { #expect(error.status == .notFound) }
            req.auth.login(admin)
            #expect(try await controller.cards(req: req).contains { $0.id == id })

            #expect(try await AnnouncementDelivery.query(on: app.db).filter(\.$announcement.$id == id).count() == first.recipientCount)
            #expect(try await AnnouncementDelivery.query(on: app.db).filter(\.$announcement.$id == id).filter(\.$user.$id == unverified.requireID()).count() == 0)
            #expect(try await AnnouncementDelivery.query(on: app.db).filter(\.$announcement.$id == id).filter(\.$user.$id == suspended.requireID()).count() == 0)
            // Opted-out users still receive Activity; the worker can safely run twice.
            let before = try await ActivityNotification.query(on: app.db).filter(\.$user.$id == recipient.requireID()).filter(\.$kind == "announcement").count()
            for _ in 0..<(first.recipientCount / 25 + 2) { try await AnnouncementService.process(on: app.db, client: app.client, logger: app.logger) }
            let after = try await ActivityNotification.query(on: app.db).filter(\.$user.$id == recipient.requireID()).filter(\.$kind == "announcement").count()
            #expect(after == before + 1)
            try req.content.encode(AnnouncementInput(id: id, title: "Changed", message: "Different"))
            do { _ = try await controller.send(req: req); Issue.record("Changed duplicate accepted") }
            catch let error as Abort { #expect(error.status == .conflict) }
            try await Announcement.find(id, on: app.db)?.delete(on: app.db)
            for user in [admin, recipient, unverified, suspended] { try await user.delete(on: app.db) }
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
