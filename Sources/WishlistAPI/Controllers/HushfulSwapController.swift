import Fluent
import SQLKit
import Vapor

struct SwapCreate: Content {
    var title: String
    var exchangeDate: String
    var priceLimit: Double?
    var currencyCode: String
    var userIDs: [UUID]
}
struct SwapUpdate: Content {
    var action: String
    var memberID: UUID?
    var wishes: [SwapWish]?
    var wishlistID: UUID?
    var reminderDays: Int?
}

struct HushfulSwapController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let swaps = routes.grouped("swaps")
        swaps.get(use: index)
        swaps.post(use: create)
        swaps.get(":swapID", use: detail)
        swaps.post(":swapID", use: update)
    }
    func index(req: Request) async throws -> [SwapView] {
        let id = try req.auth.require(User.self).requireID()
        // JSON membership is queried in PostgreSQL, so unrelated assignments are never loaded.
        guard let sql = req.db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let rows = try await sql.raw("SELECT id FROM hushful_swaps WHERE state->'members' @> \(bind: "[{\"userID\":\"\(id.uuidString)\"}]")::jsonb ORDER BY state->>'exchangeDate'").all()
        var result: [SwapView] = []
        for row in rows {
            let swapID = try row.decode(column: "id", as: UUID.self)
            if let swap = try await HushfulSwap.find(swapID, on: req.db), let i = swap.state.members.firstIndex(where: { $0.userID == id }) {
                result.append(try SwapSecurity.view(swap, memberIndex: i))
            }
        }
        return result
    }
    func create(req: Request) async throws -> SwapView {
        let user = try req.auth.require(User.self), id = try user.requireID()
        let body = try req.content.decode(SwapCreate.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, body.userIDs.count <= 99 else { throw Abort(.badRequest) }
        try ContentSafetyService.validate(title, field: "swap name")
        guard let date = SwapReminderService.date(body.exchangeDate), date > Date(), date < Date().addingTimeInterval(366 * 86400 * 3) else {
            throw Abort(.badRequest, reason: "Choose a future exchange date within three years.")
        }
        if let limit = body.priceLimit { guard limit.isFinite, limit > 0, limit <= 1_000_000 else { throw Abort(.badRequest, reason: "Enter a positive price limit.") } }
        guard let currency = try CurrencyCode.validated(body.currencyCode) else { throw Abort(.badRequest) }
        var members = [SwapMember(userID: id, name: ActivityService.actorName(for: user, fallback: "Organizer"), status: "accepted")]
        let friendships = try await Friendship.query(on: req.db).filter(\.$status == "accepted")
            .group(.or) { $0.filter(\.$requester.$id == id).filter(\.$recipient.$id == id) }.all()
        let friendIDs = Set(friendships.flatMap { [$0.$requester.id, $0.$recipient.id] }).subtracting([id])
        for friendID in Set(body.userIDs).subtracting([id]) {
            guard friendIDs.contains(friendID), try await !ProfileAccessService.isBlocked(id, friendID, on: req.db),
                  let friend = try await User.find(friendID, on: req.db) else { throw Abort(.badRequest, reason: "Choose your current friends to invite.") }
            members.append(SwapMember(userID: friendID, name: ActivityService.actorName(for: friend, fallback: "Participant")))
        }
        let swap = HushfulSwap(ownerID: id, state: .init(title: title, exchangeDate: body.exchangeDate, priceLimit: body.priceLimit, currencyCode: currency, members: members))
        let invitedMembers = Array(members.dropFirst())
        try await req.db.transaction { db in
            try await swap.save(on: db)
            for member in invitedMembers {
                if let userID = member.userID {
                    try await ActivityService.create(userID: userID, actorID: id, kind: "swap_invitation", title: "Hushful Swap invitation", message: "You’re invited to \(title). Open My Lists to respond.", on: db)
                }
            }
        }
        // Deliver after commit so notifications never refer to a rolled-back swap.
        for member in invitedMembers {
            if let userID = member.userID {
                await APNSService.send(userID: userID, kind: "swap_invitation", title: "Hushful Swap invitation", message: "Open My Lists to respond to your invitation.", actorID: id, wishlistID: nil, on: req.db, client: req.client, logger: req.logger)
                await FCMService.send(userID: userID, kind: "swap_invitation", title: "Hushful Swap invitation", message: "Open My Lists to respond to your invitation.", actorID: id, wishlistID: nil, on: req.db, client: req.client, logger: req.logger)
            }
        }
        return try SwapSecurity.view(swap, memberIndex: 0)
    }
    func detail(req: Request) async throws -> SwapView {
        let (swap, i) = try await SwapAccess.load(req, on: req.db)
        return try SwapSecurity.view(swap, memberIndex: i)
    }
    func update(req: Request) async throws -> SwapView {
        let body = try req.content.decode(SwapUpdate.self)
        let result: (SwapView, [ActivityNotification]) = try await req.db.transaction { db in
            let (swap, i) = try await SwapAccess.load(req, on: db, lock: true)
            guard swap.state.status != "cancelled" else { throw Abort(.conflict, reason: "This swap is cancelled.") }
            let myID = swap.state.members[i].id
            let admin = swap.state.members[i].userID == swap.$owner.id
            let draft = swap.state.status == "draft"
            var notifications: [ActivityNotification] = []
            switch body.action {
            case "accept", "decline":
                guard draft, !(admin && body.action == "decline") else { throw Abort(.conflict, reason: "The roster is locked.") }
                swap.state.members[i].status = body.action == "accept" ? "accepted" : "declined"
            case "wishes":
                guard swap.state.members[i].status == "accepted" else { throw Abort(.forbidden) }
                if let wishlistID = body.wishlistID {
                    let user = try req.auth.require(User.self)
                    guard let list = try await Wishlist.find(wishlistID, on: db), list.$owner.id == user.id,
                          list.purpose == "for_myself", !list.isArchived, !list.matureContentEnabled,
                          !user.isAgeRestrictedProfile,
                          try await WishlistCollaborator.query(on: db).filter(\.$wishlist.$id == wishlistID).count() == 0 else {
                        throw Abort(.badRequest, reason: "Choose a personal, non-mature wishlist owned only by you.")
                    }
                    let links = try await WishlistItemMembership.query(on: db).filter(\.$wishlist.$id == wishlistID).with(\.$item).all()
                    swap.state.members[i].wishes = try Self.cleanWishes(links.prefix(100).map { .init(title: $0.item.title, url: $0.item.url, note: $0.item.ownerNote) })
                } else { swap.state.members[i].wishes = try Self.cleanWishes(body.wishes ?? []) }
            case "reminder":
                guard swap.state.members[i].userID != nil, swap.state.members[i].status == "accepted" else { throw Abort(.badRequest, reason: "Purchase push reminders require a Hushful account.") }
                if let days = body.reminderDays { guard (0...365).contains(days) else { throw Abort(.badRequest, reason: "Choose 0–365 days before the exchange.") } }
                swap.state.members[i].reminderDays = body.reminderDays
            case "remove":
                guard admin, draft, let memberID = body.memberID, memberID != swap.state.members[i].id else { throw Abort(.forbidden) }
                swap.state.members.removeAll { $0.id == memberID }
            case "draw":
                guard admin, draft, swap.state.members.allSatisfy({ $0.status == "accepted" }),
                      let date = SwapReminderService.date(swap.state.exchangeDate), date > Date() else {
                    throw Abort(.conflict, reason: "Everyone must accept before you draw. Remove declined invitations first.")
                }
                for member in swap.state.members {
                    if let userID = member.userID, try await User.find(userID, on: db) == nil {
                        throw Abort(.conflict, reason: "A participant deleted their account. Remove them before drawing.")
                    }
                }
                let assignment = try SwapSecurity.draw(swap.state.members.map(\.id))
                for j in swap.state.members.indices { swap.state.members[j].recipientID = assignment[swap.state.members[j].id] }
                swap.state.status = "drawn"
                for member in swap.state.members {
                    if let userID = member.userID {
                        let notification = ActivityNotification(userID: userID, kind: "swap_drawn", title: "Your recipient is ready", message: "Your Hushful Swap has been drawn. Open My Lists to see your recipient.")
                        try await notification.save(on: db)
                        notifications.append(notification)
                    }
                }
            case "cancel":
                guard admin else { throw Abort(.forbidden) }
                swap.state.status = "cancelled"
                for j in swap.state.members.indices { swap.state.members[j].recipientID = nil }
            case "remind":
                guard admin, draft, let memberID = body.memberID,
                      let j = swap.state.members.firstIndex(where: { $0.id == memberID }),
                      swap.state.members[j].status == "pending", let userID = swap.state.members[j].userID else { throw Abort(.badRequest) }
                guard swap.state.members[j].lastReminder.map({ Date().timeIntervalSince($0) >= 86400 }) ?? true else {
                    throw Abort(.tooManyRequests, reason: "You can remind each person once every 24 hours.")
                }
                guard try await !ProfileAccessService.isBlocked(swap.$owner.id, userID, on: db) else { throw Abort(.forbidden) }
                swap.state.members[j].lastReminder = Date()
                let notification = ActivityNotification(userID: userID, actorID: swap.$owner.id, kind: "swap_invitation", title: "Your Hushful Swap is waiting", message: "Please respond to your invitation in My Lists.")
                try await notification.save(on: db)
                notifications.append(notification)
            default: throw Abort(.badRequest)
            }
            try await swap.save(on: db)
            let newIndex = swap.state.members.firstIndex { $0.id == myID } ?? i
            return (try SwapSecurity.view(swap, memberIndex: newIndex), notifications)
        }
        for notification in result.1 {
            await ActivityService.sendPush(notification, on: req.db, client: req.client, logger: req.logger)
        }
        return result.0
    }
    static func cleanWishes(_ wishes: [SwapWish]) throws -> [SwapWish] {
        guard wishes.count <= 100 else { throw Abort(.badRequest) }
        return try wishes.map { wish in
            let title = wish.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 200, (wish.note?.count ?? 0) <= 2000 else { throw Abort(.badRequest, reason: "Add a short gift title and a note under 2,000 characters.") }
            try ContentSafetyService.validate(title, field: "gift title")
            if let note = wish.note { try ContentSafetyService.validate(note, field: "gift note") }
            if let url = wish.url, !url.isEmpty {
                guard url.count <= 2048, let parsed = URL(string: url), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { throw Abort(.badRequest, reason: "Gift links must start with https:// or http://.") }
            }
            return .init(title: title, url: wish.url, note: wish.note)
        }
    }
}

enum SwapAccess {
    static func load(_ req: Request, on db: any Database, lock: Bool = false) async throws -> (HushfulSwap, Int) {
        guard let id = req.parameters.get("swapID", as: UUID.self) else { throw Abort(.notFound) }
        if lock {
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM hushful_swaps WHERE id = \(bind: id) FOR UPDATE").run()
        }
        guard let swap = try await HushfulSwap.find(id, on: db) else { throw Abort(.notFound) }
        let userID = req.auth.get(User.self)?.id
        let guestHash = req.headers.first(name: "X-Swap-Key").map(SwapSecurity.hash)
        guard let i = swap.state.members.firstIndex(where: {
            (userID != nil && $0.userID == userID) || (guestHash != nil && $0.guestHash == guestHash)
        }) else { throw Abort(.notFound) }
        return (swap, i)
    }
}

struct SwapGuestController: RouteCollection {
    struct Preview: Content { var title: String; var exchangeDate: String; var status: String }
    struct Join: Content { var name: String }
    struct Joined: Content { var swap: SwapView; var guestKey: String? }
    func boot(routes: any RoutesBuilder) throws {
        routes.get("swap-invites", ":invite", use: preview)
        routes.post("swap-invites", ":invite", use: join)
        // Same handlers with participant-specific guest credentials, never the invitation token.
        routes.get("guest-swaps", ":swapID", use: HushfulSwapController().detail)
        routes.post("guest-swaps", ":swapID", use: HushfulSwapController().update)
    }
    private func find(_ req: Request, on db: any Database) async throws -> HushfulSwap {
        guard let token = req.parameters.get("invite"), token.count == 64,
              let swap = try await HushfulSwap.query(on: db).filter(\.$inviteToken == token).first() else { throw Abort(.notFound) }
        return swap
    }
    func preview(req: Request) async throws -> Preview {
        let swap = try await find(req, on: req.db)
        return .init(title: swap.state.title, exchangeDate: swap.state.exchangeDate, status: swap.state.status)
    }
    func join(req: Request) async throws -> Joined {
        let body = try req.content.decode(Join.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw Abort(.badRequest) }
        try ContentSafetyService.validate(name, field: "participant name")
        return try await req.db.transaction { db in
            let initial = try await find(req, on: db)
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("SELECT id FROM hushful_swaps WHERE id = \(bind: initial.requireID()) FOR UPDATE").run()
            guard let swap = try await HushfulSwap.find(initial.requireID(), on: db) else { throw Abort(.notFound) }
            guard swap.state.status == "draft", let date = SwapReminderService.date(swap.state.exchangeDate), date > Date() else { throw Abort(.conflict, reason: "This swap is no longer accepting participants.") }
            let user = req.auth.get(User.self)
            if let userID = user?.id, let i = swap.state.members.firstIndex(where: { $0.userID == userID }) {
                return .init(swap: try SwapSecurity.view(swap, memberIndex: i), guestKey: nil)
            }
            guard swap.state.members.count < 100 else { throw Abort(.conflict, reason: "This swap is full.") }
            if let userID = user?.id { guard try await !ProfileAccessService.isBlocked(swap.$owner.id, userID, on: db) else { throw Abort(.forbidden) } }
            let key = user == nil ? SwapSecurity.token() : nil
            swap.state.members.append(.init(userID: user?.id, name: user.map { ActivityService.actorName(for: $0, fallback: name) } ?? name, status: "accepted", guestHash: key.map(SwapSecurity.hash)))
            try await swap.save(on: db)
            return .init(swap: try SwapSecurity.view(swap, memberIndex: swap.state.members.count - 1), guestKey: key)
        }
    }
}
