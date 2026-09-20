# 9C.3 importer acceptance probes

These tools exercise the internal importer; they do not modify App settings or the user's EPG cache. See `Docs/EPG_9C3_IMPLEMENTATION_CONTRACT.md` for the frozen gates and `Docs/EPG_9C3_IMPLEMENTATION_REPORT.md` for results.

## Release matrix

Build `OKVideoKitPackageTests.xctest` in Release, then:

```sh
python3 Tools/SourceAudit/EPGImportProbe/run.py \
  --bundle /private/tmp/okvideo-9c3-swiftpm/arm64-apple-macosx/release/OKVideoKitPackageTests.xctest \
  --output /private/tmp/OKVideoMac-9C3-Resources-NEW
```

The output directory must not exist. The driver freezes deterministic plain/gzip fixtures and hashes before starting 48 sequential independent client processes (four programme counts × two formats × cold/warm × three repeats). The loopback server is a separate process. It never proxies requests to upstream services. Do not compile or run other test suites during resource sampling.

The driver records the binary hash, platform, every result and scale checks, and stops on the first failure. Preserve failed output and choose a new directory for a rerun. A skipped XCTest without explicit inputs is not a resource-gate pass.

The XCTest measures RSS and `phys_footprint` every 10 ms, file sizes and FD count every 100 ms plus boundary samples. Files counted include Foundation's current download/pinned inode (delegate byte count), owned staging, SQLite DB/WAL/SHM. It drains bounded GC and samples another second. After sampling, a streaming SQL cursor hashes every programme against the external oracle. Ordinary query timings are measured separately; warm runs also query the prior active snapshot during refresh.

## Supplemental gates

Run each with the same Release `xctest` executable and the relevant test selector:

- `EPGImportAcceptanceTests/testReleaseRepeatedLifecycleAndChannelMetadataGate`: set `EPG9C3_LIFECYCLE_FIXTURE` to the matrix's `50000/fixture.xml` and `EPG9C3_LIFECYCLE_OUTPUT` to a fresh JSON path. Runs twelve success/failure/cancel cycles, checks reclamation and bounded settled memory/disk/FD growth, then imports 40K metadata facts. Local stop latency and network-cancel-to-drained-return latency are reported separately.
- `EPGImportAcceptanceTests/testPublicXMLTVMatchesLegacyOracle`: set `EPG9C3_PUBLIC_FILE` to a captured XML or gzip file. The legacy parser is the oracle; the actual downloaded-file/importer chain receives the exact captured bytes from loopback HTTP. Every programme and all declared channel-name/ID matches are compared, plus Now/Next samples. Freeze provenance/hashes independently before running.

Use the full selector prefix `OKVideoPersistenceTests.`. Each test uses fresh private staging/cache roots and removes only its own files. The public-sample test intentionally collects a small oracle outside resource measurements. It does not establish availability of the original remote endpoint.

## 9C.4 production matrix

`run_9c4_production.py` uses the same deterministic fixture generator and Release
test bundle, but exercises `EPGProductionRepository` → `EPGProductionService` →
network/import/SQLite → finite Now/Next/window DTO → maintenance/close. It runs
the same 48-process matrix with the frozen 48 MiB absolute and 8 MiB scale gates,
and reports both the one-second peak window and five-second settled deltas.
