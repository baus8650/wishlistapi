import Fluent
import Vapor

private struct UpdateProfileRequest: Content {
    let displayName: String?
    let username: String?
    let isDiscoverable: Bool?
    let friendRequestPolicy: String?
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
        Response(
            status: .ok,
            headers: ["Content-Type": "text/html; charset=utf-8"],
            body: .init(string: """
                <!doctype html>
                <html lang="en">
                <meta name="viewport" content="width=device-width, initial-scale=1">
                <title>Open in Hushful</title>
                <body style="font-family: -apple-system, sans-serif; margin: 3rem auto; max-width: 32rem; padding: 1rem; text-align: center;">
                    <h1>Hushful</h1>
                    <p>Install or open Hushful on your iPhone to view this shared wishlist.</p>
                </body>
                </html>
                """)
        )
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    // Versioned API
    let v1 = app.grouped("v1")

    // Auth (register/login)
    try v1.register(collection: AuthController())

    // Public sharing + recipient endpoints (anonymous-friendly)
    try v1.register(collection: RecipientShareController())
    try v1.register(collection: AvatarController())

    // Protected routes (JWT)
    let protected = v1
        .grouped(UserTokenAuthenticator())
        .grouped(User.guardMiddleware())

    protected.get("me") { req async throws -> User.Public in
        let user = try req.auth.require(User.self)
        return user.toPublic()
    }

    protected.patch("me") { req async throws -> User.Public in
        let user = try req.auth.require(User.self)
        let body = try req.content.decode(UpdateProfileRequest.self)
        if let requestedName = body.displayName {
            let displayName = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, displayName.count <= 80 else { throw Abort(.badRequest, reason: "Display name must be 1–80 characters.") }
            user.displayName = displayName
        }
        if let requestedUsername = body.username {
            let username = requestedUsername.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let allowed = username.range(of: #"^[a-z0-9_]{3,30}$"#, options: .regularExpression) != nil
            guard allowed else { throw Abort(.badRequest, reason: "Usernames must be 3–30 letters, numbers, or underscores.") }
            if let existing = try await User.query(on: req.db)
                .filter(\User.$username == username)
                .first(), existing.id != user.id {
                throw Abort(.conflict, reason: "That username is already taken.")
            }
            user.username = username
        }
        if let isDiscoverable = body.isDiscoverable {
            guard user.username != nil || !isDiscoverable else { throw Abort(.badRequest, reason: "Choose a username before enabling discovery.") }
            user.isDiscoverable = isDiscoverable
        }
        if let policy = body.friendRequestPolicy {
            guard ["everyone", "nobody"].contains(policy) else { throw Abort(.badRequest, reason: "Invalid friend request policy.") }
            user.friendRequestPolicy = policy
        }
        try await user.save(on: req.db)
        return user.toPublic()
    }

    // Shared wishlists saved to the signed-in account.
    try protected.grouped("shared-wishlists").register(collection: AccountShareController())

    try protected.register(collection: SocialController())
    try protected.register(collection: AccountAvatarController())
    try protected.register(collection: ActivityController())

    // Mount wishlists at /wishlists
    let wishlists = protected.grouped("wishlists")
    try wishlists.register(collection: WishlistController())
    try wishlists.register(collection: WishlistAudienceController())

    // Mount items at /wishlists (your WishlistItemController likely expects /wishlists/:id/items…)
    try wishlists.register(collection: WishlistItemController())

    // Share link creation should also live under /wishlists/...
    try wishlists.register(collection: OwnerShareController())
}
