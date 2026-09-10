import Fluent

/// Keeps the denormalized `users.has_lifetime_pro` flag in sync with every
/// supported entitlement source.
enum ProEntitlementService {
    @discardableResult
    static func refresh(_ user: User, on database: any Database) async throws -> Bool {
        let userID = try user.requireID()
        let appleEntitled = try await AppleProPurchase.query(on: database)
            .filter(\.$user.$id == userID)
            .filter(\.$active == true)
            .count() > 0
        let googleEntitled = try await GooglePlayProPurchase.query(on: database)
            .filter(\.$user.$id == userID)
            .filter(\.$active == true)
            .count() > 0
        let manualEntitled = try await AdminProGrant.query(on: database)
            .filter(\.$user.$id == userID)
            .filter(\.$active == true)
            .count() > 0

        user.hasLifetimePro = appleEntitled || googleEntitled || manualEntitled
        try await user.save(on: database)
        return user.hasLifetimePro
    }
}
