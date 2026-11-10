# Hushful Swap

Implemented in the API, iOS app, and web app. Apply `CreateHushfulSwaps` before releasing updated clients. No production deployment is performed by this change.

## Behavior

- The organizer participates and selects existing friends to invite. Account invitations start pending; participants accept or decline. The organizer sees those statuses and can remove participants before drawing.
- A shared invitation link lets guests join without an account. Joining accepts the invitation. Guests receive a separately generated private credential, stored as a hash on the server. The organizer cannot retrieve it. The web guest page stores it locally and provides recovery details to save privately.
- A swap has a name, calendar exchange date, currency, and optional positive spending limit. Maximum roster: 100. Minimum draw: four accepted participants. Two- and three-person exchanges let a participant deduce their gifter from their own assignment.
- The server randomly draws a permutation with no self-assignments. This is directed giving, not pair matching; reciprocal assignments may happen by chance. Each person gives once and receives once. All participants must accept before drawing, and the draw permanently locks the roster. There is no redraw or administrator assignment endpoint.
- Only the authenticated participant's recipient and that recipient's gift ideas are returned. Roster responses contain no account IDs, guest credential hashes, assignment IDs, or other participants' reminder settings. Organizer privileges never broaden assignment access. Assignment secrecy is enforced by the API; it is not encryption against database operators.
- Participants can create and edit a swap-specific gift-idea list, or explicitly copy a personal, solely owned, non-mature wishlist. Copies do not update automatically when the original changes. The original list stays private, and browsing copied ideas creates no list-view activity that could identify the gifter. Existing guest links, claims, discussion, and purchaser names are not exposed.
- Pending account invitations can receive an organizer-triggered activity/push reminder once per 24 hours per person. Guests without an account cannot receive device pushes; organizers can reshare their invitation link.
- Account participants can opt into one private purchase reminder, 0–365 days before the exchange, or turn it off. Reminders default off. They become eligible after the draw at noon UTC on the selected calendar day, and a worker checks every 15 minutes. A reminder configured after its due time catches up before the exchange ends. Transactional row locks and a persisted sent flag prevent duplicate activity across workers. Push delivery is best effort through existing APNs/FCM registration and device permissions.
- Participants receive generic assignment-ready notifications. Notification text never contains a recipient's name. iOS swap pushes open My Lists.

## API

- `GET/POST /v1/swaps`: list memberships / create a swap (account required).
- `GET/POST /v1/swaps/:swapID`: member view / action (account required).
- `GET /v1/swap-invites/:invite`: public title/date/status only.
- `POST /v1/swap-invites/:invite`: join with a name; returns a guest key only on creation of an anonymous membership. An authenticated existing invitee must still accept their pending invitation.
- `GET/POST /v1/guest-swaps/:swapID`: same participant view/actions, authorized with `X-Swap-Key`.

Actions: `accept`, `decline`, `wishes`, `reminder`, `remove`, `draw`, `remind`, `cancel`. Server-side authorization applies independently of client controls. All updates lock the swap row in a transaction. Cancelled swaps cannot be changed.

## Verification

Use an isolated PostgreSQL database, not a production database:

```sh
DATABASE_PORT=6543 DATABASE_NAME=hushful_swap_test swift test --filter Swap
```

Tests cover directed permutations, absence of self-assignments, privacy for organizers and participants, guest credential separation, unauthorized access, invitation acceptance and cooldowns, locked rosters, wishlist copying without viewer activity, invalid gift URLs, reminder opt-out/timing, and concurrent reminder deduplication.

The web app uses `npm run build`, `npm test`, and ESLint. The iOS scheme builds with `xcodebuild` for an iOS Simulator destination.
