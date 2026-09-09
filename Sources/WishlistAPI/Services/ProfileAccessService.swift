import Fluent

enum ProfileAccessService {
    static func areFriends(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        try await Friendship.query(on: db)
            .group(.or) { group in
                group.group(.and) { $0.filter(\.$requester.$id == first).filter(\.$recipient.$id == second) }
                group.group(.and) { $0.filter(\.$requester.$id == second).filter(\.$recipient.$id == first) }
            }
            .filter(\.$status == "accepted")
            .first() != nil
    }

    static func isBlocked(_ first: UUID, _ second: UUID, on db: any Database) async throws -> Bool {
        try await UserBlock.query(on: db)
            .group(.or) { group in
                group.group(.and) { $0.filter(\.$blocker.$id == first).filter(\.$blocked.$id == second) }
                group.group(.and) { $0.filter(\.$blocker.$id == second).filter(\.$blocked.$id == first) }
            }
            .first() != nil
    }

    static func canViewProfile(viewerID: UUID, target: User, on db: any Database) async throws -> Bool {
        guard let targetID = target.id, viewerID != targetID else { return true }
        guard try await !isBlocked(viewerID, targetID, on: db) else { return false }
        return target.isDiscoverable || (try await areFriends(viewerID, targetID, on: db))
    }

    static func canViewBirthday(viewerID: UUID, target: User, on db: any Database) async throws -> Bool {
        guard let targetID = target.id else { return false }
        guard target.birthdayMonth != nil, target.birthdayDay != nil else { return false }
        guard viewerID == targetID || try await canViewProfile(viewerID: viewerID, target: target, on: db) else { return false }
        switch target.birthdayVisibility {
        case "public": return true
        case "friends": return viewerID == targetID || (try await areFriends(viewerID, targetID, on: db))
        default: return viewerID == targetID
        }
    }

    static func canViewAttribute(_ attribute: UserProfileAttribute, viewerID: UUID, target: User, on db: any Database) async throws -> Bool {
        guard let targetID = target.id else { return false }
        if viewerID == targetID { return true }
        guard try await canViewProfile(viewerID: viewerID, target: target, on: db) else { return false }
        switch attribute.visibility {
        case "public": return true
        case "friends": return try await areFriends(viewerID, targetID, on: db)
        default: return false
        }
    }
}
