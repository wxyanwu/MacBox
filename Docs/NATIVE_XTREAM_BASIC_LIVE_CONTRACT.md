# Native Xtream Basic Live — implementation contract

Status: contracts frozen for staged local implementation, 2026-09-08.
This is not a release authorization or a claim that end-to-end acceptance passed.

## Scope and compatibility

Extend the current native Live browser/player. Do not replace the imported
M3U/TXT/JSON pipeline, change Version/Build, publish, tag, push, merge, notarize,
or introduce a proxy, Android/Node bridge, external IPTV SDK, or multi-account
aggregation. Movies + Series + Search remain the core requirement; Basic Live
must not destabilize existing imported Live playback.

Only the currently active Xtream provider contributes one dynamic Live source.
No `StoredLiveSource`, imported `rawData`, generated M3U, or persisted raw API
response is created for it. Catalogs are in-memory snapshots. Existing imported
source bytes, IDs, parser behavior, refresh, export and deletion remain unchanged.
There is currently no persisted last-Live-channel feature to migrate; do not
invent automatic playback restoration in this change.

## Identity and data boundaries

- `LiveSourceID`: `.imported(UUID)` / `.xtream(UUID)`; no shared bare-UUID key for
  the two domains. Imported-only persistence/probe/EPG dictionaries may retain
  their existing UUID keys behind an explicit `.imported` dispatch.
- `LiveSourceDescriptor`: pure Equatable/Sendable data: identity, name, kind and
  refresh/export/EPG capabilities. No closures, credentials or request URLs.
- `LiveCatalogSnapshot`: display groups/channels, not a fake `LiveSourceFormat`.
- Existing group ID defaults to group name; existing channel ID remains
  `groupName::name`. Optional explicit IDs allow Xtream identities based only
  on provider/category and provider/stream ID. Channel identity excludes category,
  display names, password and output format. Category selection uses group ID.
- `LiveStreamTarget`: exactly `.direct(URL)` or `.provider(PlaybackResourceReference)`.
  Never use placeholder URLs or two independently mutable optional targets.
  Legacy URL construction, stream identity and Codable URL fields retain their
  current semantics. A provider target has no direct URL; URL consumers must
  dispatch explicitly. New versions/kinds fail closed, never decode as direct.
- `StoredLiveChannelReference` recognizes legacy strings as opaque exact values
  (their separators cannot be split unambiguously), and versioned Xtream objects
  containing provider UUID and stream ID. Do not encode display names or URLs.
- Keep `live.favoriteChannels` and `live.deletedChannels` unchanged for imported
  sources. New Xtream references use `live.favoriteReferences.v1` and
  `live.hiddenReferences.v1`; unsupported stored objects are preserved, not
  rewritten or interpreted as URLs. Refresh/auth failures never remove favorites.

## Formal playback reference

The existing reference is episode-only. Extend it with explicit `ResourceKind`
(`episode` / `live`), preserving schema-1 episode encoding/decoding and callers.
Live is schema 2, explicitly tagged `live`, with a formal versioned Xtream Live
locator encoding provider UUID, stream ID and `ts` / `m3u8`. Live encoding omits
`sourceIdentity` and `episodeIdentity`; their legacy in-memory slots are empty
and never carry Live semantics. Strict validation binds provider, site, locator,
version and kind; reject malformed/unknown variants. Point-of-use persistence
sanitization branches explicitly by kind. Movie/Series APIs reject Live refs.

Add narrow Live APIs on the native Xtream provider, not a new generic player or
fake Movie/Series detail. `direct_source` is ignored in this version. Xtream EPG
is unsupported (`supportsEPG=false`, no XMLTV/short-EPG requests or saved EPG URL).
Untrusted artwork is filtered or omitted; never cache credential-bearing URLs.

## Network and player policy

Use a dedicated opt-in Xtream ephemeral HTTP client, with no shared cookies,
Cookie acceptance, disk cache, URL credential storage or persisted response body.
The general HTTP initializer/default behavior is unchanged. Bounded responses
remain catalog-only opt-in. The centralized configurable 64 MiB initial default
is a safety setting, not a protocol limit.

Browsing fetches metadata only: no playback URL materialization, media HEAD/Range
preflight or background channel probe. Imported-source probes stay unchanged.
On click, resolve the selected provider reference using current Keychain
credentials. Resolved URLs/headers belong only to runtime media objects and never
to catalogs, settings, history, export or diagnostics.

Reuse current playback request ownership. Before and after async work, check
request ID, current provider and credential/configuration generation. Switching
or deleting an account invalidates its requests/catalog and releases its media;
late completion cannot publish state. A password update preserves identity but
invalidates pending old-generation work. Do not create parallel warm-up streams.

Xtream recovery is serial and limited to at most the two formats of the selected
channel; never advance through other channels. Authentication/disabled/expired
results stop recovery. Temporary failures do not hide channels or remove favorites.
No live-source UI action may delete account credentials; account deletion retains
the existing account manager's partial-failure handling.

Keep existing mpv `config=no`/`terminal=no`. Explicitly disable path-bearing
watch history/watch-later/resume/scripts/log-file where supported by the bundled
mpv, with real-library initialization tests before adoption. Keep TLS validation;
do not downgrade HTTPS or claim URLSession policies govern libmpv requests.

## Phase gates

1. Compatibility contracts/models and isolated HTTP: old parser/loader/identity/
   Codable/persistence tests pass; explicit provider targets cannot reach direct
   URL probes; all affected app call sites compile before expanding.
2. Dynamic catalog/browser: identity stability and account separation; classification,
   search, favorite/hide/refresh behavior; no media request during browsing; stale
   catalog results cannot overwrite a new provider; imported UI remains usable.
3. JIT playback and lifecycle: standard TS/HLS paths; request/generation ownership;
   same-channel bounded recovery; no parallel warm-up; credential changes/deletion
   cannot resurrect old playback; security options initialize in real libmpv.
4. Acceptance: app/package regressions, normal UI entry to real local media,
   fast switching and error cases, secret scans of structured stores/logs/exports.
   Separate automated, black-box, platform and environment-blocked evidence.

Do not proceed past a failed phase by weakening tests. If a contract would require
broad reconstruction, stop expansion and report it. Deliver only a verified local
RC/implementation report. Follow the repository's verified Release installation
workflow; never replace Desktop with an unverified bundle. System Keychain
authorization, if needed, is a user action and is never bypassed.
