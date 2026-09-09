import Foundation
import Fluent
import Vapor

enum MentionService {
    private static let mentionPattern = #"(?<![A-Za-z0-9_])@([A-Za-z0-9_]{3,30})\b"#

    static func usernames(in text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: mentionPattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).lowercased()
        })
    }

    /// Returns the account-linked people who can participate in this list's
    /// shared recipient experience. Viewer rows are the source of truth for
    /// both public lists that have been opened and privately shared lists.
    static func candidates(
        for wishlistID: UUID,
        excluding actorID: UUID? = nil,
        on db: any Database
    ) async throws -> [SocialUserDTO] {
        let viewers = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .with(\.$user)
            .all()

        return viewers.compactMap { viewer in
            guard let user = viewer.user,
                  let id = user.id,
                  id != actorID,
                  let username = user.username,
                  !username.isEmpty else { return nil }
            return SocialUserDTO(
                id: id,
                username: username,
                displayName: user.displayName,
                hasAvatar: user.avatarData != nil
            )
        }
        .reduce(into: [UUID: SocialUserDTO]()) { result, candidate in
            result[candidate.id] = candidate
        }
        .values
        .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }

    /// Rejects a mention of a known user who cannot access the list. Unknown
    /// @words remain ordinary text, while known users must be authorized.
    static func validateMentions(
        in text: String,
        wishlistID: UUID,
        actorID: UUID?,
        on db: any Database
    ) async throws {
        let mentionedNames = usernames(in: text)
        guard !mentionedNames.isEmpty else { return }

        let mentionedUsers = try await User.query(on: db).all().filter { user in
            guard let username = user.username else { return false }
            return mentionedNames.contains(username.lowercased())
        }
        guard !mentionedUsers.isEmpty else { return }

        let mentionedIDs = Set(mentionedUsers.compactMap(\.id))
        let viewers = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id ~~ Array(mentionedIDs))
            .all()
        let eligibleIDs = Set(viewers.compactMap { $0.$user.id }).subtracting(actorID.map { [$0] } ?? [])
        try validateMentionedUsers(mentionedUsers, against: eligibleIDs, actorID: actorID)
    }

    static func validateMentions(
        in text: String,
        allowedUserIDs: Set<UUID>,
        actorID: UUID?,
        on db: any Database
    ) async throws {
        let mentionedNames = usernames(in: text)
        guard !mentionedNames.isEmpty else { return }

        let mentionedUsers = try await User.query(on: db).all().filter { user in
            guard let username = user.username else { return false }
            return mentionedNames.contains(username.lowercased())
        }
        guard !mentionedUsers.isEmpty else { return }

        try validateMentionedUsers(
            mentionedUsers,
            against: allowedUserIDs.subtracting(actorID.map { [$0] } ?? []),
            actorID: actorID
        )
    }

    private static func validateMentionedUsers(
        _ mentionedUsers: [User],
        against eligibleIDs: Set<UUID>,
        actorID: UUID?
    ) throws {
        let inaccessible = mentionedUsers.filter { user in
            guard let id = user.id else { return false }
            return !eligibleIDs.contains(id)
        }
        guard inaccessible.isEmpty else {
            throw Abort(.forbidden, reason: "You can only mention people who can access this list.")
        }
    }

    static func notifyNewMentions(
        in text: String,
        previousText: String? = nil,
        wishlistID: UUID,
        actorID: UUID?,
        actorName: String,
        context: String,
        eligibleUserIDs: Set<UUID>? = nil,
        on db: any Database,
        client: any Client,
        logger: Logger
    ) async throws {
        let mentionedNames = usernames(in: text)
        let previousNames = usernames(in: previousText ?? "")
        let newNames = mentionedNames.subtracting(previousNames)
        guard !newNames.isEmpty else { return }

        var mentionedUsers: [User] = []
        for username in newNames {
            if let user = try await User.query(on: db)
                .filter(\.$username == username)
                .first() {
                mentionedUsers.append(user)
            }
        }
        guard !mentionedUsers.isEmpty else { return }

        let userIDs = Set(mentionedUsers.compactMap(\.id))
        let eligibleIDs: Set<UUID>
        if let eligibleUserIDs {
            eligibleIDs = userIDs.intersection(eligibleUserIDs).filter { $0 != actorID }
        } else {
            let viewers = try await WishlistViewer.query(on: db)
                .filter(\.$wishlist.$id == wishlistID)
                .filter(\.$user.$id ~~ Array(userIDs))
                .all()
            eligibleIDs = Set(viewers.compactMap { $0.$user.id }).filter { $0 != actorID }
        }
        guard !eligibleIDs.isEmpty else { return }

        let message = "\(actorName) mentioned you \(context)"
        for userID in eligibleIDs {
            try await ActivityService.create(
                userID: userID,
                actorID: actorID,
                wishlistID: wishlistID,
                kind: "wishlist_mention",
                title: "You were mentioned",
                message: message,
                on: db,
                client: client,
                logger: logger
            )
        }
    }
}
