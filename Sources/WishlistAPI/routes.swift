import Fluent
import Vapor

private struct UpdateProfileRequest: Content {
    let displayName: String?
    let username: String?
    let isDiscoverable: Bool?
    let friendRequestPolicy: String?
    let privacySetupCompleted: Bool?
    let onboardingVersion: Int?
    let showAgeRestrictedLists: Bool?
}

func routes(_ app: Application) throws {

    // Basic sanity routes
    app.get { req async in
        "It works!"
    }

    app.get("health") { req async in
        HTTPStatus.ok
    }

    app.get(".well-known", "apple-app-site-association") { req async -> Response in
        let body = #"{"applinks":{"details":[{"appIDs":["89JNN3239D.com.bausch.hushful"],"components":[{"/":"/share/*","comment":"Hushful wishlist share links"}]}]}}"#
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(string: body))
    }

    app.get("share", ":shareToken") { req async -> Response in
        guard let shareToken = req.parameters.get("shareToken") else {
            return Response(status: .badRequest)
        }
        // Keep the API host as an app-link target for installed clients, but
        // send ordinary browsers to the responsive web guest experience.
        // The token is URL-safe and remains in the path so the web app can
        // perform the same server-side age gate as every other client.
        let destination = "https://hushful.app/share/\(shareToken)"
        return Response(
            status: .seeOther,
            headers: ["Location": destination]
        )
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    // Versioned API
    let v1 = app.grouped("v1")
    let metrics = WebMetricsController()
    v1.post("metrics", "events", use: metrics.track)

    // Auth (register/login)
    try v1.register(collection: AuthController())
    try v1.register(collection: ProPurchaseController())
    try v1.register(collection: GooglePlayProPurchaseController())

    // Public sharing endpoints accept anonymous guests, but opportunistically
    // authenticate bearer tokens so account age and block rules still apply.
    let optionallyAuthenticated = v1.grouped(UserTokenAuthenticator())
    try optionallyAuthenticated.register(collection: RecipientShareController())
    try optionallyAuthenticated.register(collection: AvatarController())
    try optionallyAuthenticated.register(collection: WishlistItemImageController())

    // Protected routes (JWT)
    let protected = v1
        .grouped(UserTokenAuthenticator())
        .grouped(User.guardMiddleware())

    protected.get("me") { req async throws -> User.Public in
        let user = try req.auth.require(User.self)
        return user.toPublic()
    }

    protected.delete("me") { req async throws -> HTTPStatus in
        let user = try req.auth.require(User.self)
        // User-owned and social records use cascading foreign keys. Anonymous
        // wishlist viewers intentionally become detached when appropriate.
        try await req.db.transaction { database in
            try await user.delete(on: database)
        }
        return .noContent
    }

    protected.patch("me") { req async throws -> User.Public in
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(UpdateProfileRequest.self)
        if let requestedName = body.displayName {
            let displayName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, displayName.count <= 80 else { throw Abort(.badRequest, reason: "Display name must be 1–80 characters.") }
            try ContentSafetyService.validate(displayName, field: "display name")
            user.displayName = displayName
            user.displayNameSearch = displayName.lowercased()
        }
        if let requestedUsername = body.username {
            let username = requestedUsername.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let currentUsername = user.username {
                guard username == currentUsername else {
                    throw Abort(.forbidden, reason: "Your username cannot be changed after it is created.")
                }
            } else {
                let allowed = username.range(of: #"^[a-z0-9_]{3,30}$"#, options: .regularExpression) != nil
                guard allowed else { throw Abort(.badRequest, reason: "Usernames must be 3–30 letters, numbers, or underscores.") }
                if let existing = try await User.query(on: req.db)
                    .filter(\User.$username == username)
                    .first(), existing.id != user.id {
                    throw Abort(.conflict, reason: "That username is already taken.")
                }
                user.username = username
            }
        }
        if let isDiscoverable = body.isDiscoverable {
            guard user.username != nil || !isDiscoverable else { throw Abort(.badRequest, reason: "Choose a username before enabling discovery.") }
            user.isDiscoverable = isDiscoverable
        }
        if let policy = body.friendRequestPolicy {
            guard ["everyone", "friends_of_friends", "nobody"].contains(policy) else { throw Abort(.badRequest, reason: "Invalid friend request policy.") }
            user.friendRequestPolicy = policy
        }
        if body.privacySetupCompleted == true {
            guard user.username != nil, body.isDiscoverable != nil, body.friendRequestPolicy != nil else {
                throw Abort(.badRequest, reason: "Choose your discovery and friend request settings before continuing.")
            }
            user.privacySetupCompleted = true
        }
        if let showAgeRestrictedLists = body.showAgeRestrictedLists {
            guard !showAgeRestrictedLists || user.derivedAgeBand == "adult" else {
                throw Abort(.badRequest, reason: "Only adult accounts can show lists intended for adults.")
            }
            user.showAgeRestrictedLists = showAgeRestrictedLists
        }
        if user.derivedAgeBand != "adult" {
            user.showAgeRestrictedLists = false
        }
        if let onboardingVersion = body.onboardingVersion {
            guard onboardingVersion == 1,
                  user.username != nil,
                  user.privacySetupCompleted == true,
                  user.birthdaySetupCompleted == true,
                  user.birthdayYear != nil,
                  user.birthdayMonth != nil,
                  user.birthdayDay != nil
            else { throw Abort(.badRequest, reason: "Enter your birthday before finishing account setup.") }
            user.onboardingVersion = onboardingVersion
        }
        try await user.save(on: req.db)
        return user.toPublic()
    }

    // Shared wishlists saved to the signed-in account.
    try protected.grouped("shared-wishlists").register(collection: AccountShareController())

    try protected.register(collection: SocialController())
    try protected.register(collection: UserReportController())
    try protected.register(collection: AccountAvatarController())
    try protected.register(collection: ActivityController())
    try protected.register(collection: PushDeviceController())
    try protected.register(collection: FriendProfileController())
    try protected.register(collection: ProfileDetailsController())
    try protected.register(collection: PinController())
    try protected.register(collection: NetworkController())
    try protected.register(collection: RecurringOccasionController())
    protected.get("metrics", "summary", use: metrics.summary)
    protected.get("metrics", "accounts", use: metrics.accounts)
    try protected.register(collection: FeedbackController())
    try protected.register(collection: AdminTOTPController())

    // Mount wishlists at /wishlists
    let wishlists = protected.grouped("wishlists")
    try wishlists.register(collection: WishlistController())
    try wishlists.register(collection: WishlistDiscussionController())
    try wishlists.register(collection: WishlistAudienceController())
    try wishlists.register(collection: WishlistCollaboratorController())
    try wishlists.register(collection: GiftPlanningController())

    // Mount items at /wishlists (your WishlistItemController likely expects /wishlists/:id/items…)
    try wishlists.register(collection: WishlistItemController())
    try wishlists.register(collection: AccountWishlistItemImageController())

    // Share link creation should also live under /wishlists/...
    try wishlists.register(collection: OwnerShareController())
}
