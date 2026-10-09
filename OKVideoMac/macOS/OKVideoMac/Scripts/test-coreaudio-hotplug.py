#!/usr/bin/env python3
"""Replay queued CoreAudio callbacks against original and patched mpv with ASan.
No audio device or system sleep setting is changed.
"""
import argparse, pathlib, subprocess, tarfile, tempfile
p = argparse.ArgumentParser()
p.add_argument("archive", type=pathlib.Path)
a = p.parse_args()
patch = pathlib.Path(__file__).resolve().parent.parent / "Patches/mpv-0.41.0-coreaudio-hotplug-lifetime.patch"
fixture = r'''
#include <CoreAudio/CoreAudio.h>
#include <dispatch/dispatch.h>
#include <Block.h>
#include <stdlib.h>
#include <stdio.h>
#include <assert.h>
#include <stdbool.h>
struct coreaudio_cb_sem { int unused; };
struct priv {
    int hotplug_cb_registration_times;
    int hotplug_registered_properties;
    dispatch_queue_t hotplug_queue;
    AudioObjectPropertyListenerBlock hotplug_listener;
    dispatch_block_t hotplug_cancel;
    void *audio_unit;
    int device;
    bool change_physical_format;
    uint64_t hw_latency_ns;
    dispatch_queue_t queue;
};
struct ao {
    struct priv *priv;
    volatile int log;
    int format, init_flags, samplerate, device_buffer;
    char *redirect, *device;
};
static int delivered;
static int add_calls, remove_calls, fail_on_add;
static bool fail_chmap;
static const AudioObjectPropertyAddress empty_address = {0};
#define MP_VERBOSE(ao, ...) do { assert((ao)->log == 123); delivered++; } while (0)
#define MP_ERR(ao, ...) ((void)0)
#define MP_ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define AO_INIT_EXCLUSIVE 1
#define CONTROL_ERROR -1
#define CONTROL_OK 0
static char *mp_tag_str(unsigned x) { return "test"; }
static bool af_fmt_is_pcm(int format) { return true; }
static bool reinit_device(struct ao *a) { assert(a->log == 123); return true; }
static void reinit_latency(struct ao *a) { assert(a->log == 123); }
static void ao_hotplug_event(struct ao *a) { assert(a->log == 123); }
static void init_physical_format(struct ao *a) { assert(a->log == 123); }
static bool ca_init_chmap(struct ao *a, int device) { return !fail_chmap; }
static void ca_fill_asbd(struct ao *a, AudioStreamBasicDescription *asbd) { *asbd = (AudioStreamBasicDescription){0}; }
static AudioChannelLayout *ca_get_acl(struct ao *a, size_t *size) { *size = 0; return NULL; }
static bool init_audiounit(struct ao *a, AudioStreamBasicDescription asbd, AudioChannelLayout *layout, size_t size) { return true; }
static void talloc_free(void *p) { free(p); }
static int64_t av_rescale(int64_t a, int64_t b, int64_t c) { return 0; }
static bool register_hotplug_cb(struct ao *);
static void unregister_hotplug_cb(struct ao *);
static AudioObjectPropertyListenerBlock retained;
static dispatch_queue_t delivery_queue;
static AudioObjectPropertyListenerProc legacy;
static void *legacy_ctx;
static OSStatus mock_add(AudioObjectID o, const AudioObjectPropertyAddress *a,
                         AudioObjectPropertyListenerProc cb, void *ctx) {
    legacy = cb; legacy_ctx = ctx; return noErr;
}
static OSStatus mock_remove(AudioObjectID o, const AudioObjectPropertyAddress *a,
                            AudioObjectPropertyListenerProc cb, void *ctx) { return noErr; }
static OSStatus mock_add_block(AudioObjectID o, const AudioObjectPropertyAddress *a,
                               dispatch_queue_t q, AudioObjectPropertyListenerBlock cb) {
    if (++add_calls == fail_on_add) return -1;
    if (!retained) { retained = Block_copy(cb); delivery_queue = q; dispatch_retain(q); }
    return noErr;
}
static OSStatus mock_remove_block(AudioObjectID o, const AudioObjectPropertyAddress *a,
                                  dispatch_queue_t q, AudioObjectPropertyListenerBlock cb) {
    remove_calls++; return noErr;
}
#define AudioObjectAddPropertyListener mock_add
#define AudioObjectRemovePropertyListener mock_remove
#define AudioObjectAddPropertyListenerBlock mock_add_block
#define AudioObjectRemovePropertyListenerBlock mock_remove_block
'''
main = r'''
int main(void) {
 for (int i = 0; i < 100; i++) {
    struct ao *a = calloc(1, sizeof(*a)); a->priv = calloc(1, sizeof(*a->priv)); a->log = 123;
    assert(register_hotplug_cb(a)); assert(register_hotplug_cb(a));
    if (retained) dispatch_sync(delivery_queue, ^{ retained(0, &empty_address); });
    else legacy(0, 0, &empty_address, legacy_ctx);
    unregister_hotplug_cb(a); // One live registration remains.
    int before = delivered;
    if (retained) dispatch_async(delivery_queue, ^{ retained(0, &empty_address); });
    else legacy(0, 0, &empty_address, legacy_ctx);
    unregister_hotplug_cb(a); // Must drain and revoke before the owner is freed.
    assert(delivered == before + 1);
    free(a->priv); free(a);
    before = delivered;
    // Model notifications queued by CoreAudio before listener removal.
    if (retained) {
        dispatch_sync(delivery_queue, ^{ retained(0, &empty_address); });
        Block_release(retained); retained = NULL;
        dispatch_release(delivery_queue);
    } else legacy(0, 0, &empty_address, legacy_ctx);
    assert(delivered == before);
 }
 // A partial listener registration must revoke the callback before freeing ao.
 for (int failed_add = 1; failed_add <= 2; failed_add++) {
    struct ao *a = calloc(1, sizeof(*a)); a->priv = calloc(1, sizeof(*a->priv)); a->log = 123;
    add_calls = remove_calls = 0; fail_on_add = failed_add;
    assert(!register_hotplug_cb(a));
    assert(a->priv->hotplug_cb_registration_times == 0);
    assert(remove_calls == failed_add - 1);
    free(a->priv); free(a);
    int before = delivered;
    if (retained) {
        dispatch_sync(delivery_queue, ^{ retained(0, &empty_address); });
        Block_release(retained); retained = NULL;
        dispatch_release(delivery_queue);
    }
    assert(delivered == before);
 }
 // The real coreaudio init registers a listener before channel-map setup.
 // A failed setup must also unregister before ao.c frees the uninitialised ao.
 struct ao *a = calloc(1, sizeof(*a)); a->priv = calloc(1, sizeof(*a->priv)); a->log = 123;
 add_calls = remove_calls = fail_on_add = 0; fail_chmap = true;
 assert(init(a) == CONTROL_ERROR);
 assert(a->priv->hotplug_cb_registration_times == 0);
 assert(remove_calls == 2);
 free(a->priv); free(a);
 int before = delivered;
 dispatch_sync(delivery_queue, ^{ retained(0, &empty_address); });
 assert(delivered == before);
 Block_release(retained); retained = NULL;
 dispatch_release(delivery_queue);
 puts("PASS: 100 registration / in-flight drain / late-delivery lifecycles");
 puts("PASS: partial registration and failed coreaudio init revoke listeners");
}
'''
with tempfile.TemporaryDirectory(prefix="tvbox-hotplug-test-") as tmp:
 root = pathlib.Path(tmp)
 with tarfile.open(a.archive) as archive:
  original = archive.extractfile("mpv-0.41.0/audio/out/ao_coreaudio.c").read().decode()
 path = root / "audio/out/ao_coreaudio.c"
 path.parent.mkdir(parents=True); path.write_text(original)
 subprocess.run(["patch", "-s", "-p1", "-i", str(patch)], cwd=root, check=True)
 for name, source in [("original", original), ("patched", path.read_text())]:
  init_section = source[source.index("static int init(struct ao *ao)"):source.index("static void init_physical_format(struct ao *ao)\n{")]
  section = source[source.index("static OSStatus hotplug_cb(AudioObjectID id"):source.index("#define OPT_BASE_STRUCT")]
  c = root / (name + ".c"); c.write_text(fixture + init_section + section + main)
  exe = root / name
  subprocess.run(["clang", "-fblocks", "-fsanitize=address", "-g", "-O1", str(c), "-o", str(exe)], check=True)
  result = subprocess.run([str(exe)], capture_output=True, text=True)
  if name == "original":
   assert result.returncode != 0 and "heap-use-after-free" in result.stderr, "Baseline must reproduce stale callback memory access"
   print("PASS: original callback reproduces heap-use-after-free under ASan")
  else:
   assert result.returncode == 0, result.stderr
   print(result.stdout.strip())
