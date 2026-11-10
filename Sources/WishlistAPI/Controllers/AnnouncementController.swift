import Fluent
import SQLKit
import Vapor

struct AnnouncementInput: Content {
    let id: UUID
    let title: String
    let message: String
    var pushBody: String? = nil
    var userIDs: [UUID]? = nil

    func validated() throws -> (String, String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, !message.isEmpty, message.count <= (pushBody == nil ? 500 : 10000) else {
            throw Abort(.badRequest, reason: "Enter a title of 1–80 characters and announcement text of 1–10,000 characters.")
        }
        _ = try validatedPushBody()
        return (title, message)
    }
    func validatedPushBody() throws -> String {
        let text = (pushBody ?? message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500 else {
            throw Abort(.badRequest, reason: "Enter push notification text of 1–500 characters.")
        }
        return text
    }
}

struct AnnouncementResponse: Content {
    let id: UUID
    let title: String
    let message: String
    let recipientCount: Int
    let pushBody: String?
    let pendingCount: Int
    let audience: String
    let createdAt: Date?
}

struct AnnouncementCard: Content {
    let id: UUID
    let title: String
    let message: String
    let createdAt: Date?
}

struct AnnouncementPreference: Content { let enabled: Bool }
struct AnnouncementSelection: Content { var userIDs: [UUID]? = nil }
struct AnnouncementAudience: Content { let users: Int; let pushUsers: Int }

struct AnnouncementController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("announcements", use: cards)
        routes.post("announcements", ":announcementID", "dismiss", use: dismiss)
        routes.get("me", "announcement-preference", use: preference)
        routes.put("me", "announcement-preference", use: updatePreference)
        routes.get("admin", "announcements", use: list)
        routes.get("admin", "announcements", "audience", use: audience)
        routes.post("admin", "announcements", "audience", use: selectedAudience)
        routes.post("admin", "announcements", "test", use: test)
        routes.post("admin", "announcements", use: send)
    }
    func cards(req: Request) async throws -> [AnnouncementCard] {
        let userID = try req.auth.require(User.self).requireID()
        let deliveries = try await AnnouncementDelivery.query(on: req.db)
            .filter(\.$user.$id == userID).filter(\.$dismissedAt == nil)
            .join(Announcement.self, on: \AnnouncementDelivery.$announcement.$id == \Announcement.$id)
            .sort(Announcement.self, \.$createdAt, .descending)
            .with(\.$announcement).limit(50).all()
        return try deliveries.map { delivery in
            let item = delivery.announcement
            return AnnouncementCard(id: try item.requireID(), title: item.title, message: item.message, createdAt: item.createdAt)
        }
    }
    func dismiss(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        guard let id = req.parameters.get("announcementID", as: UUID.self),
              let delivery = try await AnnouncementDelivery.query(on: req.db)
                .filter(\.$user.$id == userID).filter(\.$announcement.$id == id).first() else {
            throw Abort(.notFound)
        }
        delivery.dismissedAt = delivery.dismissedAt ?? Date()
        try await delivery.save(on: req.db)
        return .noContent
    }
    func preference(req: Request) throws -> AnnouncementPreference {
        .init(enabled: try req.auth.require(User.self).announcementPushEnabled != false)
    }
    func updatePreference(req: Request) async throws -> AnnouncementPreference {
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(AnnouncementPreference.self)
        user.announcementPushEnabled = body.enabled
        try await user.save(on: req.db)
        return body
    }
    func response(_ item: Announcement, db: any Database) async throws -> AnnouncementResponse {
        let id = try item.requireID()
        let pending = try await AnnouncementDelivery.query(on: db).filter(\.$announcement.$id == id).filter(\.$processed == false).count()
        return .init(id: id, title: item.title, message: item.message, recipientCount: item.recipientCount, pushBody: item.pushBody ?? item.message, pendingCount: pending, audience: item.recipientIDs == nil ? "everyone" : "selected", createdAt: item.createdAt)
    }
    func list(req: Request) async throws -> [AnnouncementResponse] {
        _ = try AdminAccessService.require(req)
        var result: [AnnouncementResponse] = []
        for item in try await Announcement.query(on: req.db).sort(\.$createdAt, .descending).limit(100).all() {
            result.append(try await response(item, db: req.db))
        }
        return result
    }
    func audience(req: Request) async throws -> AnnouncementAudience {
        _ = try AdminAccessService.require(req)
        return try await audienceResponse(userIDs: nil, db: req.db)
    }
    func selectedAudience(req: Request) async throws -> AnnouncementAudience {
        _ = try AdminAccessService.require(req)
        let body = try req.content.decode(AnnouncementSelection.self)
        return try await audienceResponse(userIDs: body.userIDs, db: req.db)
    }
    func eligibleUsers(userIDs: [UUID]?, db: any Database) async throws -> [User] {
        let query = User.query(on: db).filter(\.$emailVerifiedAt != nil).filter(\.$suspendedAt == nil)
        if let userIDs {
            let ids = Set(userIDs)
            guard !ids.isEmpty, ids.count <= 1000 else { throw Abort(.badRequest, reason: "Select between 1 and 1,000 accounts.") }
            let users = try await query.filter(\.$id ~~ Array(ids)).all()
            guard users.count == ids.count else { throw Abort(.badRequest, reason: "Some selected accounts are unavailable, unverified, or suspended. Update your selection.") }
            return users
        }
        return try await query.all()
    }
    func audienceResponse(userIDs: [UUID]?, db: any Database) async throws -> AnnouncementAudience {
        let users = try await eligibleUsers(userIDs: userIDs, db: db)
        let devices = Set(try await PushDevice.query(on: db).all().map { $0.$user.id })
        return .init(users: users.count, pushUsers: users.filter { $0.announcementPushEnabled != false && devices.contains($0.id!) }.count)
    }
    func test(req: Request) async throws -> HTTPStatus {
        let admin = try AdminAccessService.require(req)
        let input = try req.content.decode(AnnouncementInput.self)
        let (title, message) = try input.validated()
        let pushBody = try input.validatedPushBody()
        let id = try admin.requireID()
        guard try await PushDevice.query(on: req.db).filter(\.$user.$id == id).count() > 0 else {
            throw Abort(.badRequest, reason: "Enable push notifications on your device before sending a test.")
        }
        // Give each preview its own ID so testing a draft never consumes its
        // broadcast ID. Commit the card and Activity entry before sending push.
        let notification = try await req.db.transaction { db in
            let previewID = UUID()
            let previewTitle = "[Test] " + title
            let preview = Announcement(id: previewID, title: previewTitle, message: message, adminID: id, recipientCount: 1, recipientIDs: [id], pushBody: pushBody)
            try await preview.create(on: db)
            let delivery = AnnouncementDelivery(announcementID: previewID, userID: id)
            delivery.processed = true
            try await delivery.create(on: db)
            let notification = ActivityNotification(userID: id, kind: "announcement", title: previewTitle, message: message)
            try await notification.create(on: db)
            return notification
        }
        await AdminAuditService.record(req, adminID: id, action: "test_announcement", targetType: "announcement")
        await ActivityService.sendPush(notification, pushMessage: pushBody, on: req.db, client: req.client, logger: req.logger)
        return .noContent
    }
    func send(req: Request) async throws -> AnnouncementResponse {
        let adminID = try AdminAccessService.require(req).requireID()
        let input = try req.content.decode(AnnouncementInput.self)
        let (title, message) = try input.validated()
        let pushBody = try input.validatedPushBody()
        let item: Announcement = try await req.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Serialize retries of this request, including concurrent requests.
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: input.id.uuidString)))").run()
            if let existing = try await Announcement.find(input.id, on: db) {
                guard existing.title == title, existing.message == message, (existing.pushBody ?? existing.message) == pushBody, existing.$admin.id == adminID,
                      existing.recipientIDs.map(Set.init) == input.userIDs.map(Set.init) else {
                    throw Abort(.conflict, reason: "This announcement ID has already been used.")
                }
                return existing
            }
            let users = try await eligibleUsers(userIDs: input.userIDs, db: db)
            let item = Announcement(id: input.id, title: title, message: message, adminID: adminID, recipientCount: users.count, recipientIDs: input.userIDs.map { Array(Set($0)) }, pushBody: pushBody)
            try await item.create(on: db)
            for user in users {
                try await AnnouncementDelivery(announcementID: input.id, userID: try user.requireID()).create(on: db)
            }
            return item
        }
        await AdminAuditService.record(req, adminID: adminID, action: "send_announcement", targetType: "announcement", targetID: input.id)
        return try await response(item, db: req.db)
    }
}

// Durable delivery rows survive restarts and keep broadcasts out of HTTP requests.
enum AnnouncementService {
    static func schedule(on app: Application) {
        _ = app.eventLoopGroup.next().scheduleRepeatedTask(initialDelay: .seconds(15), delay: .seconds(10)) { _ in
            Task {
                do { try await process(on: app.db, client: app.client, logger: app.logger) }
                catch { app.logger.error("Announcement processing failed: \(error)") }
            }
        }
    }
    static func process(on db: any Database, client: any Client, logger: Logger) async throws {
        // Bound work per tick. Row locks allow multiple API instances to cooperate.
        for _ in 0..<25 {
            let found = try await db.transaction { tx -> Bool in
                guard let sql = tx as? any SQLDatabase else { return false }
                let rows = try await sql.raw("SELECT id FROM announcement_deliveries WHERE processed = false ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1").all()
                guard let row = rows.first else { return false }
                let id = try row.decode(column: "id", as: UUID.self)
                guard let delivery = try await AnnouncementDelivery.find(id, on: tx) else { return false }
                let user = try await delivery.$user.get(on: tx)
                if user.suspendedAt == nil, user.emailVerifiedAt != nil {
                    let item = try await delivery.$announcement.get(on: tx)
                    let notification = ActivityNotification(userID: try user.requireID(), kind: "announcement", title: item.title, message: item.message)
                    try await notification.save(on: tx)
                    // Recheck consent at delivery time. Other notification types are unaffected.
                    if user.announcementPushEnabled != false, delivery.dismissedAt == nil {
                        await ActivityService.sendPush(notification, pushMessage: item.pushBody ?? item.message, on: tx, client: client, logger: logger)
                    }
                }
                delivery.processed = true
                try await delivery.save(on: tx)
                return true
            }
            if !found { break }
        }
    }
}
