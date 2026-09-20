# 9B.3B-G preregistered budget review

Purpose: determine whether release-after-use allocator residency reaches a
plateau across repeated sessions. This does not change or pass the original RSS
body-size gate and cannot authorize the full downloader.

Synthetic loopback only. Change A and production stay frozen. One warmup is
fully invalidated and destroyed, followed in the same Release XCTest process by:

- R0 and R2, 32 MiB fast writer, 8 cycles each.
- R0 and R2, 32 MiB nominal 2 MiB/s write ceiling, 5 cycles each.

Every cycle verifies byte count and incremental SHA, waits for URLSession
invalidation and delegate destruction, explicitly releases the staged reader,
proves its owned child is absent, then waits 250 ms. No profiler, pause, forced
memory pressure, malloc pressure relief, cache flush, or selected retries.
Record transfer peak RSS/footprint and settled RSS/footprint/live+reserved malloc,
open FD count, callback size and measured duration.

Provisional composite review thresholds, fixed before measurements:

- Excluding allocator-establishing cycle 1: settled RSS slope <=1 MiB/cycle;
  settled footprint slope <=0.5 MiB/cycle.
- Median earliest versus latest non-overlapping stable window: use 3+3 cycles
  when at least six stable cycles exist, otherwise 2+2 cycles. RSS growth <=8
  MiB; footprint growth <=4 MiB; live malloc growth <=2 MiB.
- Maximum settled RSS increase from run baseline <=64 MiB; every cycle transfer
  peak delta <=64 MiB; open FD growth <=2.
- All lifecycle, bytes, SHA and cleanup checks must pass.

All four scenarios must pass to become eligible for human review. PASS is only a
recommendation to replace the rejected body-size RSS-slope criterion with a
composite gate. The official old gate remains FAIL unless the user separately
approves a new contract. Failure leaves Change B blocked.
