# B1 response-to-download admission experiment

Test-only; R3, Change A and production remain frozen. Preregister before runs.

Order: compile + Change A tests; real loopback response/coding/cancellation
matrix; only if matrix passes, 32 MiB x 8 repeated-session memory screen.
No automatic full downloader or production integration on failure.

Strict probe: dataTask receives response; validate 200, absence of Content-Range,
identity coding and declared size <=32 MiB; reply becomeDownload. Any body Data
callback is an error. Operation cancellation is sticky across task replacement.
Inject cancellation before disposition, after disposition/before didBecome, and
after installation of the replacement task. Each injection is synchronous at
a named callback boundary, never a timing sleep. Assert event order, cancellation,
one completion, no caller ownership and eventual session/delegate teardown.

Temporary file: pin read-only O_NOFOLLOW fd before callback returns, transfer fd
to serial copy worker, copy at most 64 KiB per iteration through Change A, close
fd explicitly. HTTP completion and copy completion must both precede the only
finishAndTransfer. Never manually remove Foundation files.

Fixtures: plain XML, HTTP gzip XML, HTTP br XML, opaque .xml.gz without encoding,
and HTTP gzip containing a .xml.gz (two layers). Strict paths reject encoded
responses. Separate loopback-only observation instances allow coding solely to
measure exposed response headers and final bytes. Record wire/entity/XML hashes
separately and do not claim control over wire decoding.

Additional strict rejection fixtures: 404, 206, Content-Range on 200, declared
33 MiB. All strict rejection rows require no conversion, no file handoff, and
zero body callbacks. All fixture names/log metadata are synthetic only.

Memory screen: same R3 thresholds, no profiler or forced pressure, one fully
released 64 KiB warmup, then 8 cycles with 250 ms settlement. Discard cycle 1;
compare disjoint cycles 2-4 and 6-8. RSS slope <=1 MiB/cycle; footprint slope
<=0.5; RSS/footprint/live-heap window growth <=8/4/2 MiB; settled RSS delta <=64;
per-transfer peak RSS delta <=64; FD growth <=2. Include pinned-file copying in
the measured operation. Passing this screen is not the full 1/8/16/32 MiB gate.

Record XCTest count separately from fixture rows and memory cycles. Preserve all
raw results in the repository evidence directory as well as disposable output.
