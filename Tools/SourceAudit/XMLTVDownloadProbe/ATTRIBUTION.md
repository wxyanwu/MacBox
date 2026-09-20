# 9B.3B-M preregistered attribution protocol

R0-historical stays sealed. R0-repeat uses the original receive loop, now with
the same test-only lifecycle observer and fully ended warmup as R1 and R2.
R1 moves only the proportional delay to A's existing injected write operation.
R2 removes the callback subdata loop and calls A.write(data); A still performs
bounded 64 KiB POSIX writes and all ownership/byte/cancellation checks.
No Change A, production, HTTP policy, parser, Repository or database changes.

1. Freeze before and after edits, build/test only disposable source copies.
2. Sanity invocation validates the new harness, not memory budgets.
3. Screen: 1/32 MiB, nominal slow-write ceiling 2 MiB/s, 3 repetitions of each
   R0/R1/R2, interleaved; 18 independent Release XCTest processes. Real achieved
   throughput reported. No profiler/barriers, one warmup per process.
4. Attribution: independent R0/R2 diagnostic processes, 1 and 32 MiB, one
   checkpoint per process: callback after >=512 KiB written, HTTP completion,
   session invalidated, reader released. Each records exact written/callback
   bytes. R2 checkpoint can overshoot because callback sizes are uncontrolled.
   Never compare callback snapshots as if their progress were exactly equal.
   External vmmap/heap, stack logging; <=15 seconds handshake, no delegate
   queue-dependent resume. Observer interference/permission failure reported.
   Pausing may increase network backlog: these runs never count as RSS gates.
5. Only a supported minimal candidate gets the unchanged 40-run gate:
   1/8/16/32 MiB x normal/slow x 5; growth<=8 MiB, slope<=.20, peak<=64 MiB.
   Measure original baseline-to-transfer interval. Separately report completion,
   invalidation, explicit release, delegate destruction and 250ms settled state.
6. No automatic autoreleasepool/framework/backpressure changes. Additional pool
   contrast only if allocation evidence warrants it, with separately frozen code.

malloc_zone_statistics(NULL).size_in_use is live allocated malloc bytes, not VM
region capacity or cumulative allocation traffic. heap/stack evidence is needed
for object attribution. RSS and footprint must not be substituted for each other.
No claim that their subtraction equals reclaimable memory. Tools may not observe
all allocations. No mandatory return of RSS to its initial value after release.

All inputs are synthetic loopback bytes. Per-run length + incremental SHA checks,
explicit session invalidation/file release/receipt-based fixture cleanup. No
full response oracle Data, no recursive deletion, no user App or production DB.
Original gate remains FAIL until the unprofiled full matrix proves otherwise.
Even a passed memory gate does not implement or approve the rest of Change B.

Harness correction before the complete matrix: preserve XCTest stderr separately
from JSON stdout. The first screen attempt stopped on interleaved output after
three small runs; keep its evidence and restart all 18, not selected cases.
This does not change the measured binary, receive path, rate or thresholds.

After the complete unprofiled screen and 1 MiB stage captures, use wide vmmap
output for 32 MiB captures to retain mapping identities as well as totals.
This is diagnostic-output detail only, not a change to any measured receive path.

Attribution follow-up preregistered after the first 32 MiB completion capture:
the stack-logged VM snapshot shows substantial resident MALLOC_MEDIUM(empty)
pages but far fewer live allocations. To avoid attributing profiler effects to
normal operation, run vmcontrol: R0/R2 x 1/32 MiB x completion/released (8 separate
processes), no MallocStackLogging, only wide vmmap, one bounded barrier per run.
This is a diagnostic control, not an RSS pass measurement or budget change.
