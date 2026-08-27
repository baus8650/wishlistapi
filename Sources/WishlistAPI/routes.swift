import Vapor

private struct UpdateProfileRequest: Content {
    let displayName: String
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
        let body = #"{"applinks":{"details":[{"appIDs":["89JNN3239D.com.bausch.wishlist-ios"],"components":[{"/":"/share/*","comment":"Hushful wishlist share links"}]}]}}"#
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
        let displayName = body.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw Abort(.badRequest, reason: "Display name is required.")
        }
        guard displayName.count <= 80 else {
            throw Abort(.badRequest, reason: "Display name must be 80 characters or fewer.")
        }

        user.displayName = displayName
        try await user.save(on: req.db)
        return user.toPublic()
    }

    // Shared wishlists saved to the signed-in account.
    try protected.grouped("shared-wishlists").register(collection: AccountShareController())

    // Mount wishlists at /wishlists
    let wishlists = protected.grouped("wishlists")
    try wishlists.register(collection: WishlistController())

    // Mount items at /wishlists (your WishlistItemController likely expects /wishlists/:id/items…)
    try wishlists.register(collection: WishlistItemController())

    // Share link creation should also live under /wishlists/...
    try wishlists.register(collection: OwnerShareController())
}
