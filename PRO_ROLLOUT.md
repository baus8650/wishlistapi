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

Web payments and Android are advertised as coming soon. The iOS download CTA is intentionally text while the app awaits approval. Replace it with the actual App Store URL at launch. Future web checkout should update the account entitlement through a separately verified payment-provider flow; preserve existing lifetime purchases and keep purchase provenance separate if multiple billing providers are introduced.

Then cross your fingers!
