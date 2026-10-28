# Loading outage — October 28, 2026

Production logs show a Swift precondition failure at 07:33 Eastern in PostgresNIO 1.31.0, RowStreamStateMachine.channelReadComplete(), line 94. The backtrace took 187.57 seconds, followed by connection-pool timeouts and a server restart around 07:36. The user confirmed that refreshing brought their data back after recovery. No database reset or data modification was performed.

## Driver fix

The driver's receivedRow/end methods explicitly allow buffered messages arriving while awaiting consumer read/demand on connection closure. channelReadComplete incorrectly trapped on the corresponding completion event. The local override preserves the waiting state and buffered rows and returns no rows until demand resumes or end drains the buffer. Failed/modifying states continue to trap.

Vendor/postgres-nio contains the previously pinned 1.31.0 sources and licenses, with one source modification. Package.swift overrides the transitive remote package; the lockfile removes the remote PostgresNIO pin. Docker copies the local package before dependency resolution. Upstream 1.33.1 was inspected and retains the same precondition, so a version bump alone does not fix this stack.

Three regression tests cover repeated empty completions, unsolicited completions in all three waiting states, and resumed demand without lost/duplicate rows. Eleven driver, sale-notification, and reminder tests pass together.

## Client resilience

People, Shared, and Items publish each independently loaded collection as it succeeds. A failed pins/groups/list-metadata request no longer discards successful friends/shared-list/item responses. Each refresh has an identity so canceled/older tasks cannot overwrite newer data. Failures keep loaded data and expose a retry control; genuine empty states are suppressed when loading failed. Wishlist items also show explicit loading/empty/error states.

## Deployment status

The server recovered automatically. This recurrence-prevention patch is local until the updated API is deployed. The iOS resilience changes take effect when the updated client is built and installed.
