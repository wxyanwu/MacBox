# mpv v0.41.0 CoreAudio callback lifetime modification

- Upstream: https://github.com/mpv-player/mpv/tree/v0.41.0
- Resulting build license: GPL-2.0-or-later
- Modified file: audio/out/ao_coreaudio.c
- Patch SHA-256: 0edc87332f5c77210ced49e2ccd5cdd0b34bef6b012ebec2c6953de8ac225e80
- Added: 2026-09-25
- Updated: 2026-09-30

CoreAudio property listeners now use copied blocks on a private serial queue.
A shared owner slot is revoked on that queue before listener removal and before
the ao object is freed. Already-running callbacks complete at this fence;
notifications retained by CoreAudio and delivered later see a null owner and do
nothing. Device-change notifications remain enabled during normal playback.
The change also ignores redundant unregister calls when no listener is held.
Listener registration failures now revoke and remove any listeners registered
before the failure. Audio-output initialization failures also unregister before
mpv frees an incompletely initialized ao object.

The regression harness in Scripts/test-coreaudio-hotplug.py extracts the actual
upstream and patched callback functions. AddressSanitizer detects the old stale
callback use-after-free; the patched path passes 100 register, in-flight drain,
and late-notification cycles, plus partial registration and audio-output init
failure cases. This is a controlled lifetime reproduction, not a claim that
physical Bluetooth switching or lid close/wake testing has been completed.

build-libmpv.sh applies this patch; package-app.sh includes it and this notice in
the app's Legal/ModifiedSources directory. Existing release libraries may be used
for the other dependencies, but libmpv must be rebuilt with this patch.
