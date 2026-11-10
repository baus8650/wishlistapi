import Fluent
import SQLKit
import Vapor

struct AnnouncementInput: Content {
    let id: UUID
    let title: String
    let message: String

    func validated() throws -> (String, String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 80, !message.isEmpty, message.count <= 500 else {
            throw Abort(.badRequest, reason: "Enter a title of 1–80 characters and a message of 1–500 characters.")
        }
        return (title, message)
    }
}

struct AnnouncementResponse: Content {
    let id: UUID
    let title: String
    let message: String
    let recipientCount: Int
    let pendingCount: Int
    let createdAt: Date?
}

struct AnnouncementPreference: Content { let enabled: Bool }
struct AnnouncementAudience: Content { let users: Int; let pushUsers: Int }

struct AnnouncementController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("me", "announcement-preference", use: preference)
        routes.put("me", "announcement-preference", use: updatePreference)
        routes.get("admin", "announcements", use: list)
        routes.get("admin", "announcements", "audience", use: audience)
        routes.post("admin", "announcements", "test", use: test)
        routes.post("admin", "announcements", use: send)
    }
    func preference(req: Request) throws -> AnnouncementPreference {
        .init(enabled: try req.auth.require(User.self).announcementPushEnabled == true)
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
        return .init(id: id, title: item.title, message: item.message, recipientCount: item.recipientCount, pendingCount: pending, createdAt: item.createdAt)
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
        let users = try await User.query(on: req.db).filter(\.$emailVerifiedAt != nil).filter(\.$suspendedAt == nil).all()
        let devices = Set(try await PushDevice.query(on: req.db).all().map { $0.$user.id })
        return .init(users: users.count, pushUsers: users.filter { $0.announcementPushEnabled == true && devices.contains($0.id!) }.count)
    }
    func test(req: Request) async throws -> HTTPStatus {
        let admin = try AdminAccessService.require(req)
        let input = try req.content.decode(AnnouncementInput.self)
        let (title, message) = try input.validated()
        let id = try admin.requireID()
        guard try await PushDevice.query(on: req.db).filter(\.$user.$id == id).count() > 0 else {
            throw Abort(.badRequest, reason: "Enable push notifications on your device before sending a test.")
        }
        // An explicit test request sends only to the administrator's devices.
        let notification = ActivityNotification(userID: id, kind: "announcement_test", title: "[Test] " + title, message: message)
        await ActivityService.sendPush(notification, on: req.db, client: req.client, logger: req.logger)
        return .noContent
    }
    func send(req: Request) async throws -> AnnouncementResponse {
        let adminID = try AdminAccessService.require(req).requireID()
        let input = try req.content.decode(AnnouncementInput.self)
        let (title, message) = try input.validated()
        let item: Announcement = try await req.db.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Serialize retries of this request, including concurrent requests.
            try await sql.raw("SELECT pg_advisory_xact_lock(hashtext(\(bind: input.id.uuidString)))").run()
            if let existing = try await Announcement.find(input.id, on: db) {
                guard existing.title == title, existing.message == message, existing.$admin.id == adminID else {
                    throw Abort(.conflict, reason: "This announcement ID has already been used.")
                }
                return existing
            }
            let users = try await User.query(on: db).filter(\.$emailVerifiedAt != nil).filter(\.$suspendedAt == nil).all()
            let item = Announcement(id: input.id, title: title, message: message, adminID: adminID, recipientCount: users.count)
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
                    if user.announcementPushEnabled == true {
                        await ActivityService.sendPush(notification, on: tx, client: client, logger: logger)
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
