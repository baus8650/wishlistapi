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

    // Mount wishlists at /wishlists
    let wishlists = protected.grouped("wishlists")
    try wishlists.register(collection: WishlistController())

    // Mount items at /wishlists (your WishlistItemController likely expects /wishlists/:id/items…)
    try wishlists.register(collection: WishlistItemController())

    // Share link creation should also live under /wishlists/...
    try wishlists.register(collection: OwnerShareController())
}
