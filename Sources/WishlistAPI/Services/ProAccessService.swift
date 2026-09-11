import Fluent
import Vapor

/// The same account entitlement and free limit apply to every client.
enum ProAccessService {
    static let freeListLimit = 3
    static func requirePro(_ user: User) throws {
        guard user.hasLifetimePro else {
            throw Abort(.forbidden, reason: "This feature requires Hushful Pro. Upgrade in a supported Hushful mobile app. Web payments are not available.")
        }
    }
    static func requireListCapacity(_ user: User, on database: any Database) async throws {
        guard !user.hasLifetimePro else { return }
        let count = try await Wishlist.query(on: database)
            .filter(\.$owner.$id == user.requireID()).filter(\.$isArchived == false).count()
        guard count < freeListLimit else {
            throw Abort(.forbidden, reason: "Free accounts can have up to three active wishlists. Hushful Pro unlocks unlimited lists.")
        }
    }
}
