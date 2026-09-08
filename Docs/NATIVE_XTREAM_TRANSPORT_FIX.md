# Native Xtream transport and player utility panels

Date: 2026-09-08. Implementation and focused regression record.

## Scope and isolation

`ResolvedMedia.compatibilityPolicy` defaults to `existing`. Only Native Xtream
Live opts into `nativeXtreamLive`. Crossing this boundary destroys the old mpv
instance and creates a new one with remembered player settings. Existing-to-
existing playback retains its previous lifecycle, cache, format and transport
behavior. No libmpv/FFmpeg upgrade or provider persistence migration is included.

Native HTTP(S) loads resolve the current system HTTP proxy using CFNetwork.
The resolver honors entry-URL exclusions and environment `no_proxy`, supports
legacy HTTP proxy environment configuration when no system proxy is active,
and forces file URLs and loopback media bridges to direct mode. Explicit
FFmpeg `http_proxy` values cover both stream and HLS demux requests; clearing
mpv `http-proxy` alone does not reliably suppress environment fallback.
Proxy options are applied only to the isolated Native instance. Logs record
only routing mode, never proxy endpoints or credentials.

PAC and SOCKS are not newly implemented: unsupported system proxy types retain
legacy environment transport. Routing is selected for the entry URL; this is
not a full per-redirect/per-segment CFNetwork routing implementation. URLSession
is not used to pre-resolve ordinary media redirects; libmpv follows them itself.

Native loading gets a bounded 60-second deadline. Imported Live remains at
8 seconds and ordinary VOD at 30 seconds. Closing or switching during a pending
Native load releases its continuation and stops only that request, before a
successor can proceed through the lifecycle barrier.

## Complex HLS fallback

Only an existing fallback attempt with an m3u8 candidate can inspect a master:
10-second total GET deadline (independent of inactivity timeout), a response
bound strictly below 256 KiB, five redirects, no retry. Fetch time is
subtracted from that attempt's 60-second player budget. Successful first loads
make no additional manifest request. There is no third playback attempt and no
candidate reordering. A cached HLS-first catalog whose second candidate is TS
does not run this selector; this is deliberately not a universal HLS resolver.

Selection requires at least 12 variants and a supported H.264/AAC combination
up to 1080p/60. It preserves the selected rendition's audio, subtitles and closed
captions and resolves their relative URIs against the final manifest URL. Unknown
extensions, missing groups, unsupported codecs or malformed/oversized data keep
the original candidate. Small masters and media playlists remain untouched.

The reduced master exists only in memory (`lavf://data:` with explicit HLS
format). Media playlists, segments, keys and byte ranges remain libmpv requests.
This avoids the known silent-video failure from loading Apple v9 by itself.
It may choose a lower maximum resolution than the unmodified master, solely in
this recovery path. It does not promise immediate startup of Apple's full master:
the original candidate may first consume its deadline.

Local diagnostic rollback keys (default false) are
`player.disableNativeXtreamTransport` and `player.disableNativeXtreamHLSFallback`.
They require restarting playback and do not change imported configuration.

## Utility panel layout

The shared panel wrapper measures natural content height, caps it to the
available viewport (at most 560 points including chrome), aligns content at the
top, and scrolls overflow. The old expanding max-height wrapper and fixed inner
subtitle/settings scroll heights were removed. This applies to episodes, audio,
subtitles and playback settings in regular windows, resized windows and fullscreen.

## Evidence

- OKVideoKit focused regression: 84 passed, zero failures.
- Historical App focused regression: 41 passed, zero skipped, zero failures, including
  existing TVBox/CatPaw policies, imported Live fallback, lifecycle ownership,
  Native cancellation, proxy bypass and compact window/panel layout.
- Apple reduced master through the actual app client and OpenGL renderer:
  1080p frame captured, selected audio track and progressing timeline; initial
  isolated gate completed in 7.006 seconds.
- Mux cross-host 302 through the actual app client and renderer: passed with
  system HTTP proxy, selected audio and progressing timeline.
- These network tests use public fixtures and an offscreen, muted test window.
  They do not constitute user-visible end-to-end verification of every provider.
- `xcodebuild build-for-testing` succeeded. LaunchServices could not start its
  test bundle, so selected XCTest tests were run by an isolated app-shaped CLI
  host using the same built app module and bundled native libraries.
- An initial temporary test host lacked the XCTest framework search path and
  terminated in dyld before app code. Its executable name and framework paths
  were corrected; subsequent tests passed. That host is never a deliverable.

Release packaging, signature and installation results are recorded separately
with the generated artifact evidence; Debug products must not be installed.

For 0.6.0, external redirect fixture URLs are supplied only through the test environment (`OKVIDEOMAC_XTREAM_REDIRECT_FIXTURE_URL`); real Mock login URLs are not stored in source. Current full-suite counts and formal artifact gates are maintained in BUILDING and the release verification report.
