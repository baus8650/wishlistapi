# Wishlist

A private-surprise wishlist app with a Vapor/PostgreSQL API and a SwiftUI iOS client.

The owner creates wishlists and items. Recipients open a private share token and can mark items as purchased or leave notes. Recipient activity is stored separately from the owner's item data and is never returned by owner endpoints, preserving the surprise.

## Local development

Requirements:

- Docker Desktop, running
- Xcode (not only the Command Line Tools) for the iOS app

Start the database and API from this directory:

```bash
docker compose up -d db
docker compose run --rm migrate
docker compose up app
```

The API is then available at `http://127.0.0.1:8080`. Check it with `curl http://127.0.0.1:8080/`.

Open `../wishlist-ios/wishlist-ios.xcodeproj` in Xcode and run the `wishlist-ios` scheme in an iPhone simulator. The simulator can reach the locally running API at the default URL already configured in `APIClient.swift`.

For a physical device, change `APIClient.baseURL` to the Mac's LAN address. Production builds must use an HTTPS API URL.

## Core flow

1. Register or log in.
2. Create a wishlist with the plus button.
3. Open it and add items.
4. Tap the share button to create and send a private share token.
5. A recipient opens the link button, pastes the token, and can reserve items or add notes.
6. The owner continues to see only the original wishlist and item details.

Treat share tokens like unlisted links: anyone who has one can view that wishlist. Creating a new token does not revoke older tokens; revocation and rotation endpoints exist in the API but are not yet exposed in the iOS UI.

## Configuration

Docker Compose supplies local defaults. Set secure values in production:

| Variable | Local default |
| --- | --- |
| `DATABASE_HOST` | `db` |
| `DATABASE_PORT` | `5432` |
| `DATABASE_NAME` | `wishlist_dev` |
| `DATABASE_USERNAME` | `wishlist` |
| `DATABASE_PASSWORD` | `wishlist` |
| `JWT_SECRET` | `dev-only-change-me` |
| `DATABASE_URL` | unset; overrides the individual database variables when set |
| `PORT` | `8080`; hosting platforms can assign this dynamically |
| `AUTO_MIGRATE` | `false`; set to `true` for the Railway beta deployment |

Never deploy with the default JWT secret or database password.

## Railway beta deployment

1. Push this `WishlistAPI` directory as the root of a Git repository.
2. In Railway, create a new project from that repository. Railway detects the
   root `Dockerfile` automatically.
3. Add a PostgreSQL service to the same Railway project.
4. In the API service, add these variables:
   - `DATABASE_URL=${{Postgres.DATABASE_URL}}`
   - `JWT_SECRET` set to a long, randomly generated value
   - `AUTO_MIGRATE=true`
   - `LOG_LEVEL=info`
5. Under Networking, generate a public domain and set the health-check path to
   `/health`.

The container reads Railway's assigned `PORT`. With `AUTO_MIGRATE=true`, any
pending Fluent migrations run before the API begins accepting traffic.

## Tests

With PostgreSQL running and the database variables set, run `swift test`.

The current automated suite is still starter-level. Before production, add integration coverage for authentication, ownership boundaries, share revocation, and the invariant that owner responses never contain recipient purchase/note state.

## Production readiness

The core MVP flow is implemented, but a public launch still needs:

- A hosted PostgreSQL database and HTTPS API deployment
- Production API URL configuration in the iOS target
- Expanded privacy and authorization integration tests
- Account recovery, privacy policy, support information, and App Store assets
- Share-link management in the owner UI
- Rate limiting and abuse monitoring on authentication and public share endpoints
