# B1-M common-harness causal comparison

Developer-only. Production HTTP/XMLTV/Repository, Change A, historical R3, and
historical B1 remain frozen. No provider input, application launch, database, or
recursive cleanup is allowed.

Two modes run through one XCTest implementation. Direct creates a download task;
converted creates a data task, validates the response, and requests
`becomeDownload`. Session configuration, delegate class/queue, pinned file,
shared serial 64 KiB copy worker, Change A staging, caller SHA/read/release,
session invalidation, fixture root, and memory observer are otherwise identical.
Direct is a loopback diagnostic control and cannot become a production fallback.

The high-frequency observer samples only task RSS and physical footprint into
fixed scalar fields. It performs no malloc-zone traversal, dictionary creation,
JSON encoding, or unbounded sample retention. `stop()` establishes a serial-queue
barrier; malloc active/reserved bytes are measured only at settled phase points.

Correctness precedes memory runs. The observation-lifecycle test, Change A's 31
tests, and the existing corrected B1 response/coding/cancellation matrix must
pass before comparison. Builds and tests run only from a frozen disposable source
snapshot.

Preregistered order is D1, C1, C2, D2, D3, C3. Each item is a new Release XCTest
process with one fully released 64 KiB warmup followed by eight 32 MiB cycles and
250 ms settlement. There are no retries, profiler, pressure relief, threshold
changes, or selected-run replacement.

Each process must independently pass the existing B1/R3 limits: settled RSS
slope <=1 MiB/cycle; footprint slope <=0.5; early/late RSS, footprint, and live
heap growth <=8/4/2 MiB; maximum settled and operation RSS deltas <=64 MiB; FD
growth <=2; all temporary/staging files removed; byte count and SHA exact.

B1-M is eligible to pass only when all three direct and all three converted runs
pass. Direct-pass/converted-fail associates the failure with the conversion path
but does not itself identify a fix. Both-fail points to shared harness/lifecycle
cost. Mixed or direct-fail/converted-pass outcomes remain inconclusive. No result
automatically starts B2.
