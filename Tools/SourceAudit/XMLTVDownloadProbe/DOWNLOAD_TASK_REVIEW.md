# R3 URLSessionDownloadTask preregistered review

R3 is a developer-only feasibility experiment. It does not implement or
authorize the 9B.3 Change B downloader.

Foundation receives one deterministic 32 MiB identity-coded loopback response
with `URLSessionDownloadTask`. During `didFinishDownloadingTo`, the test copies
the Foundation-owned temporary file into frozen Change A ownership through one
fixed 64 KiB buffer. It never receives response-body `Data` callbacks and never
manually deletes Foundation's temporary file.

One fully invalidated and destroyed 64 KiB warm-up is followed by eight cycles
inside one fresh Release XCTest process. Every cycle must verify:

- HTTP status/content-coding/declared-length acceptance;
- total copied and read byte counts;
- incremental SHA-256;
- session invalidation and delegate destruction;
- explicit Change A staged-file release;
- Foundation temporary-file disappearance after its callback;
- no FD growth or owned staging residue.

Memory is sampled every 10 ms through transfer, then again 250 ms after all
ownership has been released. No profiler, pause, forced memory pressure,
pressure relief, cache flush, retry, parser, repository, or production caller is
allowed.

Pre-registered provisional thresholds are identical to B3G:

- discard allocator-establishing cycle 1;
- settled RSS slope <=1 MiB/cycle;
- settled physical-footprint slope <=0.5 MiB/cycle;
- median cycles 2-4 versus cycles 6-8: RSS growth <=8 MiB, footprint growth
  <=4 MiB, live malloc growth <=2 MiB;
- maximum settled RSS over run baseline <=64 MiB;
- every cycle transfer RSS increase <=64 MiB;
- open FD growth <=2;
- all correctness and cleanup assertions pass.

Failure stops R3. Passing only makes `URLSessionDownloadTask` eligible for a
separate Change B design review; it does not change the previously failed RSS
gate and does not authorize production wiring.
