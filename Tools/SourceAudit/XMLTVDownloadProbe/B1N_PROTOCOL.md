# B1-N strict-admission session-lifetime experiment

Developer-only. B2 and all production paths remain frozen. Direct DownloadTask
is not a candidate in this experiment. Both variants create data tasks, validate
HTTP 200/no Content-Range/identity coding/declared size before body admission,
then request `becomeDownload`.

The common implementation uses one task-ID router, operation state, pinned
Foundation descriptor, shared serial 64 KiB copy worker, Change A staging,
HTTP/copy join, single `finishAndTransfer`, caller SHA/read/release, and the B1-M
low-allocation observer. The sole intended variable is URLSession/delegate/router
lifetime:

- perOperation: create, invalidate, and destroy one router/session per operation;
- sharedSession: one warmed router/session serves the warmup and all eight
  sequential operations, then is explicitly invalidated and destroyed.

Before memory measurement, two concurrent operations share one router: one is
cancelled immediately after `becomeDownload` disposition and the other must
complete with exact bytes. Cancellation, task replacement, mapping removal, and
ownership must remain operation-scoped.

Preregistered memory order: P1, S1, S2, P2, P3, S3. Every row is a new Release
XCTest process with one 64 KiB warmup, eight 32 MiB operations, and 250 ms
settlement. No retry, profiler, pressure relief, wait extension, or threshold
change. The existing R3/B1 limits are evaluated independently for every process.

B1-N supports the reusable-session direction only if all three per-operation
controls reproduce FAIL and all three shared-session runs PASS. All-pass is
stable but does not isolate the prior failure. Any mixed result or any failed
router isolation/correctness assertion blocks the direction. Passing B1-N is a
feasibility result only; it does not start B2 or establish its full security,
redirect, deadline, failure, concurrency, disk-budget, or shutdown contract.
