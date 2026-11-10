# Hushful Swap

Implemented in the API, iOS app, and web app. Apply `CreateHushfulSwaps` and `AddSwapWishlists` before releasing updated clients. No production deployment is performed by this change.

## Behavior

- Home shows a dismissible feature announcement and a separate section for active swaps and invitations. Creation lives in the + / Create menu on iOS and Mac, and in the web navigation menu.

- The organizer participates and selects existing friends to invite. Account invitations start pending; participants accept or decline. The organizer sees those statuses and can remove participants before drawing.
- A shared invitation link prompts people to sign in or create a Hushful account. The web app keeps the pending invitation through sign-in, email verification, and account setup in the same browser. Accepting the invitation joins with the signed-in account; repeated joins do not duplicate membership. Existing participants can reopen a drawn swap from its invitation. Anonymous participation and private guest keys are not supported.
- A swap has a name, calendar exchange date, currency, and optional positive spending limit. Maximum roster: 100. Two- and three-person swaps are supported; the only lower bound is having another person to gift to. All participants must accept before drawing. In small groups participants can infer assignments, although the API still returns only their own recipient.
- The organizer can edit the exchange date before or after the draw. Assignments stay fixed. Changing the date resets purchase-reminder delivery for the new date and notifies other account participants.
- The server randomly draws a permutation with no self-assignments. This is directed giving, not pair matching; reciprocal assignments may happen by chance. Each person gives once and receives once. All participants must accept before drawing, and the draw permanently locks the roster. There is no redraw or administrator assignment endpoint.
- Only the authenticated participant's recipient and that recipient's gift ideas are returned. Roster responses contain no account IDs, assignment IDs, or other participants' reminder settings. Organizer privileges never broaden assignment access. Assignment secrecy is enforced by the API; it is not encryption against database operators.
- Each accepted participant has a dedicated, private normal wishlist associated with the swap. Its title uses the exchange name (for example, “Our exchange · Swap wishlist”), without any participant or recipient name. It uses the existing item create/edit/delete, image upload, quantity, currency, sale, and Pro cash-fund paths. iOS uses the normal `AddItemView` and `WishlistItemsView`, including `ItemLinkImporter` URL autofill. The share extension offers accepted, non-cancelled swap wishlists alongside regular lists and uses the same metadata importer and save endpoints. Web item entry reuses the normal `AddItemModal`.
- Swap lists live inside the swap rather than the normal My Lists section and do not consume the three-list free allowance. Old lightweight wishes are migrated once under the swap row lock, preserving existing content. Participants may copy another solely owned, non-mature list into the swap; copied items include images, prices, inherited currency, quantity, and sale details, and remain independent of the source list.
- The assigned gifter gets a sanitized, read-only view of current items, including private image access, through the swap. Reading them creates no wishlist viewer or activity record. No normal sharing link, public visibility, collaborator, or audience can be added to a swap wishlist, and normal owner item APIs remain owner-only. Each participant receives only their own wishlist summary; the recipient’s underlying wishlist ID and other assignments are not exposed.
- Pending account invitations can receive an organizer-triggered activity/push reminder once per 24 hours per person. All participants use their Hushful account for access and reminders.
- Account participants can opt into one private purchase reminder, 0–365 days before the exchange, or turn it off. Reminders default off. They become eligible after the draw at noon UTC on the selected calendar day, and a worker checks every 15 minutes. A reminder configured after its due time catches up before the exchange ends. Transactional row locks and a persisted sent flag prevent duplicate activity across workers. Push delivery is best effort through existing APNs/FCM registration and device permissions.
- Participants receive generic assignment-ready notifications. Notification text never contains a recipient's name. iOS swap pushes open My Lists.

## API

- `GET/POST /v1/swaps`: list memberships / create a swap (account required).
- `GET/POST /v1/swaps/:swapID`: member view / action (account required).
- `GET /v1/swap-invites/:invite`: public title/date/status only.
- `POST /v1/swap-invites/:invite`: accept and join with the authenticated account. Anonymous requests return 401. Legacy guest swap routes have been removed.

Actions: `accept`, `decline`, `wishes`, `reminder`, `remove`, `draw`, `remind`, `date`, `cancel`. Server-side authorization applies independently of client controls. All updates lock the swap row in a transaction. Cancelled swaps cannot be changed.

## Verification

Use an isolated PostgreSQL database, not a production database:

```sh
DATABASE_PORT=6543 DATABASE_NAME=hushful_swap_test swift test --filter Swap
```

Tests cover directed permutations, absence of self-assignments, privacy for organizers and participants, account-only joining, rejection of anonymous and legacy guest access, invitation acceptance and cooldowns, locked rosters, wishlist copying without viewer activity, invalid gift URLs, reminder opt-out/timing, administrator-only date edits preserving assignments, concurrent reminder deduplication, standard item CRUD and rich fields, private gifter image access, preserved legacy wishes, and swap lists not consuming the free-list allowance.

The web app uses `npm run build`, `npm test`, and ESLint. The iOS scheme builds with `xcodebuild` for an iOS Simulator destination.
