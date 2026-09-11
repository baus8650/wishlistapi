# Cross-platform Pro rollout

This change requires a coordinated API and iOS release. Do not deploy the new server restrictions while the only available iOS build unlocks purchases locally: that build cannot sync a purchase to the API and would lose access to gated server features.

The web uses `/v1/me.isPro`, never a client-supplied purchase flag. Free accounts can create three active primary-owned lists; archived lists and other people's lists do not count. The server serializes creation per account to prevent concurrent requests exceeding the limit. Pro is required for recurring occasion creation/updates, cash funds, duplication, and planning/appearance/archive settings. Ordinary wishes, sharing, collaboration, and gift coordination stay free.

## Apple configuration

Before releasing the API and updated iOS build:

1. Hushful's numeric Apple ID is `6805499302`. Purchase verification uses this by default; no app-ID setup is needed. `APPLE_APP_ID` remains available as an explicit server override.
2. Apple's three published root certificates are included in `Resources/AppleCertificates/`. The Dockerfile already copies these resources into `/app/Resources/AppleCertificates/` and sets `APPLE_ROOT_CERTIFICATE_PATHS` to their absolute paths. No separate certificate upload or Railway variable is needed for Docker deployments. For local runs outside Docker, set this variable to the three absolute paths in your checkout. An existing deployment-level override of this variable must point to the packaged files. Certificate sources and fingerprints are recorded in that directory's README.
3. Leave `APPLE_STORE_ENVIRONMENT` unset for production. Set it to `sandbox` only on an isolated test server; never use sandbox grants for production accounts.
4. Configure App Store Server Notifications V2 to `https://<API host>/v1/pro/apple/notifications`. Set up the sandbox notification URL separately. Refund/revocation updates depend on notifications; confirm delivery and retries before launch.
5. Apply the `CreateAppleProPurchases` migration. The server verifies Apple's signature/certificate chain, bundle, environment, product, purchase type, and account token. Per-purchase signed timestamps prevent an older purchase replay from overwriting a newer refund notification.
6. Exercise a sandbox purchase, restore, purchase on a different Hushful account (must fail), web status refresh, refund, and replay of an older grant after refund. Use isolated test accounts. Verify three-list enforcement with concurrent creation requests and a Pro account with more than three lists.
7. Release the iOS code that syncs verified transactions on purchase, restore, launch/account configuration, and transaction updates. Existing buyers need to open the updated app or Restore Purchases once to sync. Failed sync leaves local StoreKit access available and shows retry instructions; it does not finish the new transaction until the server acknowledges it.

## Google Play configuration

Before distributing the Android build:

1. Create an active one-time product named `hushful_pro_lifetime` for package `com.hushful.app` and grant the server service account access to the Google Play Android Publisher API.
2. Configure `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` or `GOOGLE_PLAY_SERVICE_ACCOUNT_BASE64` on the API deployment. Never include the service-account key in the Android project.
3. Apply the `CreateGooglePlayProPurchases` migration and test purchase, pending purchase, restore, duplicate delivery, and a purchase attempted from a different Hushful account.
4. Configure Google Play Real-time Developer Notifications in the Play Console, create a Pub/Sub push subscription to `https://<API host>/v1/pro/google/notifications?token=<GOOGLE_PLAY_RTDN_TOKEN>`, and set the same high-entropy token on the API. The endpoint re-verifies each token before activating or revoking the stored entitlement.
5. Upload the Android App Bundle to an internal or closed test track and install it from Google Play. A sideloaded debug build cannot complete a production Play purchase. Verify that Google Sign-In uses the Play app-signing certificate, not the upload certificate.

The web reads the server's `isPro` entitlement and does not accept client-supplied purchase state. Preserve purchase provenance and the account-level, non-transferable behavior when adding any future web checkout.

Then cross your fingers!
