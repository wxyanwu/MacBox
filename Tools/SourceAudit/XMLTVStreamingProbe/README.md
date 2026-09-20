# 9B incremental import verification

Developer-only executable, no App/startup/Repository integration. Uses the
`XMLTVStreaming` SPI with a synchronous tentative sink. No SQLite, user data,
network or recursive cleanup. Files must be in an explicit canonical 9B scratch
root. The caller retains the run directory; this tool does not delete it.

9B.1 tests plain local files; 9B.2 adds explicit `--mode gzip` to the runner
(or a final `gzip` argument to the executable). The sink writes length-prefixed 9A programme
rows incrementally; after the document succeeds, Python combines the returned
channel metadata and those rows to check the ORIGINAL independent generator's
full semantic SHA-256. It never reconstructs an in-memory programme array.
Sink output is not a cache or a format proposed for production persistence.

`Resources.swift` is a byte-identical reuse of the frozen 9A sampler; changes to
9B must not alter 9A baseline tooling. 10ms samples may miss short peaks, kernel
RSS high water is cumulative, and file-backed staging does have system I/O cost.
This is a local plain/gzip-file parse/sink measurement, NOT an end-to-end HTTP/SQLite
performance claim. Channel metadata/cardinality can still affect memory.

Run Release builds/tests from a disposable frozen SOURCE COPY with an external
scratch build directory. Never execute recursive-cleanup tests on the working
tree. Run resource measurements serially, after all builds have completed.

New SPI batches default to 512 records AND 1MiB estimated field bytes. A record
larger than the explicitly selected byte budget rejects that new import; it is
not silently truncated/dropped and does not change the legacy Data API. Estimation
is UTF-8 title/channel bytes + 64 per record, not a promise about actual RSS.

The sink must process/release each batch before returning and cooperate with
cancellation. A caller which itself retains all batches defeats the memory
contract. No asynchronous queue or unbounded `AsyncStream` is used. Cancellation
of an arbitrary non-cooperative/blocking sink is not claimed to be interruptible.

The new SPI scopes Foundation date-parsing temporaries with an autoreleasepool.
A controlled 10K/200K experiment showed that batching alone still retained these
until parse completion. DateFormatter configuration/interpretation is unchanged;
the legacy collecting API does not enable this new lifetime boundary.

On any failure/cancellation `discardTentative()` runs once. Successful parsing
returns a summary only after EOF, document validity, byte/element/alias limits,
and final batch completion. A successful return is not permission to publish an
active Repository generation. Production staging/activation belongs to later work.

## 9B.2 complete gzip-stream policy

`parseGzipStream` validates every member through physical EOF, including CRC and
ISIZE. Combined uncompressed bytes must form one XMLTV document. A document split
across members is valid; empty members are allowed around it. Two complete XML
documents, corrupted/truncated members and all non-gzip suffixes (even zero
padding) fail. Unlike this explicit new SPI, the frozen production Data decoder
still stops after the first member. This boundary change was explicitly approved;
it is not described as byte-for-byte legacy acceptance compatibility.

The input buffer is 64 KiB plus bounded zlib state; no complete compressed or
expanded Data is retained. The compressed 32 MiB and expanded 64 MiB caps count
actual bytes across all members and cannot reset at each header. Batch limits,
raw programme limits, aliases and date semantics are shared with 9B.1.

Example (from a frozen disposable source copy, after its Release probe builds):

    python3 run_plain.py --mode gzip --binary /private/tmp/OKVideoMac-9B.ID/Build/release/XMLTVStreamingProbe --output /private/tmp/OKVideoMac-9B.ID/GzipMatrix

Both modes reuse the same original 9A generator and full semantic digest oracle.
The gzip summary separately reports compressed bytes, expanded bytes and members.
