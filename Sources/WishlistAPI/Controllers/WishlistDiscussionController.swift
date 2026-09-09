import Fluent
import Vapor

struct WishlistDiscussionController: RouteCollection {
    struct DiscussionCommentResponse: Content {
        let id: UUID
        let message: String
        let authorDisplayName: String?
        let createdAt: Date?
        let isMine: Bool
    }

    struct CreateDiscussionCommentRequest: Content {
        let message: String
        let displayName: String?
        let shareName: Bool?
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.get(":wishlistID", "discussion", use: list)
        routes.get(":wishlistID", "discussion", "mention-candidates", use: mentionCandidates)
        routes.post(":wishlistID", "discussion", use: create)
        routes.delete(":wishlistID", "discussion", ":commentID", use: delete)
    }

    func list(req: Request) async throws -> [DiscussionCommentResponse] {
        let userID = try req.auth.require(User.self).requireID()
        let (wishlist, participant) = try await authorize(wishlistID: req, userID: userID, on: req.db)
        let wishlistID = try wishlist.requireID()
        let comments = try await WishlistDiscussionComment.query(on: req.db)
            .filter(\.$wishlist.$id == wishlistID)
            .sort(\.$createdAt, .ascending)
            .all()
        let viewerIDs = Array(Set(comments.map(\.$viewer.id)))
        let viewers = try await WishlistViewer.query(on: req.db)
            .filter(\.$id ~~ viewerIDs)
            .with(\.$user)
            .all()
        let names = Dictionary(uniqueKeysWithValues: viewers.compactMap { viewer -> (UUID, String)? in
            guard let id = viewer.id else { return nil }
            let displayName = viewer.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountName = viewer.user?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = displayName?.isEmpty == false ? displayName! : accountName
            guard let name, !name.isEmpty else { return nil }
            return (id, name)
        })
        let participantID = try participant.requireID()

        return comments.compactMap { comment in
            guard let id = comment.id else { return nil }
            return .init(
                id: id,
                message: comment.message,
                authorDisplayName: comment.shareName ? names[comment.$viewer.id] : nil,
                createdAt: comment.createdAt,
                isMine: comment.$viewer.id == participantID
            )
        }
    }

    func mentionCandidates(req: Request) async throws -> [SocialUserDTO] {
        let userID = try req.auth.require(User.self).requireID()
        let (wishlist, _) = try await authorize(wishlistID: req, userID: userID, on: req.db)
        return try await memberUsers(for: wishlist, excluding: userID, on: req.db)
    }

    func create(req: Request) async throws -> DiscussionCommentResponse {
        let user = try req.auth.require(User.self)
        let userID = try user.requireID()
        let (wishlist, participant) = try await authorize(wishlistID: req, userID: userID, on: req.db)
        let wishlistID = try wishlist.requireID()
        let body = try req.content.decode(CreateDiscussionCommentRequest.self)
        let message = body.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 1_000 else {
            throw Abort(.badRequest, reason: "Comments must be between 1 and 1,000 characters.")
        }

        let members = try await memberUsers(for: wishlist, excluding: nil, on: req.db)
        let memberIDs = Set(members.map(\.id))
        try await MentionService.validateMentions(
            in: message,
            allowedUserIDs: memberIDs,
            actorID: userID,
            on: req.db
        )

        let shareName = body.shareName != false
        if shareName, let displayName = body.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !displayName.isEmpty {
            participant.displayName = displayName
            try await participant.save(on: req.db)
        }

        let comment = WishlistDiscussionComment(
            wishlistID: wishlistID,
            viewerID: try participant.requireID(),
            message: message,
            shareName: shareName
        )
        try await comment.save(on: req.db)

        let actorName = user.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ??
            user.username.map { "@\($0)" } ?? "Someone"
        do {
            try await MentionService.notifyNewMentions(
                in: message,
                wishlistID: wishlistID,
                actorID: userID,
                actorName: actorName,
                context: "in a joint wishlist discussion.",
                eligibleUserIDs: memberIDs,
                on: req.db,
                client: req.client,
                logger: req.logger
            )
        } catch {
            req.logger.warning("Joint wishlist comment was saved, but mention notifications could not be created: \(error)")
        }

        let author = shareName ? (participant.displayName ?? user.displayName) : nil
        return .init(
            id: try comment.requireID(),
            message: message,
            authorDisplayName: author,
            createdAt: comment.createdAt,
            isMine: true
        )
    }

    func delete(req: Request) async throws -> HTTPStatus {
        let userID = try req.auth.require(User.self).requireID()
        let (wishlist, participant) = try await authorize(wishlistID: req, userID: userID, on: req.db)
        guard let commentID = req.parameters.get("commentID", as: UUID.self),
              let comment = try await WishlistDiscussionComment.query(on: req.db)
                .filter(\.$id == commentID)
                .filter(\.$wishlist.$id == wishlist.requireID())
                .filter(\.$viewer.$id == participant.requireID())
                .first() else {
            throw Abort(.notFound)
        }
        try await comment.delete(on: req.db)
        return .noContent
    }

    private func authorize(
        wishlistID req: Request,
        userID: UUID,
        on db: any Database
    ) async throws -> (Wishlist, WishlistViewer) {
        guard let viewer = try await User.find(userID, on: db),
              let wishlistID = req.parameters.get("wishlistID", as: UUID.self),
              let wishlist = try await Wishlist.find(wishlistID, on: db),
              try await WishlistPermissionService.canEdit(wishlistID: wishlistID, userID: userID, on: db) else {
            throw Abort(.notFound)
        }
        guard !wishlist.matureContentEnabled || viewer.derivedAgeBand == "adult" else {
            throw Abort(.forbidden, reason: "This list is not available to your account.")
        }

        if let existing = try await WishlistViewer.query(on: db)
            .filter(\.$wishlist.$id == wishlistID)
            .filter(\.$user.$id == userID)
            .first() {
            return (wishlist, existing)
        }

        let participant = WishlistViewer(wishlistId: wishlistID, userId: userID)
        try await participant.save(on: db)
        return (wishlist, participant)
    }

    private func memberUsers(
        for wishlist: Wishlist,
        excluding userID: UUID?,
        on db: any Database
    ) async throws -> [SocialUserDTO] {
        let owner = try await wishlist.$owner.get(on: db)
        let ownerID = try owner.requireID()
        let collaborators = try await WishlistCollaborator.query(on: db)
            .filter(\.$wishlist.$id == wishlist.requireID())
            .with(\.$user)
            .all()
            .map(\.user)
        return ([owner] + collaborators).compactMap { user in
            guard let id = user.id,
                  id != ownerID,
                  id != userID,
                  let username = user.username,
                  !username.isEmpty else { return nil }
            return SocialUserDTO(id: id, username: username, displayName: user.displayName, hasAvatar: user.avatarData != nil)
        }
        .reduce(into: [UUID: SocialUserDTO]()) { result, user in result[user.id] = user }
        .values
        .sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
