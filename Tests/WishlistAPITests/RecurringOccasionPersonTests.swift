@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor

@Suite("Person-linked occasion reminders", .serialized)
struct RecurringOccasionPersonTests {
    @Test func associationPreferencesAndLegacyEdits() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let owner = User(email: "occasion-owner-\(UUID())@example.com", passwordHash: "unused")
            owner.hasLifetimePro = true
            let partner = User(email: "occasion-partner-\(UUID())@example.com", passwordHash: "unused")
            partner.displayName = "Alex"
            let stranger = User(email: "occasion-stranger-\(UUID())@example.com", passwordHash: "unused")
            for user in [owner, partner, stranger] { try await user.save(on: app.db) }
            try await Friendship(requesterID: owner.requireID(), recipientID: partner.requireID(), status: "accepted").save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(owner)
            var body = RecurringOccasionDTO(id: nil, name: "Our anniversary", eventMonth: 6, eventDay: 12,
                reminderMonth: 6, reminderDay: 1, icon: "heart", colorHex: "786A82", lastCreatedYear: nil,
                notificationsEnabled: false, personID: partner.id)
            try req.content.encode(body)
            let controller = RecurringOccasionController()
            let created = try await controller.create(req: req)
            #expect(created.personID == partner.id)
            #expect(created.person?.displayName == "Alex")
            #expect(created.notificationsEnabled == false)
            req.parameters.set("occasionID", to: try #require(created.id).uuidString)

            // An older client editing other fields must preserve the association and preference.
            body.personID = nil
            body.notificationsEnabled = nil
            body.name = "Anniversary dinner"
            try req.content.encode(body)
            let legacyEdit = try await controller.update(req: req)
            #expect(legacyEdit.personID == partner.id)
            #expect(legacyEdit.notificationsEnabled == false)
            #expect(legacyEdit.name == "Anniversary dinner")

            body.personID = stranger.id
            try req.content.encode(body)
            do {
                _ = try await controller.update(req: req)
                Issue.record("An unconnected account was linked to the occasion")
            } catch let error as Abort { #expect(error.status == .badRequest) }

            // Occasion details remain private to their creator.
            req.auth.login(partner)
            #expect(try await controller.index(req: req).isEmpty)
            req.auth.login(owner)
            body.personID = nil
            body.clearPerson = true
            body.notificationsEnabled = true
            try req.content.encode(body)
            let cleared = try await controller.update(req: req)
            #expect(cleared.person == nil)
            #expect(cleared.personID == nil)
            #expect(cleared.notificationsEnabled == true)
            let reloaded = try await controller.index(req: req)
            #expect(reloaded.first?.personID == nil)
            #expect(reloaded.first?.notificationsEnabled == true)
            for user in [owner, partner, stranger] { try await user.delete(on: app.db) }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
