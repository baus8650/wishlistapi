import Fluent
import Vapor

enum AdminAccessService {
    static func isAdmin(_ user: User) -> Bool {
        let configuredEmails = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return user.role == "admin" || configuredEmails.contains(user.email.lowercased())
    }

    static func require(_ req: Request) throws -> User {
        let user = try req.auth.require(User.self)
        guard isAdmin(user) else {
            throw Abort(.forbidden)
        }
        guard !user.adminTOTPEnabled || req.storage[AdminMFAStorageKey.self] == true else {
            throw Abort(.unauthorized, reason: "Admin verification required. Enter your authenticator code when signing in.")
        }
        return user
    }

    static func all(_ db: any Database) async throws -> [User] {
        let configuredEmails = Set((Environment.get("METRICS_ADMIN_EMAILS") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return try await User.query(on: db).all().filter {
            $0.role == "admin" || configuredEmails.contains($0.email.lowercased())
        }
    }
}

struct AdminMFAStorageKey: StorageKey {
    typealias Value = Bool
}
