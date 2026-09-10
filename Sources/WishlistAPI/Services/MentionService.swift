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

    /// Returns people who are eligible to be mentioned in a shared wishlist.
    /// Public lists use accepted friends of the owner and collaborators;
    /// private lists use explicit recipient access and collaborators.
    static func candidates(
        for wishlistID: UUID,
        excluding actorID: UUID? = nil,
        on db: any Database
    ) async throws -> [SocialUserDTO] {
        let eligibleIDs = try await eligibleUserIDs(for: wishlistID, on: db)
            .subtracting(actorID.map { [$0] } ?? [])
        return try await users(for: eligibleIDs, on: db)
    }

    /// Returns account IDs that can be mentioned for this wishlist. The
    /// primary owner is intentionally excluded from the result.
    static func eligibleUserIDs(
        for wishlistID: UUID,
        on db: any Database
    ) async throws -> Set<UUID> {
        guard let wishlist = try await Wishlist.find(wishlistID, on: db) else { return [] }
        let ownerID = try await wishlist.$owner.get(on: db).requireID()
        let collaboratorIDs = Set(try await WishlistCollaborator.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .all()
            .map(\.$user.id))

        var eligibleIDs = collaboratorIDs
        if wishlist.visibility == "public" {
            for principalID in collaboratorIDs.union([ownerID]) {
                eligibleIDs.formUnion(try await acceptedFriendIDs(for: principalID, on: db))
            }
        } else {
            // A linked viewer may have received access through an explicit
            // audience grant or through an authenticated share link.
            let viewerIDs = try await WishlistViewer.query(on: db)
                .filter(\.$wishlist.$id == wishlistID)
                .all()
                .compactMap(\.$user.id)
            eligibleIDs.formUnion(viewerIDs)
        }

        eligibleIDs.remove(ownerID)
        let owner = try await wishlist.$owner.get(on: db)
        var filtered = Set<UUID>()
        for userID in eligibleIDs {
            guard let user = try await User.find(userID, on: db),
                  try await !ProfileAccessService.isBlocked(ownerID, userID, on: db) else { continue }
            if wishlist.matureContentEnabled || owner.isAgeRestrictedProfile {
                guard user.derivedAgeBand == "adult" else { continue }
            }
            filtered.insert(userID)
        }
        return filtered
    }

    static func collaborativeCandidates(
        for wishlistID: UUID,
        excluding actorID: UUID? = nil,
        on db: any Database
    ) async throws -> [SocialUserDTO] {
        try await candidates(for: wishlistID, excluding: actorID, on: db)
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
        let eligibleIDs = (try await eligibleUserIDs(for: wishlistID, on: db))
            .intersection(mentionedIDs)
            .subtracting(actorID.map { [$0] } ?? [])
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
        let ownerID = try await Wishlist.find(wishlistID, on: db)?.$owner.id
        let excludedIDs = Set([actorID, ownerID].compactMap { $0 })
        let eligibleIDs: Set<UUID>
        if let eligibleUserIDs {
            eligibleIDs = userIDs.intersection(eligibleUserIDs).subtracting(excludedIDs)
        } else {
            eligibleIDs = userIDs
                .intersection(try await MentionService.eligibleUserIDs(for: wishlistID, on: db))
                .subtracting(excludedIDs)
        }
        guard !eligibleIDs.isEmpty else { return }

        // Lock-screen notifications must not disclose a person's name, list,
        // or private comment/note content. The in-app activity view still
        // identifies the event after the account is unlocked.
        let message = "Open Hushful to view the mention."
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

    private static func acceptedFriendIDs(for userID: UUID, on db: any Database) async throws -> Set<UUID> {
        let friendships = try await Friendship.query(on: db)
            .filter(\.$status == "accepted")
            .group(.or) { group in
                group.group(.and) { $0.filter(\.$requester.$id == userID) }
                group.group(.and) { $0.filter(\.$recipient.$id == userID) }
            }
            .all()

        return Set(friendships.flatMap { [$0.$requester.id, $0.$recipient.id] }.filter { $0 != userID })
    }

    private static func users(for ids: Set<UUID>, on db: any Database) async throws -> [SocialUserDTO] {
        guard !ids.isEmpty else { return [] }
        return try await User.query(on: db)
            .filter(\.$id ~~ Array(ids))
            .all()
            .compactMap { user in
                guard let id = user.id,
                      let username = user.username,
                      !username.isEmpty else { return nil }
                return SocialUserDTO(
                    id: id,
                    username: username,
                    displayName: user.displayName,
                    hasAvatar: user.avatarData != nil
                )
            }
            .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }
}
