# mpv v0.41.0 CoreAudio callback lifetime modification

- Upstream: https://github.com/mpv-player/mpv/tree/v0.41.0
- Resulting build license: GPL-2.0-or-later
- Modified file: audio/out/ao_coreaudio.c
- Patch SHA-256: c458a9253288c0586780cfab46661614ae6d07e8d741a0814b63aad788303d80
- Added: 2026-09-25

CoreAudio property listeners now use copied blocks on a private serial queue.
A shared owner slot is revoked on that queue before listener removal and before
the ao object is freed. Already-running callbacks complete at this fence;
notifications retained by CoreAudio and delivered later see a null owner and do
nothing. Device-change notifications remain enabled during normal playback.
The change also ignores redundant unregister calls when no listener is held.

The regression harness in Scripts/test-coreaudio-hotplug.py extracts the actual
upstream and patched callback functions. AddressSanitizer detects the old stale
callback use-after-free; the patched path passes 100 register, in-flight drain,
and late-notification cycles. This is a controlled lifetime reproduction, not a
claim that physical lid close/wake testing has been completed.

build-libmpv.sh applies this patch; package-app.sh includes it and this notice in
the app's Legal/ModifiedSources directory. Existing release libraries may be used
for the other dependencies, but libmpv must be rebuilt with this patch.
