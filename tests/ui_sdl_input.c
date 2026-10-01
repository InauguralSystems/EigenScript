/* Real SDL queue -> ext_gfx decoder acceptance (#1263). */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "eigs_embed.h"
extern EigsValue *builtin_gfx_poll(EigsValue *arg);
extern EigsValue *eigs_gfx_decode_sdl_event(const void *event);

typedef unsigned char U8; typedef unsigned short U16; typedef unsigned int U32; typedef int S32;
typedef struct { S32 scancode, sym; U16 mod; U32 unused; } Keysym;
typedef struct { U32 type, ts, wid, which, state; S32 x, y, xrel, yrel; } Motion;
typedef struct { U32 type, ts, wid, which; U8 button, state, clicks, pad; S32 x, y; } Button;
typedef struct { U32 type, ts, wid, which; S32 x, y; U32 direction; } Wheel;
typedef struct { U32 type, ts, wid; U8 event, p1, p2, p3; S32 data1, data2; } Window;
typedef struct { U32 type, ts, wid; U8 state, rep, p2, p3; Keysym keysym; } Key;
typedef union { U32 type; Motion motion; Button button; Wheel wheel; Window window; Key key; unsigned char pad[56]; } Event;

static int eval_ok(const char *src) {
    EigsValue *v = eigs_eval_string(src);
    if (!v) { fprintf(stderr, "ui SDL input FAIL: %s\n", eigs_last_error_message()); return 0; }
    eigs_value_release(v); return 1;
}
static int (*g_push)(Event *);
static int (*g_poll)(Event *);
static int (*g_peep)(Event *, int, int, U32, U32);
static void (*g_set_mod)(int);
static int g_next;
static EigsValue *host_push(EigsValue *arg) {
    Event e; (void)arg; memset(&e, 0, sizeof e);
    if (g_next == 0) while (g_poll(&e) == 1) { }
    memset(&e, 0, sizeof e);
    switch (g_next++) {
    case 0: e.key.type=0x300; e.key.keysym.scancode=82; e.key.keysym.mod=3; break;
    case 1: e.motion.type=0x400; e.motion.wid=1; e.motion.state=1; e.motion.x=321; e.motion.y=654; break;
    case 2: e.button.type=0x401; e.button.wid=1; e.button.button=3; e.button.x=111; e.button.y=222; break;
    case 3: e.button.type=0x402; e.button.wid=1; e.button.button=3; e.button.x=112; e.button.y=223; break;
    case 4: e.wheel.type=0x403; e.wheel.x=-2; e.wheel.y=5; break;
    default: e.window.type=0x200; e.window.event=6; e.window.data1=640; e.window.data2=480; break;
    }
    if (e.type >= 0x400 && e.type <= 0x403) g_set_mod(0x00c0 | 0x0300);
    if (g_push(&e) != 1) return eigs_value_new_null();
    Event queued;
    if (g_peep(&queued, 1, 2, e.type, e.type) != 1) return eigs_value_new_null();
    return eigs_gfx_decode_sdl_event(&queued);
}

int main(void) {
    EigsState *st = eigs_open(); void *sdl;
    if (!st) return 1;
    sdl = dlopen("libSDL2-2.0.so.0", RTLD_NOW);
    if (!sdl) sdl = dlopen("libSDL2.so", RTLD_NOW);
    g_push = sdl ? (int (*)(Event *))dlsym(sdl, "SDL_PushEvent") : NULL;
    g_poll = sdl ? (int (*)(Event *))dlsym(sdl, "SDL_PollEvent") : NULL;
    g_peep = sdl ? (int (*)(Event *, int, int, U32, U32))dlsym(sdl, "SDL_PeepEvents") : NULL;
    g_set_mod = sdl ? (void (*)(int))dlsym(sdl, "SDL_SetModState") : NULL;
    if (!g_push || !g_poll || !g_peep || !g_set_mod) { fprintf(stderr, "ui SDL input FAIL: SDL event API unavailable\n"); return 1; }
    eigs_register_function("host_push_event", host_push);
    const char *src =
      "assert of [(gfx_open of [80, 60, \"ui-input-1263\"]) == 1, \"open\"]\n"
      "loop while (gfx_poll of null) != null:\n    ignore is 0\n"
      "e is host_push_event of null\nassert of [e.type == \"keydown\" and e.key == \"up\" and e.scancode == 82 and e.shift == 1 and e.ctrl == 0 and e.alt == 0, \"key fields\"]\n"
      "e is host_push_event of null\nassert of [e.type == \"mousemove\" and e.x == 321 and e.y == 654 and e.shift == 0 and e.ctrl == 1 and e.alt == 1, \"motion fields / #599 state offset\"]\n"
      "e is host_push_event of null\nassert of [e.type == \"mousedown\" and e.button == 3 and e.x == 111 and e.y == 222 and e.ctrl == 1 and e.alt == 1, \"button fields\"]\n"
      "e is host_push_event of null\nassert of [e.type == \"mouseup\" and e.button == 3 and e.x == 112 and e.y == 223 and e.ctrl == 1 and e.alt == 1, \"button-up fields\"]\n"
      "e is host_push_event of null\nassert of [e.type == \"wheel\" and e.x == -2 and e.y == 5 and e.mx != null and e.my != null and e.ctrl == 1 and e.alt == 1, \"wheel fields\"]\n"
      "e is host_push_event of null\nassert of [e.type == \"resize\" and e.w == 640 and e.h == 480, \"window fields\"]\n"
      "gfx_close of null\n";
    int ok = eval_ok(src); eigs_close(st);
    if (ok) puts("ui SDL input OK: key, motion/drag, button, wheel, and resize fields decoded from SDL_PushEvent");
    return ok ? 0 : 1;
}
