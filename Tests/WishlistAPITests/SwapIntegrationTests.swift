@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Hushful Swap integration", .serialized)
struct SwapIntegrationTests {
    @Test func accountOnlyInvitationsDrawPrivacyAndLockedRoster() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await app.autoMigrate()
            let users = (0..<5).map { index in
                let user = User(email: "swap-\(UUID())@example.com", passwordHash: "unused")
                user.displayName = "Participant \(index)"
                return user
            }
            for user in users { try await user.save(on: app.db) }
            let owner = users[0], friend = users[1], stranger = users[4]
            try await Friendship(requesterID: owner.requireID(), recipientID: friend.requireID(), status: "accepted").save(on: app.db)
            let controller = HushfulSwapController()
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(owner)
            let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.timeZone = TimeZone(secondsFromGMT: 0); dateFormatter.dateFormat = "yyyy-MM-dd"
            let date = dateFormatter.string(from: Date().addingTimeInterval(30 * 86400))
            try req.content.encode(SwapCreate(title: "Our swap", exchangeDate: date, priceLimit: 50, currencyCode: "USD", userIDs: [friend.requireID()]))
            let created = try await controller.create(req: req)
            #expect(created.members.count == 2)
            #expect(created.members.first(where: { $0.name == friend.displayName })?.status == "pending")
            #expect(try await controller.index(req: req).contains { $0.id == created.id })
            req.parameters.set("swapID", to: created.id.uuidString)
            let friendMember = try #require(created.members.first { $0.id != created.myID })
            try req.content.encode(SwapUpdate(action: "remind", memberID: friendMember.id))
            let reminded = try await controller.update(req: req)
            #expect(reminded.members.first { $0.id == friendMember.id }?.canRemind == false)
            do { _ = try await controller.update(req: req); Issue.record("Repeated invitation push was allowed") }
            catch let error as Abort { #expect(error.status == .tooManyRequests) }
            req.auth.login(stranger)
            do { _ = try await controller.detail(req: req); Issue.record("Outsider read swap") }
            catch let error as Abort { #expect(error.status == .notFound) }
            req.auth.login(friend)
            #expect(try await controller.index(req: req).contains { $0.id == created.id })
            try req.content.encode(SwapUpdate(action: "draw"))
            do { _ = try await controller.update(req: req); Issue.record("Non-admin drew recipients") }
            catch let error as Abort { #expect(error.status == .conflict || error.status == .forbidden) }
            try req.content.encode(SwapUpdate(action: "accept"))
            #expect(try await controller.update(req: req).myStatus == "accepted")
            try req.content.encode(SwapUpdate(action: "reminder", reminderDays: 12))
            #expect(try await controller.update(req: req).reminderDays == 12)
            try req.content.encode(SwapUpdate(action: "reminder"))
            #expect(try await controller.update(req: req).reminderDays == nil)
            let invite = try #require(created.inviteURL?.split(separator: "/").last.map(String.init))
            let joinReq = Request(application: app, on: app.eventLoopGroup.next())
            joinReq.parameters.set("invite", to: invite)
            do { _ = try await SwapInvitationController().join(req: joinReq); Issue.record("Anonymous user joined swap") }
            catch let error as Abort { #expect(error.status == .unauthorized) }
            let rejected = try await app.testing().sendRequest(.POST, "/v1/swap-invites/\(invite)")
            #expect(rejected.status == .unauthorized)
            let anonymousPreview = try await app.testing().sendRequest(.GET, "/v1/swap-invites/\(invite)")
            #expect(anonymousPreview.status == .ok)
            joinReq.auth.login(users[2])
            let joined = try await SwapInvitationController().join(req: joinReq)
            #expect(joined.swap.myStatus == "accepted")
            let rejoined = try await SwapInvitationController().join(req: joinReq)
            #expect(rejoined.swap.members.count == 3)
            joinReq.auth.login(users[3])
            _ = try await SwapInvitationController().join(req: joinReq)
            joinReq.parameters.set("swapID", to: created.id.uuidString)
            try joinReq.content.encode(SwapUpdate(action: "wishes", wishes: [.init(title: "A gift idea")]))
            #expect(try await controller.update(req: joinReq).wishes.first?.title == "A gift idea")
            req.auth.login(owner)
            try req.content.encode(SwapUpdate(action: "draw"))
            let drawn = try await controller.update(req: req)
            #expect(drawn.status == "drawn")
            #expect(drawn.recipient != nil)
            #expect(drawn.inviteURL == nil)
            let stored = try #require(try await HushfulSwap.find(created.id, on: app.db))
            #expect(Set(stored.state.members.compactMap(\.recipientID)).count == 4)
            #expect(stored.state.members.allSatisfy { $0.id != $0.recipientID })
            let firstAssignments = stored.state.members.map(\.recipientID)
            do { _ = try await controller.update(req: req); Issue.record("Organizer redrew recipients") }
            catch let error as Abort { #expect(error.status == .conflict) }
            try req.content.encode(SwapUpdate(action: "remove", memberID: friendMember.id))
            do { _ = try await controller.update(req: req); Issue.record("Organizer changed a drawn roster") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            #expect(try await HushfulSwap.find(created.id, on: app.db)?.state.members.map(\.recipientID) == firstAssignments)
            let participantView = try await controller.detail(req: joinReq)
            #expect(participantView.recipient != nil)
            #expect(participantView.isAdmin == false)
            let json = String(decoding: try JSONEncoder().encode(drawn), as: UTF8.self)
            #expect(!json.contains("recipientID"))
            #expect(!json.contains("guestHash"))
            let oldGuestRoute = try await app.testing().sendRequest(.GET, "/v1/guest-swaps/\(created.id)", headers: ["X-Swap-Key": invite])
            #expect(oldGuestRoute.status != .ok)
            let unauthorized = try await app.testing().sendRequest(.GET, "/v1/swaps/\(created.id)", headers: ["X-Swap-Key": invite])
            #expect(unauthorized.status == .unauthorized)
            // Only the organizer can change dates; even after drawing, assignments remain fixed.
            let laterDate = dateFormatter.string(from: Date().addingTimeInterval(60 * 86400))
            try joinReq.content.encode(SwapUpdate(action: "date", exchangeDate: laterDate))
            do { _ = try await controller.update(req: joinReq); Issue.record("Participant changed the date") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            #expect(try await controller.detail(req: joinReq).exchangeDate == date)
            for i in stored.state.members.indices { stored.state.members[i].purchaseReminderSent = true }
            try await stored.save(on: app.db)
            try req.content.encode(SwapUpdate(action: "date", exchangeDate: laterDate))
            let rescheduled = try await controller.update(req: req)
            #expect(rescheduled.exchangeDate == laterDate)
            #expect(rescheduled.status == "drawn")
            let updated = try #require(try await HushfulSwap.find(created.id, on: app.db))
            #expect(updated.state.members.map(\.recipientID) == firstAssignments)
            #expect(updated.state.members.allSatisfy { $0.purchaseReminderSent == false })
            #expect(try await controller.detail(req: joinReq).exchangeDate == laterDate)
            try req.content.encode(SwapUpdate(action: "date", exchangeDate: "2027-02-30"))
            do { _ = try await controller.update(req: req); Issue.record("Invalid calendar date was saved") }
            catch let error as Abort { #expect(error.status == .badRequest) }
            #expect(try await controller.detail(req: req).exchangeDate == laterDate)
            // Existing account members can reopen their swap from the invitation after drawing.
            #expect(try await SwapInvitationController().join(req: joinReq).swap.recipient != nil)
            for user in users { try await user.delete(on: app.db) }
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    @Test func listCopyDoesNotGrantNormalListAccessOrCreateViewerActivity() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); try await app.autoMigrate()
            let owner = User(email: "swap-list-\(UUID())@example.com", passwordHash: "unused")
            try await owner.save(on: app.db)
            let list = try Wishlist(ownerUserId: owner.requireID(), title: "Private ideas"); list.purpose = "for_myself"
            try await list.save(on: app.db)
            let item = try WishlistItem(wishlistId: list.requireID(), title: "A book", url: "https://example.com/book", ownerNote: "Paperback")
            try await item.save(on: app.db)
            try await WishlistItemMembership(itemID: item.requireID(), wishlistID: list.requireID()).save(on: app.db)
            let swap = try HushfulSwap(ownerID: owner.requireID(), state: .init(title: "Copy", exchangeDate: "2027-12-20", currencyCode: "USD", members: [.init(userID: owner.requireID(), name: "Owner", status: "accepted")]))
            try await swap.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next()); req.auth.login(owner); req.parameters.set("swapID", to: try swap.requireID().uuidString)
            try req.content.encode(SwapUpdate(action: "wishes", wishlistID: list.requireID()))
            let copied = try await HushfulSwapController().update(req: req)
            #expect(copied.wishes.first?.title == "A book")
            #expect(copied.wishes.first?.note == "Paperback")
            #expect(try await WishlistViewer.query(on: app.db).filter(\.$wishlist.$id == list.requireID()).count() == 0)
            #expect(try await Wishlist.find(list.requireID(), on: app.db)?.visibility == "private")
            list.matureContentEnabled = true; try await list.save(on: app.db)
            do { _ = try await HushfulSwapController().update(req: req); Issue.record("Mature list was copied into a swap") }
            catch let error as Abort { #expect(error.status == .badRequest) }
            try await owner.delete(on: app.db)
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }
    @Test func scheduledRemindersArePersistedExactlyOnceAcrossConcurrentWorkers() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); try await app.autoMigrate()
            let user = User(email: "swap-reminder-\(UUID())@example.com", passwordHash: "unused")
            try await user.save(on: app.db)
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"
            let tomorrow = formatter.string(from: Date().addingTimeInterval(86400))
            let swap = try HushfulSwap(ownerID: user.requireID(), state: .init(title: "Reminder", exchangeDate: tomorrow, currencyCode: "USD", status: "drawn", members: [.init(userID: user.requireID(), name: "Owner", status: "accepted", reminderDays: 7)]))
            try await swap.save(on: app.db)
            async let first: Void = SwapReminderService.sendDue(on: app.db, client: app.client, logger: app.logger)
            async let second: Void = SwapReminderService.sendDue(on: app.db, client: app.client, logger: app.logger)
            _ = try await (first, second)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == user.requireID()).filter(\.$kind == "swap_purchase_reminder").count() == 1)
            #expect(try await HushfulSwap.find(swap.requireID(), on: app.db)?.state.members.first?.purchaseReminderSent == true)
            try await SwapReminderService.sendDue(on: app.db, client: app.client, logger: app.logger)
            #expect(try await ActivityNotification.query(on: app.db).filter(\.$user.$id == user.requireID()).filter(\.$kind == "swap_purchase_reminder").count() == 1)
            try await user.delete(on: app.db)
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

}
