import Fluent
import Vapor

struct WebMetricsController {
    struct TrackRequest: Content { let visitorID: String; let path: String; let signedIn: Bool }
    struct Daily: Content { let date: String; let views: Int; let visitors: Int; let signups: Int }
    struct PathCount: Content { let path: String; let views: Int }
    struct Summary: Content { let days: Int; let views: Int; let visitors: Int; let signedInViews: Int; let totalAccounts: Int; let newAccounts: Int; let daily: [Daily]; let topPaths: [PathCount] }
    struct AccountDirectoryEntry: Content {
        let id: UUID
        let displayName: String?
        let email: String
        let username: String?
        let emailVerified: Bool
        let onboardingVersion: Int?
        let isPro: Bool
        let suspicious: Bool
        let createdAt: Date?
    }
    struct AccountActivity: Content {
        let userID: UUID
        let email: String
        let emailVerified: Bool
        let createdWishlists: [CreatedWishlist]
        let sentFriendRequests: [FriendRequest]
        let receivedFriendRequests: [FriendRequest]
    }
    struct CreatedWishlist: Content {
        let id: UUID
        let title: String
        let archived: Bool
        let createdAt: Date?
    }
    struct FriendRequest: Content {
        let id: UUID
        let otherUserEmail: String
        let otherUserDisplayName: String?
        let otherUsername: String?
        let status: String
        let createdAt: Date?
        let updatedAt: Date?
    }

    func track(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(TrackRequest.self)
        let visitor = body.visitorID.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = body.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard visitor.range(of: #"^[A-Za-z0-9-]{16,64}$"#, options: .regularExpression) != nil,
              path.hasPrefix("/"), path.count <= 120 else { throw Abort(.badRequest) }
        try await WebMetricEvent(visitorID: visitor, path: path, signedIn: body.signedIn).save(on: req.db)
        return .noContent
    }

    func summary(req: Request) async throws -> Summary {
        let admin = try AdminAccessService.require(req)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_metrics", targetType: "metrics")
        let days = min(max(req.query[Int.self, at: "days"] ?? 30, 1), 365)
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: Date()))!
        let events = try await WebMetricEvent.query(on: req.db).filter(\.$createdAt >= start).all()
        let totalAccounts = try await User.query(on: req.db).count()
        let recentAccounts = try await User.query(on: req.db).filter(\.$createdAt >= start).all()
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: events) { formatter.string(from: $0.createdAt ?? Date()) }
        let signups = Dictionary(grouping: recentAccounts) { formatter.string(from: $0.createdAt ?? Date()) }
        let dates = Set(grouped.keys).union(signups.keys)
        let daily = dates.map { date in
            let dayEvents = grouped[date] ?? []
            return Daily(date: date, views: dayEvents.count, visitors: Set(dayEvents.map(\.visitorID)).count, signups: signups[date]?.count ?? 0)
        }.sorted { $0.date < $1.date }
        let paths = Dictionary(grouping: events) { $0.path }.map { PathCount(path: $0.key, views: $0.value.count) }.sorted { $0.views > $1.views }.prefix(10)
        return .init(days: days, views: events.count, visitors: Set(events.map(\.visitorID)).count, signedInViews: events.filter { $0.signedIn }.count, totalAccounts: totalAccounts, newAccounts: recentAccounts.count, daily: daily, topPaths: Array(paths))
    }

    func accounts(req: Request) async throws -> [AccountDirectoryEntry] {
        let admin = try AdminAccessService.require(req)
        await AdminAuditService.record(req, adminID: try admin.requireID(), action: "view_account_directory", targetType: "accounts")
        let query = (req.query[String.self, at: "q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let limit = min(max(req.query[Int.self, at: "limit"] ?? 500, 1), 1_000)
        let accountsQuery = User.query(on: req.db)
        if !query.isEmpty {
            accountsQuery.group(.or) { matches in
                matches.filter(\.$email ~~ query)
                matches.filter(\.$displayNameSearch ~~ query)
                matches.filter(\.$username ~~ query)
            }
        }
        let accounts = try await accountsQuery
            .sort(\.$createdAt, .descending)
            .limit(limit)
            .all()
        return try accounts.map {
            let localPart = $0.email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
            let normalizedName = ($0.displayName ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
            let looksGenerated = !normalizedName.isEmpty
                && localPart.lowercased().hasPrefix(normalizedName)
                && localPart.dropFirst(normalizedName.count).contains(where: { $0.isNumber })
            return .init(id: try $0.requireID(), displayName: $0.displayName, email: $0.email, username: $0.username, emailVerified: $0.emailVerifiedAt != nil, onboardingVersion: $0.onboardingVersion, isPro: $0.hasLifetimePro, suspicious: looksGenerated, createdAt: $0.createdAt)
        }
    }

    /// Admin-only current activity for an account under review. This exposes
    /// relationships and list metadata, not any wishlist item content.
    func accountActivity(req: Request) async throws -> AccountActivity {
        let admin = try AdminAccessService.require(req)
        guard let accountID = req.parameters.get("accountID", as: UUID.self),
              let account = try await User.find(accountID, on: req.db)
        else {
            throw Abort(.notFound, reason: "That Hushful account could not be found.")
        }
        await AdminAuditService.record(
            req,
            adminID: try admin.requireID(),
            action: "view_account_activity",
            targetType: "user",
            targetID: accountID
        )

        let wishlists = try await Wishlist.query(on: req.db)
            .filter(\.$owner.$id == accountID)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
        let sent = try await Friendship.query(on: req.db)
            .filter(\.$requester.$id == accountID)
            .with(\.$recipient)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()
        let received = try await Friendship.query(on: req.db)
            .filter(\.$recipient.$id == accountID)
            .with(\.$requester)
            .sort(\.$createdAt, .descending)
            .limit(100)
            .all()

        return try .init(
            userID: accountID,
            email: account.email,
            emailVerified: account.emailVerifiedAt != nil,
            createdWishlists: wishlists.map {
                try .init(id: $0.requireID(), title: $0.title, archived: $0.isArchived, createdAt: $0.createdAt)
            },
            sentFriendRequests: try sent.map { relationship in
                try friendRequest(relationship, otherUser: relationship.recipient)
            },
            receivedFriendRequests: try received.map { relationship in
                try friendRequest(relationship, otherUser: relationship.requester)
            }
        )
    }

    private func friendRequest(_ relationship: Friendship, otherUser: User) throws -> FriendRequest {
        .init(
            id: try relationship.requireID(),
            otherUserEmail: otherUser.email,
            otherUserDisplayName: otherUser.displayName,
            otherUsername: otherUser.username,
            status: relationship.status,
            createdAt: relationship.createdAt,
            updatedAt: relationship.updatedAt
        )
    }

}
