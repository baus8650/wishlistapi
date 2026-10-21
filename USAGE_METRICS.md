# Hushful usage metrics

Matches Nestic's first-party traffic and growth coverage on web and iOS. New collection starts when these changes are deployed; the existing web metric table is retained for historical access through its legacy endpoint.

## Coverage

- Website page views, iOS app opens, App Store link clicks, opted-in sessions, new accounts, and items created.
- 7/30/90-day UTC charts, complete daily totals including zero days, country/city, device/browser/OS, referral sites, campaigns, time zones, pages, and the latest 100 events.
- New accounts and items created are current database records created in the reporting period, not an immutable action history. Deleted records no longer contribute. Traffic is approximate, not unique people or installs.
- Web: standalone `/metrics` dashboard, linked from Account (administrator access). Overview includes complete-week comparisons, daily charts, average views, busiest day, ranked sources, and daily CSV export. Audience, Sources and Recent Activity have separate sections. iOS: Account → Hushful Metrics provides a full native dashboard with Overview, Audience, Sources and Activity sections: card totals, date-based charts, daily totals, expandable country/city/device/source breakdowns, and filterable recent events with available location details. The web dashboard is an optional shortcut. Web sign-in is separate; native credentials are never included in the link.

## Consent and protection

Detailed web analytics are opt-in via Usage privacy. iOS app opens are sent only after opting in; change the setting in Account → Privacy. Browser DNT/GPC signals suppress all details. Unconsented web events contain event ID, source, kind and an allowlisted generic path only. Withdrawal clears session identifiers and affects subsequent collection; an in-flight request may have already been sent. Updating consent for the current web page updates its existing event rather than counting another page view.

No account IDs, authentication headers, wishlist contents, private share/reset links, precise location or raw visitor IPs are stored in usage events. IPs are used transiently for the offline lookup and salted in-memory rate limits. Bots are excluded. Administrative endpoints retain Hushful's role and MFA enforcement and audit logging. Recent traffic is available only to administrators.

Usage events expire after 90 days, with cleanup at startup and every six hours. Geo data is DB-IP Lite October 2026, CC BY 4.0, copied from Nestic's offline indexes; attribution is in both admin dashboards and `Resources/GEOIP-LICENSE.txt`. Unknown locations remain empty. No third-party geolocation requests are sent.

## Rollout

1. Deploy WishlistAPI and run migrations (`CreateUsageEvents`, `AddUsageLocationDetails`) before deploying the web client and shipping the iOS build. Keep the `Resources/geoip-*` files and license in the server image; the existing Dockerfile stages Resources.
2. Leave `ANALYTICS_TRUST_PROXY` unset unless the server is behind a trusted proxy that strips/replaces forwarding headers and prevents direct connections. Set it to `true` in that deployment to use forwarded visitor IPs for approximate geography. Without it, geography uses the network peer address and may be unknown/the proxy's location.
3. Publish the updated web privacy policy with the release. Review App Store Connect's App Privacy disclosures for optional first-party usage analytics, approximate location, and random session identifiers before shipping the iOS update. This work does not publish disclosures or deploy services.
4. Verify anonymous vs opted-in events and admin dashboards against a migrated staging PostgreSQL database. Use a test account/device and browser session. No production data was changed during implementation.

## Validation

Web: `npm test`, `npm run lint`, `npm run build`.
Server: `swift test --filter UsageAnalytics` tests consent withdrawal, DNT/GPC, dimension sanitization, offline geo lookup, and role/MFA checks. Full API integration tests require local PostgreSQL.
iOS: build `wishlist-ios` for a generic iOS Simulator destination, code signing disabled.

## October 15 analytics improvements

Native iOS now includes the complete Overview, Audience, Sources and Activity dashboard, including ranked country/city breakdowns with percentages, expandable dimensions, daily totals and event filters. Optional server location diagnostics distinguish missing resources, disabled proxy forwarding and no located events. Diagnostics are administrator-only and do not reveal connection addresses.

Administrator self-exclusion: iOS Account → Privacy and the native metrics page show “Exclude this device from analytics” only after successful administrator verification. Web `/metrics` shows a browser exclusion switch only after a successful administrator report response; the public Usage privacy panel does not offer it. Exclusion stops every new usage request from that installation/browser, including anonymous counts, and persists independently of sign-in. Detailed-data consent alone still permits anonymous web counts. Clear app/browser storage or use another browser/device and the exclusion must be set again. Administrators default to device/browser exclusion on their first successful report load; explicit choices are preserved. Signed-in administrators are excluded server-side regardless of that switch. Clients authenticate collection requests solely for this exclusion; account IDs are not stored with events. Normal security/audit logs and database account/item totals are unaffected.

Production investigation found `ANALYTICS_TRUST_PROXY` missing on Railway. The running image stages Resources and Railway documents X-Real-IP as the client address. On October 15 this variable was set to true for wishlistapi production, triggering a redeploy of the existing release; Railway confirmed SUCCESS for that configuration rollout. Only that configuration fix was deployed; the new UI, self-exclusion and diagnostic code remain local until their respective releases. New opted-in events can have city estimates with the corrected production configuration; old events cannot be backfilled without retained IPs.
