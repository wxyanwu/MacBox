# Step 9A — XMLTV baseline and semantic oracle

Developer-only standalone Swift package. It is **not** an App dependency or startup hook.
It imports the existing OKVideoCore without changing its APIs or production limits.
There is no SQLite programme database, schema migration, provider request, or UI implementation.

## Reproduce

Use macOS + the project's Xcode toolchain, Python 3, and a new private temporary directory.
All paths below are placeholders; do not reuse a populated benchmark output directory.

```sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer swift test \
  --package-path Tools/SourceAudit/EPGBaseline --scratch-path /private/tmp/OKVideoMac-9A.YOURRUN/Build \
  -c release --disable-swift-testing
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Tools/SourceAudit/EPGBaseline -p 'test_*.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 Tools/SourceAudit/EPGBaseline/run_baseline.py \
  --binary /private/tmp/OKVideoMac-9A.YOURRUN/Build/release/EPGBaseline \
  --output /private/tmp/OKVideoMac-9A.YOURRUN/Baseline --repetitions 3
python3 Tools/SourceAudit/EPGBaseline/summarize.py /private/tmp/OKVideoMac-9A.YOURRUN/Baseline
```

The tests use XCTest. `--disable-swift-testing` avoids the current toolchain attempting
Swift Testing discovery through the executable target's main entry point after XCTest.
Do not interpret a nonzero test-runner exit as success merely because XCTest printed passes.

Run performance experiments serially, without an App build running beside them. OS disk
caches are deliberately not purged. The harness neither launches the App nor reads any
user database or cache. HTTP is limited to generated fixture files served on 127.0.0.1.
The HTTP client is the production `isolatedEphemeral()` client, not a shared-cookie session.

## Four deliverables

1. **Fixture generator** (`fixture.py`). Fixed seed/integer PRNG, fixed anchor, explicit UTC
   offset, deterministic XML escaping and Unicode, gzip `mtime=0`. Adjustable programme and
   channel counts, title length, alias count, overlap/gap ratio, duration, offset, time shift,
   and long programmes. The gzip library/version is recorded: byte-identical compression
   across arbitrary different zlib versions is not promised. No giant XML is checked in.
2. **Semantic oracle** (`Oracle.swift`, XCTest contracts and fixture.json). An independent
   generator computes a length-prefixed SHA-256 over every channel/alias/programme, plus
   sample exact expected Now/Next tuples and window intersection counts. The runner checks
   the production parser/index against those expected values, not only programme count.
   Matcher tests retain programme-only IDs even outside the proposed window. Unicode ID
   equality follows current Swift String semantics, not hypothetical SQLite BINARY keys.
3. **Stage curves** (raw JSON, Summary.json/Markdown). RSS, physical footprint, cumulative
   kernel peak RSS, before/after points, 10ms sampled maxima, per-stage timings and sample
   counts. Adjacent-scale and OLS RSS slopes are expressed as MiB per 10K programmes.
4. **Query distributions**. 120 timed batches per lookup category with p50/p95/max and a
   consumed checksum. Separate exact, normalized, ambiguous, unmatched, dense/sparse, gap
   and past-end cases. First-query n=1 is labelled, not presented as a reliable p95.

## Measurement modes and caveats

- `fetch`: exact production XMLTV HTTP request limits (32 MiB, no downgrade, timeout/retries),
  measuring a full Data response. Its legacy-named `programmeCount` output field is **bytes**.
- `staged`: local file read → decompress → parse/create guide → snapshot/index → queries →
  guide JSON encode/decode. Intermediate lifetimes are explicitly retained. This is a
  diagnostic overlap experiment, **not** the production peak. Parsing expanded XML avoids
  decompressing twice. Parse and guide creation cannot be separated without instrumenting
  production code, so they are one measured phase. Guide JSON excludes Repository Entry
  envelope; it is not claimed to be the exact disk-cache encode operation.
- `production`: existing EPGRepository.load → XMLTVService.fetch → parser → Entry JSON
  persist → EPGSnapshot. Production API calls, no lookalike replacement implementation.
- `cold`: a new process reads the previous successful production cache through repository.cached;
  includes Data/JSON decode and snapshot/index build. OS page cache is not flushed.
- `cancel`: 200K gzip production parser on a detached task, cancel requested after 50ms;
  records cancellation-to-return only. Not a promise about network/Repository cancellation.

Production/cold queries also check the independently generated expected tuples. Full guide
oracle allocations occur after staged measurements, and are excluded from import peaks.
Do not add stage peaks: arrays/strings may share storage; actual lifetime overlap must be
measured. The sampler may miss brief transients, and kernel RSS high water is cumulative.
Peak delta uses the same process's early baseline, not the entire GUI App's footprint.

The 50-channel × 6h window measurement is a **reference full-array intersection scan**.
There is no existing production window API. Its result/time is not a SQLite benchmark.
The production overlap selection differs from XMLTVGuide's old first-match helper; tests
explicitly preserve this distinction rather than silently choosing an oracle implementation.

## Limits and failure reporting

Each worker gets a 240-second harness deadline. Timeout means incomplete, not damaged XML.
Expected existing limit rejections are separate from passes; a cold cache test without a
successful preceding import is **not run**, never passed. Safety limits stay 32/64 MiB and
200K programme elements. Large plain XML may exceed the HTTP limit while the gzip response
fits; staged file parsing does not imply the same file was admitted by HTTP.

No user settings, credentials, streams, raw provider responses, or remote URLs are involved.
Run directories can contain synthetic XML, oracle records and disposable EPG JSON caches;
they do not contain real user data. No permanent UUID allocation or Registry writes occur.
Existing Source/channel/route identity, EPG matching, Player and UI remain frozen.

## Budgets and stop

9A reports measured current behavior and proposes future acceptance budgets. It does not
validate SQLite batch size, database/WAL quotas, or a retention policy's product suitability.
Those remain experiments for explicitly approved later phases. No 9B–9F or Full Guide.
