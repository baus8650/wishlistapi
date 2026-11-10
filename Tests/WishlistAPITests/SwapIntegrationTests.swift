@testable import WishlistAPI
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Hushful Swap integration", .serialized)
struct SwapIntegrationTests {
    @Test func invitationsGuestsDrawPrivacyAndLockedRoster() async throws {
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
            let date = "2027-12-20"
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
            let guestReq = Request(application: app, on: app.eventLoopGroup.next())
            guestReq.parameters.set("invite", to: invite)
            try guestReq.content.encode(SwapGuestController.Join(name: "Guest one"))
            let guest = try await SwapGuestController().join(req: guestReq)
            let key = try #require(guest.guestKey)
            try guestReq.content.encode(SwapGuestController.Join(name: "Guest two"))
            let guestTwo = try await SwapGuestController().join(req: guestReq)
            #expect(guestTwo.guestKey != key)
            guestReq.parameters.set("swapID", to: created.id.uuidString)
            // Public invitation links cannot authenticate a participant or reveal assignments.
            guestReq.headers.replaceOrAdd(name: "X-Swap-Key", value: invite)
            do { _ = try await controller.detail(req: guestReq); Issue.record("Invite token acted as private credential") }
            catch let error as Abort { #expect(error.status == .notFound) }
            guestReq.headers.replaceOrAdd(name: "X-Swap-Key", value: key)
            try guestReq.content.encode(SwapUpdate(action: "wishes", wishes: [.init(title: "A guest gift")]))
            #expect(try await controller.update(req: guestReq).wishes.first?.title == "A guest gift")
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
            let guestView = try await controller.detail(req: guestReq)
            #expect(guestView.recipient != nil)
            #expect(guestView.isAdmin == false)
            let json = String(decoding: try JSONEncoder().encode(drawn), as: UTF8.self)
            #expect(!json.contains(key))
            #expect(!json.contains("recipientID"))
            #expect(!json.contains("guestHash"))
            // The guest key works over the actual unauthenticated HTTP route too.
            let response = try await app.testing().sendRequest(.GET, "/v1/guest-swaps/\(created.id)", headers: ["X-Swap-Key": key])
            #expect(response.status == .ok)
            let unauthorized = try await app.testing().sendRequest(.GET, "/v1/guest-swaps/\(created.id)")
            #expect(unauthorized.status == .notFound)
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
            do { _ = try await HushfulSwapController().update(req: req); Issue.record("Mature list was shared with unverified guests") }
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
