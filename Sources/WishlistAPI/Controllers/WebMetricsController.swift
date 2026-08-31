import Fluent
import Vapor

struct WebMetricsController {
    struct TrackRequest: Content { let visitorID: String; let path: String; let signedIn: Bool }
    struct Daily: Content { let date: String; let views: Int; let visitors: Int; let signups: Int }
    struct PathCount: Content { let path: String; let views: Int }
    struct Summary: Content { let days: Int; let views: Int; let visitors: Int; let signedInViews: Int; let totalAccounts: Int; let newAccounts: Int; let daily: [Daily]; let topPaths: [PathCount] }

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
        let user = try req.auth.require(User.self)
        let allowed = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        guard allowed.contains(user.email.lowercased()) else { throw Abort(.forbidden) }
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
}
