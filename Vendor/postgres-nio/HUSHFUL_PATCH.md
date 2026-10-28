# PostgreSQL read-completion recovery

Vendored from vapor/postgres-nio 1.31.0, revision 7fa45c5a1f6e79338a26e18121210a87389f7a67, the previously resolved dependency. Licenses are preserved. The only upstream source change is RowStreamStateMachine.channelReadComplete().

Production crashed October 28, 2026 at RowStreamStateMachine.swift:94, followed by connection-pool timeouts. receivedRow/end already accept unsolicited buffered reads when a connection closes. This patch also accepts the corresponding completion while waiting for read/demand: it returns no rows, preserving buffers/state. Failed/modifying states still assert. No schema or data changes.

Regression tests are in the application’s PostgresReadCompletionTests.swift. Remove this override when upstream supports this event sequence.
