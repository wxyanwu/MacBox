# 9B.3B first gate — URLSession memory feasibility

Test-only, loopback-only real URLSessionDataDelegate → frozen Change A. No
production downloader/API, parser, HTTPClient, Repository or database changes.
If this first gate fails, stop; do not finish or ship the general downloader.

Preregistered method (before measurements):

- 1/8/16/32 MiB, five independent Release XCTest processes for every size/mode.
- Fast writer and intentional 2 MiB/s writer, identical code except rate.
- 64 KiB fixed warm-up. Independent server; fixed synthetic byte sequence.
- No full-response client fixture/oracle Data; incremental SHA-256 check.
- Writer slows by bytes, not callback count. Serial delegate synchronous writes.
- 10 ms RSS/footprint sampling with fixed-capacity observer storage.
- No build/package or other benchmark in parallel with the matrix.
- Measure baseline, peak, transferred/released RSS, callback count/max size,
  byte counts, checksums, transfer time. Retain all raw samples and logs.
- For each mode: median peak RSS delta(32 MiB) minus delta(1 MiB) <= 8 MiB;
  least-squares slope over the four median deltas <= 0.20 MiB/MiB;
  each run's peak incremental RSS <= 64 MiB.
- Near-complete-response memory accumulation is FAIL, even without Data.append.
- Uncontrolled/noisy evidence is INCONCLUSIVE, not PASS. No selective reruns or
  threshold adjustment. Failure is not permission to switch networking designs.

The observer baseline includes fixed warm-up but reports process high-water RSS
too. Sampling may miss brief peaks; no wire-buffer or arbitrary-macOS guarantee.
Server socket write completion does not imply client consumption. Slow-mode
server slowdown may be evidence of pressure, not a failed fast-producer setup.

The XCTest entry skips unless explicitly invoked with the harness's synthetic
environment. Run it only from an immutable disposable source copy. Test roots use
Change A's receipt-based fixture; the harness never recursively deletes a path.

Use run.py --xctest <release XCTest executable> --output <new directory inside
an existing canonical /private/tmp/OKVideoMac-9B.* root>. No real URLs accepted.

## 9B.3 promoted chain gate

`run_9b3_chain.py` exercises the reviewed download-task implementation through
the plain/gzip parser boundary. It generates a deterministic 200,000-programme
fixture, runs the gzip network -> staging file -> synchronous bounded-batch
parser chain in three fresh Release XCTest processes, and requires the matching
programme digest. The same expanded plain XML is larger than 32 MiB and must be
rejected by download admission. No database, Repository, cache or App path is
opened.

The gate samples process RSS/footprint every 10 ms and requires every run to
stay within a 64 MiB incremental ceiling. This is an application regression
gate for the current Foundation implementation, not a claim that Foundation's
temporary file or internal networking buffers have an application-provable
strict maximum between progress callbacks.

Run it only after building a Release XCTest bundle with testing enabled:

    swift build -c release --build-tests -Xswiftc -enable-testing ...
    python3 run_9b3_chain.py --xctest <bundle> --output /private/tmp/OKVideoMac-9B.<id>/9B3ChainFinal
