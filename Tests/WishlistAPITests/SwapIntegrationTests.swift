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
            let accepted = try await controller.update(req: req)
            #expect(accepted.myStatus == "accepted")
            #expect(accepted.wishlist != nil)
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
            let list = try Wishlist(ownerUserId: owner.requireID(), title: "Private ideas"); list.purpose = "for_myself"; list.currencyCode = "EUR"
            try await list.save(on: app.db)
            let item = try WishlistItem(wishlistId: list.requireID(), title: "A book", url: "https://example.com/book", price: 20, ownerNote: "Paperback", quantity: 2)
            try await item.save(on: app.db)
            try await WishlistItemMembership(itemID: item.requireID(), wishlistID: list.requireID()).save(on: app.db)
            try await WishlistItemImage(itemID: item.requireID(), data: Data([4, 5, 6]), contentType: "image/jpeg").save(on: app.db)
            let swap = try HushfulSwap(ownerID: owner.requireID(), state: .init(title: "Copy", exchangeDate: "2027-12-20", currencyCode: "USD", members: [.init(userID: owner.requireID(), name: "Owner", status: "accepted")]))
            try await swap.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next()); req.auth.login(owner); req.parameters.set("swapID", to: try swap.requireID().uuidString)
            try req.content.encode(SwapUpdate(action: "wishes", wishlistID: list.requireID()))
            let copied = try await HushfulSwapController().update(req: req)
            #expect(copied.wishes.first?.title == "A book")
            #expect(copied.wishes.first?.note == "Paperback")
            #expect(copied.wishes.first?.price == 20)
            #expect(copied.wishes.first?.quantity == 2)
            #expect(copied.wishes.first?.currencyCode == "EUR")
            let copiedItemID = try #require(copied.wishes.first?.id)
            #expect(try await WishlistItemImage.query(on: app.db).filter(\.$item.$id == copiedItemID).first()?.data == Data([4, 5, 6]))
            #expect(try await WishlistViewer.query(on: app.db).filter(\.$wishlist.$id == list.requireID()).count() == 0)
            #expect(try await Wishlist.find(list.requireID(), on: app.db)?.visibility == "private")
            item.itemType = "cash_fund"; item.price = nil; item.quantity = 1; item.contributionGoal = 150
            try await item.save(on: app.db)
            do { _ = try await HushfulSwapController().update(req: req); Issue.record("Free account copied a new cash fund") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            owner.hasLifetimePro = true; try await owner.save(on: app.db)
            #expect(try await HushfulSwapController().update(req: req).wishes.first?.itemType == "cash_fund")
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

    @Test func swapWishlistsUseNormalItemCRUDAndKeepGifterReadsAnonymous() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); try await app.autoMigrate()
            let users = (0..<3).map { _ in User(email: "swap-items-\(UUID())@example.com", passwordHash: "unused") }
            for user in users { try await user.save(on: app.db) }
            var members = try users.map { try SwapMember(userID: $0.requireID(), name: "Participant", status: "accepted") }
            for i in members.indices { members[i].recipientID = members[(i + 2) % 3].id }
            let swap = try HushfulSwap(ownerID: users[0].requireID(), state: .init(title: "Our exchange", exchangeDate: "2028-12-20", currencyCode: "USD", status: "drawn", members: members))
            try await swap.save(on: app.db)
            let req = Request(application: app, on: app.eventLoopGroup.next())
            req.auth.login(users[1]); req.parameters.set("swapID", to: try swap.requireID().uuidString)
            let view = try await HushfulSwapController().detail(req: req)
            let wishlist = try #require(view.wishlist)
            let listID = try #require(wishlist.id)
            #expect(wishlist.title == "Our exchange · Swap wishlist")
            #expect(wishlist.visibility == "private")
            #expect(try await WishlistController().index(req: req).allSatisfy { $0.id != listID })
            req.parameters.set("wishlistID", to: listID.uuidString)
            let body = try JSONDecoder().decode(WishlistItemController.CreateRequest.self, from: Data(#"{"title":"Coffee grinder","url":"https://example.com/grinder","price":60,"salePrice":45,"quantity":2,"currencyCode":"EUR","ownerNote":"Blue please"}"#.utf8))
            try req.content.encode(body)
            let item = try await WishlistItemController().createForWishlist(req: req)
            try await WishlistItemImage(itemID: item.requireID(), data: Data([1, 2, 3]), contentType: "image/jpeg").save(on: app.db)
            let ownItems = try await WishlistItemController().listForWishlist(req: req)
            #expect(ownItems.contains { $0.id == item.id })
            req.auth.login(users[2])
            let gifter = try await HushfulSwapController().detail(req: req)
            let wish = try #require(gifter.recipient?.wishes.first)
            #expect(wish.title == "Coffee grinder")
            #expect(wish.id == item.id)
            #expect(wish.price == 60 && wish.salePrice == 45)
            #expect(wish.quantity == 2 && wish.currencyCode == "EUR")
            #expect(wish.note == "Blue please")
            let recipientJSON = String(decoding: try JSONEncoder().encode(gifter.recipient), as: UTF8.self)
            #expect(!recipientJSON.contains(listID.uuidString))
            req.parameters.set("itemID", to: try item.requireID().uuidString)
            #expect(try await WishlistItemImageController().show(req: req).status == .ok)
            do { _ = try await WishlistItemController().listForWishlist(req: req); Issue.record("Gifter gained owner API access") }
            catch let error as Abort { #expect(error.status == .notFound) }
            req.auth.login(users[0])
            do { _ = try await WishlistItemImageController().show(req: req); Issue.record("Organizer saw another participant’s image") }
            catch let error as Abort { #expect(error.status == .notFound) }
            #expect(try await WishlistViewer.query(on: app.db).filter(\.$wishlist.$id == listID).count() == 0)
            req.auth.login(users[1])
            let replacement = try JSONDecoder().decode(WishlistItemController.CreateRequest.self, from: Data(#"{"title":"Edited grinder","price":80,"quantity":3}"#.utf8))
            try req.content.encode(replacement)
            _ = try await WishlistItemController().replace(req: req)
            req.auth.login(users[2])
            #expect(try await HushfulSwapController().detail(req: req).recipient?.wishes.first?.title == "Edited grinder")
            req.auth.login(users[1])
            let settings = try JSONDecoder().decode(WishlistController.UpdateSettingsRequest.self, from: Data(#"{"visibility":"public"}"#.utf8))
            try req.content.encode(settings)
            do { _ = try await WishlistController().updateSettings(req: req); Issue.record("Swap wishlist became public") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            do { _ = try await OwnerShareController().createShareLink(req: req); Issue.record("Swap wishlist got a guest link") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            try req.content.encode(WishlistAudienceController.Audience(userIDs: [], groupIDs: []))
            do { _ = try await WishlistAudienceController().update(req: req); Issue.record("Swap wishlist got an ordinary audience") }
            catch let error as Abort { #expect(error.status == .forbidden) }
            _ = try await WishlistItemController().delete(req: req)
            #expect(try await HushfulSwapController().detail(req: req).wishes.isEmpty)
            for user in users { try await user.delete(on: app.db) }
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    @Test func legacySwapWishesMigrateOnceWithoutUsingFreeListCapacity() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app); try await app.autoMigrate()
            let user = User(email: "swap-migration-\(UUID())@example.com", passwordHash: "unused")
            try await user.save(on: app.db)
            let swap = try HushfulSwap(ownerID: user.requireID(), state: .init(title: "Legacy", exchangeDate: "2028-12-20", currencyCode: "USD", members: [.init(userID: user.requireID(), name: "Owner", status: "accepted", wishes: [.init(title: "Old wish", url: "https://example.com/wish", note: "Keep this")])]))
            try await swap.save(on: app.db)
            for _ in 0..<2 { try await Wishlist(ownerUserId: user.requireID(), title: "Ordinary list").save(on: app.db) }
            let req = Request(application: app, on: app.eventLoopGroup.next()); req.auth.login(user); req.parameters.set("swapID", to: try swap.requireID().uuidString)
            let first = try await HushfulSwapController().detail(req: req)
            let second = try await HushfulSwapController().detail(req: req)
            #expect(first.wishlist?.id == second.wishlist?.id)
            #expect(second.wishes.count == 1)
            #expect(second.wishes.first?.title == "Old wish")
            #expect(second.wishes.first?.note == "Keep this")
            #expect(try await Wishlist.query(on: app.db).filter(\.$swapID == swap.requireID()).count() == 1)
            try await ProAccessService.requireListCapacity(user, on: app.db)
            for list in try await Wishlist.query(on: app.db).filter(\.$owner.$id == user.requireID()).all() {
                if list.id == first.wishlist?.id { #expect(list.swapID == swap.id) }
            }
            try await user.delete(on: app.db)
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

}
