import Fluent
import FluentPostgresDriver
import JWT
import Vapor

public func configure(_ app: Application) async throws {

    // MARK: Database

    if let databaseURL = Environment.get("DATABASE_URL"), !databaseURL.isEmpty {
        // Railway supplies DATABASE_URL, including any TLS options required by
        // the selected PostgreSQL service.
        app.databases.use(try .postgres(url: databaseURL), as: .psql)
    } else {
        let hostname = Environment.get("DATABASE_HOST") ?? "localhost"
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber
        let username = Environment.get("DATABASE_USERNAME") ?? "wishlist"
        let password = Environment.get("DATABASE_PASSWORD") ?? "wishlist"
        let database = Environment.get("DATABASE_NAME") ?? "wishlist_dev"

        let configuration = SQLPostgresConfiguration(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disable
        )
        app.databases.use(.postgres(configuration: configuration), as: .psql)
    }

    let secret: String
    if let configuredSecret = Environment.get("JWT_SECRET"), !configuredSecret.isEmpty {
        secret = configuredSecret
    } else if app.environment == .production {
        app.logger.critical("JWT_SECRET must be set in production.")
        throw Abort(.internalServerError, reason: "Server authentication is not configured.")
    } else {
        secret = "dev-only-change-me"
    }
    let key = HMACKey(from: secret)
    await app.jwt.keys.add(hmac: key, digestAlgorithm: .sha256)

    app.migrations.add(CreateUser())
    app.migrations.add(AddDisplayNameToUser())
    app.migrations.add(CreateWishlist())
    app.migrations.add(CreateWishlistItem())
    app.migrations.add(CreateWishlistShareLink())
    app.migrations.add(CreateWishlistViewer())
    app.migrations.add(CreateItemViewerState())

    // MARK: Routes
    try routes(app)
}
