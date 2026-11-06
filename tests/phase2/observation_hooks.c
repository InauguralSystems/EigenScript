/* observation_hooks.c: the test-only LD_PRELOAD shim for the R1.6 per-builtin
 * behaviour table (#1758, ruling A4). It starts from the blind bar critic's
 * observation_hooks.c (2026-10-20). EigenScript's source and binary are
 * unchanged: the runtime dlopen()s SDL and SDL_mixer and dlsym()s each entry
 * point, so interposing dlsym() reaches them, and clock_gettime() is
 * interposed directly.
 *
 * One hook per process, chosen by R16_HOOK:
 *   pcm     SDL_QueueAudio: log the int16 samples actually delivered.
 *   mix     SDL_OpenAudioDevice: wrap the playback callback (EigenScript's
 *           own channel mixer) and log the first non-silent buffer it
 *           delivers.
 *   mixvol  Mix_VolumeMusic: log the volume passed to SDL_mixer.
 *   clock   clock_gettime(CLOCK_MONOTONIC): answer 9007199 s 254740993 ns,
 *           that is 2^53 + 1 ns.
 *   events  SDL_PollEvent: deliver mouse motion (17, -9), key scancode 4,
 *           and button 1 at (23, 42); after that the queue is empty.
 * Every hooked process first appends "hook-loaded <name>" to the file named
 * by R16_HOOK_LOG. Capture hooks append their payload lines there too. The
 * runner refuses a hook row whose log lacks the marker.
 * R16_PLANT=silence is a test mutation, used only by the plants: delivered
 * PCM becomes zeros, and the log records what was delivered.
 * Build: gcc -shared -fPIC -O0 -Wall -Wextra observation_hooks.c -ldl -o observation_hooks.so */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct {   /* the layout of EigenScript's own SDL_AudioSpec mirror (ext_gfx.c) */
    int freq;
    uint16_t format;
    uint8_t channels;
    uint8_t silence;
    uint16_t samples;
    uint16_t padding;
    uint32_t size;
    void (*callback)(void *, uint8_t *, int);
    void *userdata;
} HookAudioSpec;

static int hook_is(const char *name) {
    const char *h = getenv("R16_HOOK");
    return h && strcmp(h, name) == 0;
}

static void hook_log(const char *fmt, const int16_t *s, int n) {
    const char *path = getenv("R16_HOOK_LOG");
    if (!path || !path[0]) return;
    FILE *f = fopen(path, "a");
    if (!f) return;
    fputs(fmt, f);
    for (int i = 0; i < n; i++) fprintf(f, " %d", s[i]);
    fputc('\n', f);
    fclose(f);
}

__attribute__((constructor)) static void hook_loaded(void) {
    const char *h = getenv("R16_HOOK");
    if (!h || !h[0]) return;
    char line[64];
    snprintf(line, sizeof line, "hook-loaded %s", h);
    hook_log(line, NULL, 0);
}

static int silence_plant(void) {
    const char *p = getenv("R16_PLANT");
    return p && strcmp(p, "silence") == 0;
}

/* pcm: SDL_QueueAudio(dev, data, len) */
static int (*real_queue)(uint32_t, const void *, uint32_t);
static int capture_queue(uint32_t dev, const void *data, uint32_t len) {
    void *out = (void *)data;
    void *zeros = NULL;
    if (silence_plant()) { zeros = calloc(len ? len : 1, 1); out = zeros; }
    int n = (int)(len / 2);
    char head[64];
    snprintf(head, sizeof head, "SDL_QueueAudio %d:", n);
    hook_log(head, (const int16_t *)out, n < 8 ? n : 8);
    int rc = real_queue(dev, out, len);
    free(zeros);
    return rc;
}

/* mix: wrap the playback callback that SDL_OpenAudioDevice registers */
static uint32_t (*real_open)(const char *, int, const HookAudioSpec *, HookAudioSpec *, int);
static void (*real_cb)(void *, uint8_t *, int);
static int mix_logged;
static void wrapped_cb(void *ud, uint8_t *stream, int len) {
    real_cb(ud, stream, len);
    if (silence_plant()) memset(stream, 0, (size_t)len);
    if (mix_logged) return;
    const int16_t *s = (const int16_t *)stream;
    int n = len / 2;
    for (int i = 0; i < n; i++) {
        if (s[i] != 0) {
            hook_log("mix:", s, n < 8 ? n : 8);
            mix_logged = 1;
            return;
        }
    }
}
static uint32_t wrap_open(const char *device, int iscapture, const HookAudioSpec *desired,
                          HookAudioSpec *obtained, int allowed) {
    if (iscapture || !desired || !desired->callback) return real_open(device, iscapture, desired, obtained, allowed);
    HookAudioSpec spec = *desired;
    real_cb = spec.callback;
    spec.callback = wrapped_cb;
    return real_open(device, iscapture, &spec, obtained, allowed);
}

/* mixvol: Mix_VolumeMusic(volume) */
static int (*real_volume)(int);
static int capture_volume(int volume) {
    char line[64];
    snprintf(line, sizeof line, "Mix_VolumeMusic %d", volume);
    hook_log(line, NULL, 0);
    return real_volume(volume);
}

/* events: SDL_PollEvent(SDL_Event *); EigenScript's SDL_Event mirror is 64 bytes */
static int injected_poll(void *out) {
    static int seq = 0;
    uint32_t *u = out;
    int32_t *s = out;
    memset(out, 0, 64);
    switch (seq++) {
    case 0: u[0] = 0x400; s[5] = 17; s[6] = -9; return 1;                       /* SDL_MOUSEMOTION */
    case 1: u[0] = 0x300; s[4] = 4; return 1;                                    /* SDL_KEYDOWN, scancode */
    case 2: u[0] = 0x401; ((uint8_t *)out)[16] = 1; s[5] = 23; s[6] = 42; return 1; /* SDL_MOUSEBUTTONDOWN */
    default: return 0;
    }
}

static void *(*real_dlsym)(void *, const char *);
void *dlsym(void *handle, const char *name) {
    if (!real_dlsym) real_dlsym = dlvsym(RTLD_NEXT, "dlsym", "GLIBC_2.2.5");
    void *p = real_dlsym(handle, name);
    if (!p) return p;
    if (hook_is("events") && strcmp(name, "SDL_PollEvent") == 0) return (void *)injected_poll;
    if (hook_is("pcm") && strcmp(name, "SDL_QueueAudio") == 0) { real_queue = p; return (void *)capture_queue; }
    if (hook_is("mix") && strcmp(name, "SDL_OpenAudioDevice") == 0) { real_open = p; return (void *)wrap_open; }
    if (hook_is("mixvol") && strcmp(name, "Mix_VolumeMusic") == 0) { real_volume = p; return (void *)capture_volume; }
    return p;
}

int clock_gettime(clockid_t clockid, struct timespec *ts) {
    static int (*real_clock)(clockid_t, struct timespec *);
    if (hook_is("clock") && clockid == CLOCK_MONOTONIC) {
        ts->tv_sec = 9007199;
        ts->tv_nsec = 254740993;
        return 0;
    }
    if (!real_clock) real_clock = dlvsym(RTLD_NEXT, "clock_gettime", "GLIBC_2.17");
    return real_clock(clockid, ts);
}
