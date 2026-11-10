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

    @Test func separatePushAndAnnouncementText() throws {
        let longText = String(repeating: "Full announcement.\n", count: 100)
        let input = AnnouncementInput(id: UUID(), title: "Hello", message: longText, pushBody: "  Read the news  ")
        #expect(try input.validated().1 == longText.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(try input.validatedPushBody() == "Read the news")
        #expect(try AnnouncementInput(id: UUID(), title: "Legacy", message: "Older message").validatedPushBody() == "Older message")
        for push in [" ", String(repeating: "x", count: 501)] {
            #expect(throws: Abort.self) { try AnnouncementInput(id: UUID(), title: "Hello", message: longText, pushBody: push).validated() }
        }
        #expect(throws: Abort.self) { try AnnouncementInput(id: UUID(), title: "Hello", message: String(repeating: "x", count: 10001), pushBody: "Short alert").validated() }
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
            try req.content.encode(AnnouncementInput(id: id, title: "Try a feature", message: "Find it in My Lists.", pushBody: "A short feature tip"))
            do { _ = try await controller.send(req: req); Issue.record("Non-admin broadcast succeeded") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            req.auth.login(admin)
            admin.adminTOTPEnabled = true
            do { _ = try await controller.send(req: req); Issue.record("MFA bypass succeeded") }
            catch let error as Abort { #expect(error.status == .unauthorized) }
            req.storage[AdminMFAStorageKey.self] = true
            // Test sends exercise all three surfaces, restricted to the admin.
            let device = PushDevice(userID: try admin.requireID(), token: UUID().uuidString, environment: "sandbox")
            try await device.create(on: app.db)
            #expect(try await controller.test(req: req) == .noContent)
            #expect(try await Announcement.find(id, on: app.db) == nil)
            let previews = try await controller.cards(req: req).filter { $0.title == "[Test] Try a feature" }
            let preview = try #require(previews.first)
            #expect(previews.count == 1)
            #expect(preview.message == "Find it in My Lists.")
            #expect(try await Announcement.find(preview.id, on: app.db)?.pushBody == "A short feature tip")
            let previewActivity = try await ActivityNotification.query(on: app.db).filter(\.$user.$id == admin.requireID()).filter(\.$title == preview.title).first()
            #expect(previewActivity?.message == "Find it in My Lists.")
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == admin.requireID()).filter(\.$title == preview.title).count() == 1)
            #expect(try await AnnouncementDelivery.query(on: app.db).filter(\.$announcement.$id == preview.id).count() == 1)
            #expect(try await AnnouncementDelivery.query(on: app.db).filter(\.$announcement.$id == preview.id).filter(\.$processed == true).count() == 1)
            req.auth.login(recipient)
            #expect(try await controller.cards(req: req).contains { $0.id == preview.id } == false)
            req.auth.login(admin)
            // Processing the queue must not create a second Activity entry.
            try await AnnouncementService.process(on: app.db, client: app.client, logger: app.logger)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == admin.requireID()).filter(\.$title == preview.title).count() == 1)
            req.parameters.set("announcementID", to: preview.id.uuidString)
            #expect(try await controller.dismiss(req: req) == .noContent)
            #expect(try await controller.cards(req: req).contains { $0.id == preview.id } == false)
            let first = try await controller.send(req: req)
            let retry = try await controller.send(req: req)
            #expect(first.id == retry.id)
            #expect(first.pushBody == "A short feature tip")
            try req.content.encode(AnnouncementInput(id: id, title: "Try a feature", message: "Find it in My Lists.", pushBody: "Changed push"))
            do { _ = try await controller.send(req: req); Issue.record("Push text changed on retry") }
            catch let error as Abort { #expect(error.status == .conflict) }
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
            let targetedID = UUID()
            let recipientID = try recipient.requireID()
            try req.content.encode(AnnouncementSelection(userIDs: [recipientID]))
            let selectedAudience = try await controller.selectedAudience(req: req)
            #expect(selectedAudience.users == 1)
            #expect(selectedAudience.pushUsers == 0) // This recipient opted out.
            try req.content.encode(AnnouncementInput(id: targetedID, title: "Just for you", message: "A targeted announcement", userIDs: [recipientID, recipientID]))
            let targeted = try await controller.send(req: req)
            #expect(targeted.recipientCount == 1)
            #expect(targeted.audience == "selected")
            #expect(try await controller.send(req: req).id == targeted.id)
            #expect(try await AnnouncementDelivery.query(on: app.db).filter(\.$announcement.$id == targetedID).count() == 1)
            #expect(try await controller.cards(req: req).contains { $0.id == targetedID } == false)
            req.auth.login(recipient)
            #expect(try await controller.cards(req: req).contains { $0.id == targetedID })
            req.auth.login(admin)
            try await AnnouncementService.process(on: app.db, client: app.client, logger: app.logger)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == recipientID).filter(\.$title == "Just for you").count() == 1)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == admin.requireID()).filter(\.$title == "Just for you").count() == 0)
            try req.content.encode(AnnouncementInput(id: targetedID, title: "Just for you", message: "A targeted announcement"))
            do { _ = try await controller.send(req: req); Issue.record("Audience changed on retry") }
            catch let error as Abort { #expect(error.status == .conflict) }
            for ids: [UUID] in [[], [UUID()], [try unverified.requireID()], [try suspended.requireID()]] {
                let invalidID = UUID()
                try req.content.encode(AnnouncementInput(id: invalidID, title: "Invalid audience", message: "Must not broadcast", userIDs: ids))
                do { _ = try await controller.send(req: req); Issue.record("Invalid selection accepted") }
                catch let error as Abort { #expect(error.status == .badRequest) }
                #expect(try await Announcement.find(invalidID, on: app.db) == nil)
            }
            req.auth.login(recipient)
            req.parameters.set("announcementID", to: targetedID.uuidString)
            let archive = try await controller.archive(req: req)
            #expect(archive.items.contains { $0.id == id }) // Previously dismissed on My Lists.
            #expect(archive.items.contains { $0.id == targetedID })
            #expect(archive.unreadCount == 1)
            #expect(try await ActivityService.unreadCount(userID: recipientID, on: app.db) == 1) // No double counting its Activity copy.
            let normal = ActivityNotification(userID: recipientID, kind: "friend_accepted", title: "Friend", message: "Hello")
            try await normal.create(on: app.db)
            #expect(try await ActivityService.unreadCount(userID: recipientID, on: app.db) == 2)
            req.url = URI(string: "/v1/activity?category=activity")
            let activityController = ActivityController()
            #expect(try await activityController.list(req: req).allSatisfy { $0.kind != "announcement" })
            _ = try await activityController.readAll(req: req)
            #expect(try await controller.archive(req: req).unreadCount == 1)
            #expect(try await ActivityService.unreadCount(userID: recipientID, on: app.db) == 1)
            _ = try await activityController.clearAll(req: req)
            req.url = URI(string: "/v1/activity") // Older clients can also clear the legacy announcement copies.
            _ = try await activityController.clearAll(req: req)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == recipientID).count() == 0)
            #expect(try await controller.archive(req: req).items.contains { $0.id == targetedID })
            #expect(try await controller.read(req: req) == .noContent)
            #expect(try await controller.read(req: req) == .noContent)
            #expect(try await controller.archive(req: req).unreadCount == 0)
            #expect(try await controller.cards(req: req).contains { $0.id == targetedID }) // Reading is separate from dismissal.
            req.auth.login(unverified)
            do { _ = try await controller.read(req: req); Issue.record("Non-recipient read another account's announcement") }
            catch let error as Abort { #expect(error.status == .notFound) }
            #expect(try await controller.archive(req: req).items.isEmpty)
            req.auth.login(recipient)
            var olderIDs: [UUID] = []
            for index in 0..<55 {
                let olderID = UUID(); olderIDs.append(olderID)
                let older = Announcement(id: olderID, title: "Archive \(index)", message: "Older news", adminID: try admin.requireID(), recipientCount: 1, recipientIDs: [recipientID])
                try await older.create(on: app.db)
                let delivery = AnnouncementDelivery(announcementID: olderID, userID: recipientID)
                delivery.processed = true
                try await delivery.create(on: app.db)
            }
            let firstPage = try await controller.archive(req: req)
            #expect(firstPage.items.count == 50)
            #expect(firstPage.nextPage == 2)
            req.url = URI(string: "/v1/announcements/history?page=2")
            let secondPage = try await controller.archive(req: req)
            #expect(secondPage.items.count == 7)
            #expect(secondPage.nextPage == nil)
            #expect(Set(firstPage.items.map(\.id)).intersection(secondPage.items.map(\.id)).isEmpty)
            #expect(secondPage.unreadCount == 55)
            for olderID in olderIDs { try await Announcement.find(olderID, on: app.db)?.delete(on: app.db) }
            try await Announcement.find(targetedID, on: app.db)?.delete(on: app.db)
            try await Announcement.find(preview.id, on: app.db)?.delete(on: app.db)
            try await Announcement.find(id, on: app.db)?.delete(on: app.db)
            for user in [admin, recipient, unverified, suspended] { try await user.delete(on: app.db) }
            try await app.asyncShutdown()
        } catch { try await app.asyncShutdown(); throw error }
    }
}
