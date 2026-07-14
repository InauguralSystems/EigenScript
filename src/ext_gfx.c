/*
 * EigenScript Graphics Extension — SDL2 builtins.
 * Dynamically loads libSDL2 at runtime (no dev headers needed).
 *
 * Builtins: gfx_open, gfx_close, gfx_clear, gfx_rect, gfx_line,
 *           gfx_point, gfx_circle, gfx_present, gfx_poll, gfx_ticks, gfx_delay,
 *           gfx_text, gfx_text_width, gfx_text_height (proportional
 *           antialiased text via SDL2_ttf when available, #593)
 */

#include "eigenscript.h"
#include "ext_names.h"
#include "trace.h"   /* audio capture is a nondet input source (#579) */

#if EIGENSCRIPT_EXT_GFX

#include <dlfcn.h>

/* ---- SDL2 types (minimal, no headers needed) ---- */

typedef uint8_t  Uint8;
typedef uint32_t Uint32;
typedef int32_t  Sint32;

typedef struct { int x, y, w, h; } SDL_Rect;
typedef struct { Sint32 scancode; Sint32 sym; uint16_t mod; Uint32 unused; } SDL_Keysym;
typedef struct { Uint32 type; Uint32 ts; Uint32 wid; Uint8 state; Uint8 rep; Uint8 p2; Uint8 p3; SDL_Keysym keysym; } SDL_KeyboardEvent;
typedef struct { Uint32 type; Uint32 ts; Uint32 wid; Uint32 which; Sint32 x; Sint32 y; Sint32 xrel; Sint32 yrel; } SDL_MouseMotionEvent;
typedef struct { Uint32 type; Uint32 ts; Uint32 wid; Uint32 which; Uint8 button; Uint8 state; Uint8 clicks; Uint8 p1; Sint32 x; Sint32 y; } SDL_MouseButtonEvent;
typedef struct { Uint32 type; Uint32 ts; Uint32 wid; Uint32 which; Sint32 x; Sint32 y; Uint32 direction; } SDL_MouseWheelEvent;
typedef struct { Uint32 type; Uint32 ts; Uint32 wid; Uint8 event; Uint8 p1; Uint8 p2; Uint8 p3; Sint32 data1; Sint32 data2; } SDL_WindowEvent;

typedef union {
    Uint32 type;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    SDL_MouseWheelEvent wheel;
    SDL_WindowEvent window;
    Uint8 padding[64];
} SDL_Event;

typedef void SDL_Window;
typedef void SDL_Renderer;

typedef struct {
    int freq;
    uint16_t format;
    uint8_t channels;
    uint8_t silence;
    uint16_t samples;
    uint16_t padding;
    uint32_t size;
    void (*callback)(void*, uint8_t*, int);
    void *userdata;
} SDL_AudioSpec;

/* SDL2 constants */
#define MY_SDL_INIT_VIDEO       0x00000020u
#define MY_SDL_INIT_AUDIO       0x00000010u
#define MY_SDL_AUDIO_S16LSB     0x8010
#define MY_SDL_QUIT_EVENT       0x100u
#define MY_SDL_KEYDOWN          0x300u
#define MY_SDL_KEYUP            0x301u
#define MY_SDL_MOUSEMOTION      0x400u
#define MY_SDL_MOUSEBUTTONDOWN  0x401u
#define MY_SDL_MOUSEBUTTONUP    0x402u
#define MY_SDL_MOUSEWHEEL       0x403u
#define MY_SDL_WINDOWEVENT      0x200u
#define MY_SDL_WINDOWPOS_CENTERED 0x2FFF0000
#define MY_SDL_WINDOW_RESIZABLE 0x00000020u
#define MY_SDL_RENDERER_ACCELERATED 0x02u
#define MY_SDL_RENDERER_PRESENTVSYNC 0x04u
#define MY_SDL_BLENDMODE_BLEND  0x01u

/* ---- Function pointers ---- */

static void *g_sdl_lib = NULL;
static SDL_Window *g_window = NULL;
static SDL_Renderer *g_renderer = NULL;

static int (*p_SDL_Init)(Uint32);
static void (*p_SDL_Quit)(void);
static const char* (*p_SDL_GetError)(void);
static SDL_Window* (*p_SDL_CreateWindow)(const char*, int, int, int, int, Uint32);
static void (*p_SDL_DestroyWindow)(SDL_Window*);
static void (*p_SDL_SetWindowTitle)(SDL_Window*, const char*);
static SDL_Renderer* (*p_SDL_CreateRenderer)(SDL_Window*, int, Uint32);
static void (*p_SDL_DestroyRenderer)(SDL_Renderer*);
static int (*p_SDL_SetRenderDrawColor)(SDL_Renderer*, Uint8, Uint8, Uint8, Uint8);
static int (*p_SDL_SetRenderDrawBlendMode)(SDL_Renderer*, int);
static int (*p_SDL_RenderClear)(SDL_Renderer*);
static int (*p_SDL_RenderFillRect)(SDL_Renderer*, const SDL_Rect*);
static int (*p_SDL_RenderDrawLine)(SDL_Renderer*, int, int, int, int);
static int (*p_SDL_RenderDrawPoint)(SDL_Renderer*, int, int);
static void (*p_SDL_RenderPresent)(SDL_Renderer*);
static int (*p_SDL_PollEvent)(SDL_Event*);
static int (*p_SDL_GetModState)(void);
static Uint32 (*p_SDL_GetTicks)(void);
static void (*p_SDL_Delay)(Uint32);
static int (*p_SDL_RenderSetClipRect)(SDL_Renderer*, const SDL_Rect*);

/* Texture function pointers (for framebuffer blit) */
typedef void SDL_Texture;
#define MY_SDL_PIXELFORMAT_ARGB8888 0x16362004u
#define MY_SDL_TEXTUREACCESS_STREAMING 1
static SDL_Texture* (*p_SDL_CreateTexture)(SDL_Renderer*, Uint32, int, int, int);
static void (*p_SDL_DestroyTexture)(SDL_Texture*);
static int (*p_SDL_UpdateTexture)(SDL_Texture*, const SDL_Rect*, const void*, int);
static int (*p_SDL_RenderCopy)(SDL_Renderer*, SDL_Texture*, const SDL_Rect*, const SDL_Rect*);
static SDL_Texture* (*p_SDL_CreateTextureFromSurface)(SDL_Renderer*, void*);
static void (*p_SDL_FreeSurface)(void*);
static int (*p_SDL_QueryTexture)(SDL_Texture*, Uint32*, int*, int*, int*);

/* Framebuffer texture cache */
static SDL_Texture *g_fb_texture = NULL;
static int g_fb_w = 0, g_fb_h = 0;

/* Audio function pointers */
static int (*p_SDL_OpenAudioDevice)(const char*, int, const SDL_AudioSpec*, SDL_AudioSpec*, int);
static void (*p_SDL_CloseAudioDevice)(int);
static int (*p_SDL_QueueAudio)(int, const void*, Uint32);
static void (*p_SDL_LockAudioDevice)(int);
static void (*p_SDL_UnlockAudioDevice)(int);
static void (*p_SDL_PauseAudioDevice)(int, int);
static Uint32 (*p_SDL_GetQueuedAudioSize)(int);
static void (*p_SDL_ClearQueuedAudio)(int);
static Uint32 (*p_SDL_DequeueAudio)(int, void*, Uint32);

/* Audio state */
static int g_audio_device = 0;
static int g_audio_freq = 44100;
static int g_audio_channels = 1;
static int g_capture_device = 0;   /* #579: microphone/input device */

static int load_sdl2(void) {
    if (g_sdl_lib) return 1;
    g_sdl_lib = dlopen("libSDL2-2.0.so.0", RTLD_LAZY);
    if (!g_sdl_lib) g_sdl_lib = dlopen("libSDL2.so", RTLD_LAZY);
    if (!g_sdl_lib) return 0;

    int ok = 1;
    #define LOAD(name) do { \
        p_##name = dlsym(g_sdl_lib, #name); \
        if (!p_##name) { fprintf(stderr, "gfx: missing symbol %s\n", #name); ok = 0; } \
    } while(0)
    LOAD(SDL_Init); LOAD(SDL_Quit); LOAD(SDL_GetError);
    LOAD(SDL_CreateWindow); LOAD(SDL_DestroyWindow); LOAD(SDL_SetWindowTitle);
    LOAD(SDL_CreateRenderer); LOAD(SDL_DestroyRenderer);
    LOAD(SDL_SetRenderDrawColor); LOAD(SDL_SetRenderDrawBlendMode);
    LOAD(SDL_RenderClear); LOAD(SDL_RenderFillRect);
    LOAD(SDL_RenderDrawLine); LOAD(SDL_RenderDrawPoint);
    LOAD(SDL_RenderPresent); LOAD(SDL_PollEvent);
    LOAD(SDL_GetTicks); LOAD(SDL_Delay);
    #undef LOAD
    /* Optional symbols — NULL is fine */
    p_SDL_GetModState = dlsym(g_sdl_lib, "SDL_GetModState");
    p_SDL_RenderSetClipRect = dlsym(g_sdl_lib, "SDL_RenderSetClipRect");
    p_SDL_CreateTexture = dlsym(g_sdl_lib, "SDL_CreateTexture");
    p_SDL_DestroyTexture = dlsym(g_sdl_lib, "SDL_DestroyTexture");
    p_SDL_UpdateTexture = dlsym(g_sdl_lib, "SDL_UpdateTexture");
    p_SDL_RenderCopy = dlsym(g_sdl_lib, "SDL_RenderCopy");
    p_SDL_CreateTextureFromSurface = dlsym(g_sdl_lib, "SDL_CreateTextureFromSurface");
    p_SDL_FreeSurface = dlsym(g_sdl_lib, "SDL_FreeSurface");
    p_SDL_QueryTexture = dlsym(g_sdl_lib, "SDL_QueryTexture");
    p_SDL_OpenAudioDevice = dlsym(g_sdl_lib, "SDL_OpenAudioDevice");
    p_SDL_CloseAudioDevice = dlsym(g_sdl_lib, "SDL_CloseAudioDevice");
    p_SDL_QueueAudio = dlsym(g_sdl_lib, "SDL_QueueAudio");
    p_SDL_LockAudioDevice = dlsym(g_sdl_lib, "SDL_LockAudioDevice");
    p_SDL_UnlockAudioDevice = dlsym(g_sdl_lib, "SDL_UnlockAudioDevice");
    p_SDL_PauseAudioDevice = dlsym(g_sdl_lib, "SDL_PauseAudioDevice");
    p_SDL_GetQueuedAudioSize = dlsym(g_sdl_lib, "SDL_GetQueuedAudioSize");
    p_SDL_ClearQueuedAudio = dlsym(g_sdl_lib, "SDL_ClearQueuedAudio");
    p_SDL_DequeueAudio = dlsym(g_sdl_lib, "SDL_DequeueAudio");
    if (!ok) {
        dlclose(g_sdl_lib);
        g_sdl_lib = NULL;
        return 0;
    }
    return 1;
}

/* ---- SDL_mixer (streaming background music) ----
 * Loaded separately and lazily (only when audio_music_* is first used) so the
 * core graphics binary keeps no hard dependency on libSDL2_mixer. Music plays
 * on the mixer's own audio device, alongside the existing SFX sample queue
 * (two SDL audio devices coexist; the OS mixes them). MP3 decode is provided
 * by SDL_mixer via libmpg123. */
#define MY_MIX_INIT_MP3    0x00000008
#define MY_AUDIO_S16SYS    0x8010
#define MY_MIX_MAX_VOLUME  128
static void *g_mixer_lib  = NULL;
static int   g_mixer_open = 0;
static void *g_music      = NULL;        /* current Mix_Music* */
static int   (*p_Mix_Init)(int);
static void  (*p_Mix_Quit)(void);
static int   (*p_Mix_OpenAudioDevice)(int, uint16_t, int, int, const char*, int);
static void  (*p_Mix_CloseAudio)(void);
static void *(*p_Mix_LoadMUS)(const char*);
static void  (*p_Mix_FreeMusic)(void*);
static int   (*p_Mix_PlayMusic)(void*, int);
static int   (*p_Mix_VolumeMusic)(int);
static int   (*p_Mix_HaltMusic)(void);

static int load_sdl_mixer(void) {
    if (g_mixer_lib) return 1;
    g_mixer_lib = dlopen("libSDL2_mixer-2.0.so.0", RTLD_LAZY);
    if (!g_mixer_lib) g_mixer_lib = dlopen("libSDL2_mixer.so", RTLD_LAZY);
    if (!g_mixer_lib) {
        fprintf(stderr, "audio_music: cannot load libSDL2_mixer "
                "(install libsdl2-mixer-2.0-0)\n");
        return 0;
    }
    int ok = 1;
    #define MLOAD(name) do { p_##name = dlsym(g_mixer_lib, #name); \
        if (!p_##name) { fprintf(stderr, "audio_music: missing %s\n", #name); ok = 0; } } while(0)
    MLOAD(Mix_Init); MLOAD(Mix_Quit);
    MLOAD(Mix_OpenAudioDevice); MLOAD(Mix_CloseAudio);
    MLOAD(Mix_LoadMUS); MLOAD(Mix_FreeMusic);
    MLOAD(Mix_PlayMusic); MLOAD(Mix_VolumeMusic); MLOAD(Mix_HaltMusic);
    #undef MLOAD
    if (!ok) { dlclose(g_mixer_lib); g_mixer_lib = NULL; return 0; }
    return 1;
}

/* ---- SDL2_ttf (proportional antialiased text, #593) ----
 * Loaded separately and lazily (first gfx_text / gfx_text_width /
 * gfx_text_height call) so the core graphics binary keeps no hard
 * dependency on libSDL2_ttf. THE FALLBACK IS LOAD-BEARING: when the lib
 * or a usable font file is missing (CI containers may have neither),
 * gfx_text renders through the 5x7 bitmap path exactly as before, and
 * the metrics builtins return the bitmap math (len*6*scale / 7*scale).
 *
 * Font discovery: EIGS_GFX_FONT (absolute path to a .ttf) wins; when it
 * is set but unreadable we warn once and stay on the bitmap font — a
 * nonexistent path is the deterministic off-switch the tests pin.
 * Otherwise a short list of common system fonts is probed. No
 * fontconfig dependency.
 *
 * Text rendering is output-only — no trace-tape records (same class as
 * gfx_rect); the metrics builtins are environment-dependent (which font
 * is installed) but untraced, same class as gfx_ticks. */
typedef struct { Uint8 r, g, b, a; } SDL_Color;

static void *g_ttf_lib = NULL;
static int g_ttf_state = 0;            /* 0 unprobed, 1 active, -1 unavailable */
static char g_ttf_font_path[512];

static int  (*p_TTF_Init)(void);
static void (*p_TTF_Quit)(void);
static void *(*p_TTF_OpenFont)(const char*, int);
static void (*p_TTF_CloseFont)(void*);
static int  (*p_TTF_SizeUTF8)(void*, const char*, int*, int*);
static int  (*p_TTF_FontHeight)(void*);
static void *(*p_TTF_RenderUTF8_Blended)(void*, const char*, SDL_Color);

/* TTF_Font* cache, one entry per pixel size actually used. */
#define TTF_FONT_CACHE_MAX 16
static struct { int px; void *font; } g_ttf_fonts[TTF_FONT_CACHE_MAX];
static int g_ttf_font_count = 0;

/* Map the gfx_text bitmap `scale` to a TTF pixel size. 6*scale + 2
 * keeps the rendered line height close to the bitmap cell (7*scale)
 * and the average advance narrower than the bitmap's 6*scale, so
 * existing fixed-width layouts don't overflow (scale 2 → 14 px). */
static int ttf_scale_to_px(int scale) {
    if (scale < 1) scale = 1;
    return 6 * scale + 2;
}

static int ttf_available(void) {
    if (g_ttf_state) return g_ttf_state > 0;
    g_ttf_state = -1;

    const char *env = getenv("EIGS_GFX_FONT");
    if (env && *env) {
        if (access(env, R_OK) != 0) {
            fprintf(stderr, "gfx_text: EIGS_GFX_FONT '%s' is not readable; "
                    "using the bitmap font\n", env);
            return 0;
        }
        snprintf(g_ttf_font_path, sizeof g_ttf_font_path, "%s", env);
    } else {
        static const char *candidates[] = {
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
            "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
            NULL
        };
        const char *found = NULL;
        for (int i = 0; candidates[i]; i++)
            if (access(candidates[i], R_OK) == 0) { found = candidates[i]; break; }
        if (!found) return 0;   /* silent: bitmap is the normal fallback */
        snprintf(g_ttf_font_path, sizeof g_ttf_font_path, "%s", found);
    }

    g_ttf_lib = dlopen("libSDL2_ttf-2.0.so.0", RTLD_LAZY);
    if (!g_ttf_lib) g_ttf_lib = dlopen("libSDL2_ttf.so", RTLD_LAZY);
    if (!g_ttf_lib) return 0;   /* silent: bitmap is the normal fallback */

    int ok = 1;
    #define TLOAD(name) do { p_##name = dlsym(g_ttf_lib, #name); \
        if (!p_##name) { fprintf(stderr, "gfx_text: missing %s\n", #name); ok = 0; } } while(0)
    TLOAD(TTF_Init); TLOAD(TTF_Quit);
    TLOAD(TTF_OpenFont); TLOAD(TTF_CloseFont);
    TLOAD(TTF_SizeUTF8); TLOAD(TTF_FontHeight);
    TLOAD(TTF_RenderUTF8_Blended);
    #undef TLOAD
    if (!ok || p_TTF_Init() != 0) {
        dlclose(g_ttf_lib);
        g_ttf_lib = NULL;
        return 0;
    }
    g_ttf_state = 1;
    return 1;
}

/* Cached TTF_Font* for a bitmap scale; NULL when the font can't open
 * (callers fall back to the bitmap path). */
static void* ttf_font_for_scale(int scale) {
    int px = ttf_scale_to_px(scale);
    for (int i = 0; i < g_ttf_font_count; i++)
        if (g_ttf_fonts[i].px == px) return g_ttf_fonts[i].font;
    if (g_ttf_font_count >= TTF_FONT_CACHE_MAX)
        return g_ttf_fonts[0].font;   /* pathological size churn: reuse */
    void *font = p_TTF_OpenFont(g_ttf_font_path, px);
    g_ttf_fonts[g_ttf_font_count].px = px;
    g_ttf_fonts[g_ttf_font_count].font = font;   /* cache NULL too */
    g_ttf_font_count++;
    return font;
}

static void ttf_teardown(void) {
    if (!g_ttf_lib) { g_ttf_state = 0; g_ttf_font_count = 0; return; }
    for (int i = 0; i < g_ttf_font_count; i++)
        if (g_ttf_fonts[i].font) p_TTF_CloseFont(g_ttf_fonts[i].font);
    g_ttf_font_count = 0;
    p_TTF_Quit();
    dlclose(g_ttf_lib);
    g_ttf_lib = NULL;
    g_ttf_state = 0;
}

/* Scancode to key name — SDL2 scancodes */
static const char* scancode_name(int sc) {
    switch (sc) {
        case 4: return "a"; case 5: return "b"; case 6: return "c";
        case 7: return "d"; case 8: return "e"; case 9: return "f";
        case 10: return "g"; case 11: return "h"; case 12: return "i";
        case 13: return "j"; case 14: return "k"; case 15: return "l";
        case 16: return "m"; case 17: return "n"; case 18: return "o";
        case 19: return "p"; case 20: return "q"; case 21: return "r";
        case 22: return "s"; case 23: return "t"; case 24: return "u";
        case 25: return "v"; case 26: return "w"; case 27: return "x";
        case 28: return "y"; case 29: return "z";
        case 30: return "1"; case 31: return "2"; case 32: return "3";
        case 33: return "4"; case 34: return "5"; case 35: return "6";
        case 36: return "7"; case 37: return "8"; case 38: return "9";
        case 39: return "0";
        case 40: return "return"; case 41: return "escape";
        case 42: return "backspace"; case 43: return "tab";
        case 44: return "space";
        case 45: return "-"; case 46: return "=";
        case 47: return "["; case 48: return "]"; case 49: return "\\";
        case 51: return ";"; case 52: return "'";
        case 54: return ","; case 55: return "."; case 56: return "/";
        case 57: return "capslock";
        case 58: return "f1"; case 59: return "f2"; case 60: return "f3";
        case 61: return "f4"; case 62: return "f5"; case 63: return "f6";
        case 64: return "f7"; case 65: return "f8"; case 66: return "f9";
        case 67: return "f10"; case 68: return "f11"; case 69: return "f12";
        case 73: return "insert"; case 74: return "home";
        case 75: return "pageup"; case 76: return "delete";
        case 77: return "end"; case 78: return "pagedown";
        case 79: return "right"; case 80: return "left";
        case 81: return "down"; case 82: return "up";
        default: return "";
    }
}

/* ---- Builtins ---- */

/* gfx_open of [width, height, title] */
Value* builtin_gfx_open(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_num(0);
    int w = (int)arg->data.list.items[0]->data.num;
    int h = (int)arg->data.list.items[1]->data.num;
    const char *title = arg->data.list.items[2]->type == VAL_STR ? arg->data.list.items[2]->data.str : "EigenScript";

    if (!load_sdl2()) {
        fprintf(stderr, "gfx_open: cannot load libSDL2\n");
        return make_num(0);
    }
    if (p_SDL_Init(MY_SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "gfx_open: SDL_Init failed: %s\n", p_SDL_GetError());
        return make_num(0);
    }
    g_window = p_SDL_CreateWindow(title, MY_SDL_WINDOWPOS_CENTERED, MY_SDL_WINDOWPOS_CENTERED, w, h, MY_SDL_WINDOW_RESIZABLE);
    if (!g_window) {
        fprintf(stderr, "gfx_open: SDL_CreateWindow failed: %s\n", p_SDL_GetError());
        return make_num(0);
    }
    g_renderer = p_SDL_CreateRenderer(g_window, -1, MY_SDL_RENDERER_ACCELERATED | MY_SDL_RENDERER_PRESENTVSYNC);
    if (!g_renderer) {
        g_renderer = p_SDL_CreateRenderer(g_window, -1, 0);
    }
    if (!g_renderer) {
        fprintf(stderr, "gfx_open: SDL_CreateRenderer failed\n");
        p_SDL_DestroyWindow(g_window);
        g_window = NULL;
        return make_num(0);
    }
    p_SDL_SetRenderDrawBlendMode(g_renderer, MY_SDL_BLENDMODE_BLEND);
    return make_num(1);
}

/* gfx_close of null */
Value* builtin_gfx_close(Value *arg) {
    (void)arg;
    ttf_teardown();
    if (g_fb_texture && p_SDL_DestroyTexture) { p_SDL_DestroyTexture(g_fb_texture); g_fb_texture = NULL; g_fb_w = 0; g_fb_h = 0; }
    if (g_audio_device) { p_SDL_CloseAudioDevice(g_audio_device); g_audio_device = 0; }
    if (g_capture_device) { p_SDL_CloseAudioDevice(g_capture_device); g_capture_device = 0; }
    if (g_renderer) { p_SDL_DestroyRenderer(g_renderer); g_renderer = NULL; }
    if (g_window) { p_SDL_DestroyWindow(g_window); g_window = NULL; }
    if (g_sdl_lib) {
        p_SDL_Quit();
        dlclose(g_sdl_lib);
        g_sdl_lib = NULL;
    }
    return make_null();
}

/* gfx_clear of [r, g, b] */
Value* builtin_gfx_clear(Value *arg) {
    if (!g_renderer) return make_null();
    int r = 0, g = 0, b = 0;
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 3) {
        r = (int)arg->data.list.items[0]->data.num;
        g = (int)arg->data.list.items[1]->data.num;
        b = (int)arg->data.list.items[2]->data.num;
    }
    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, 255);
    p_SDL_RenderClear(g_renderer);
    return make_null();
}

/* gfx_rect of [x, y, w, h, r, g, b] or [x, y, w, h, r, g, b, a] */
Value* builtin_gfx_rect(Value *arg) {
    if (!g_renderer || !arg || arg->type != VAL_LIST || arg->data.list.count < 7) return make_null();
    SDL_Rect rect;
    rect.x = (int)arg->data.list.items[0]->data.num;
    rect.y = (int)arg->data.list.items[1]->data.num;
    rect.w = (int)arg->data.list.items[2]->data.num;
    rect.h = (int)arg->data.list.items[3]->data.num;
    int r = (int)arg->data.list.items[4]->data.num;
    int g = (int)arg->data.list.items[5]->data.num;
    int b = (int)arg->data.list.items[6]->data.num;
    int a = (arg->data.list.count >= 8) ? (int)arg->data.list.items[7]->data.num : 255;
    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, a);
    p_SDL_RenderFillRect(g_renderer, &rect);
    return make_null();
}

/* gfx_line of [x1, y1, x2, y2, r, g, b] */
Value* builtin_gfx_line(Value *arg) {
    if (!g_renderer || !arg || arg->type != VAL_LIST || arg->data.list.count < 7) return make_null();
    int x1 = (int)arg->data.list.items[0]->data.num;
    int y1 = (int)arg->data.list.items[1]->data.num;
    int x2 = (int)arg->data.list.items[2]->data.num;
    int y2 = (int)arg->data.list.items[3]->data.num;
    int r = (int)arg->data.list.items[4]->data.num;
    int g = (int)arg->data.list.items[5]->data.num;
    int b = (int)arg->data.list.items[6]->data.num;
    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, 255);
    p_SDL_RenderDrawLine(g_renderer, x1, y1, x2, y2);
    return make_null();
}

/* gfx_point of [x, y, r, g, b] */
Value* builtin_gfx_point(Value *arg) {
    if (!g_renderer || !arg || arg->type != VAL_LIST || arg->data.list.count < 5) return make_null();
    int x = (int)arg->data.list.items[0]->data.num;
    int y = (int)arg->data.list.items[1]->data.num;
    int r = (int)arg->data.list.items[2]->data.num;
    int g = (int)arg->data.list.items[3]->data.num;
    int b = (int)arg->data.list.items[4]->data.num;
    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, 255);
    p_SDL_RenderDrawPoint(g_renderer, x, y);
    return make_null();
}

/* gfx_circle of [cx, cy, radius, r, g, b] — filled circle via midpoint */
Value* builtin_gfx_circle(Value *arg) {
    if (!g_renderer || !arg || arg->type != VAL_LIST || arg->data.list.count < 6) return make_null();
    int cx = (int)arg->data.list.items[0]->data.num;
    int cy = (int)arg->data.list.items[1]->data.num;
    int radius = (int)arg->data.list.items[2]->data.num;
    int r = (int)arg->data.list.items[3]->data.num;
    int g = (int)arg->data.list.items[4]->data.num;
    int b = (int)arg->data.list.items[5]->data.num;
    int a = (arg->data.list.count >= 7) ? (int)arg->data.list.items[6]->data.num : 255;
    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, a);
    /* Filled circle via horizontal lines */
    for (int dy = -radius; dy <= radius; dy++) {
        int dx = (int)sqrt((double)(radius * radius - dy * dy));
        SDL_Rect row = { cx - dx, cy + dy, dx * 2 + 1, 1 };
        p_SDL_RenderFillRect(g_renderer, &row);
    }
    return make_null();
}

/* gfx_rrect of [x, y, w, h, radius, r, g, b] or [..., a]
 * Filled rounded rectangle. Draws corner arcs via scanlines + rects for body. */
Value* builtin_gfx_rrect(Value *arg) {
    if (!g_renderer || !arg || arg->type != VAL_LIST || arg->data.list.count < 8) return make_null();
    int x = (int)arg->data.list.items[0]->data.num;
    int y = (int)arg->data.list.items[1]->data.num;
    int w = (int)arg->data.list.items[2]->data.num;
    int h = (int)arg->data.list.items[3]->data.num;
    int rad = (int)arg->data.list.items[4]->data.num;
    int r = (int)arg->data.list.items[5]->data.num;
    int g = (int)arg->data.list.items[6]->data.num;
    int b = (int)arg->data.list.items[7]->data.num;
    int a = (arg->data.list.count >= 9) ? (int)arg->data.list.items[8]->data.num : 255;
    if (w <= 0 || h <= 0) return make_null();
    /* Clamp radius to half the smaller dimension */
    if (rad > w / 2) rad = w / 2;
    if (rad > h / 2) rad = h / 2;
    if (rad < 0) rad = 0;
    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, a);
    if (rad == 0) {
        SDL_Rect rect = { x, y, w, h };
        p_SDL_RenderFillRect(g_renderer, &rect);
        return make_null();
    }
    /* Center body (between top and bottom rounded bands) */
    SDL_Rect center = { x, y + rad, w, h - 2 * rad };
    p_SDL_RenderFillRect(g_renderer, &center);
    /* Top and bottom bands with rounded corners via scanlines */
    for (int dy = 0; dy < rad; dy++) {
        int dx = (int)sqrt((double)(rad * rad - (rad - dy) * (rad - dy)));
        /* Top band */
        SDL_Rect top_row = { x + rad - dx, y + dy, w - 2 * (rad - dx), 1 };
        p_SDL_RenderFillRect(g_renderer, &top_row);
        /* Bottom band */
        SDL_Rect bot_row = { x + rad - dx, y + h - 1 - dy, w - 2 * (rad - dx), 1 };
        p_SDL_RenderFillRect(g_renderer, &bot_row);
    }
    return make_null();
}

/* gfx_clip of [x, y, w, h] — set render clip rectangle.
 * gfx_clip of null — clear clip rectangle. */
Value* builtin_gfx_clip(Value *arg) {
    if (!g_renderer || !p_SDL_RenderSetClipRect) return make_null();
    if (!arg || arg->type == VAL_NULL) {
        p_SDL_RenderSetClipRect(g_renderer, NULL);
        return make_null();
    }
    if (arg->type != VAL_LIST || arg->data.list.count < 4) return make_null();
    SDL_Rect clip;
    clip.x = (int)arg->data.list.items[0]->data.num;
    clip.y = (int)arg->data.list.items[1]->data.num;
    clip.w = (int)arg->data.list.items[2]->data.num;
    clip.h = (int)arg->data.list.items[3]->data.num;
    p_SDL_RenderSetClipRect(g_renderer, &clip);
    return make_null();
}

/* gfx_present of null — flip buffer to screen */
Value* builtin_gfx_present(Value *arg) {
    (void)arg;
    if (g_renderer) p_SDL_RenderPresent(g_renderer);
    return make_null();
}

/* Attach keyboard modifier state as shift/ctrl/alt (0/1) dict fields.
 * KMOD_SHIFT = 0x0003, KMOD_CTRL = 0x00C0, KMOD_ALT = 0x0300.
 * Key events read the mask from keysym.mod; mouse/wheel events (#568)
 * pass SDL_GetModState() — SDL keeps it current at mouse-event time. */
static void poll_set_mods(Value *d, int mod) {
    dict_set_owned(d, "shift", make_num((mod & 0x03) ? 1 : 0));
    dict_set_owned(d, "ctrl", make_num((mod & 0xC0) ? 1 : 0));
    dict_set_owned(d, "alt", make_num((mod & 0x300) ? 1 : 0));
}

static int poll_mod_state(void) {
    return p_SDL_GetModState ? p_SDL_GetModState() : 0;
}

/* gfx_poll of null — return next event as dict, or null if none.
 * {"type": "keydown", "key": "up"} / {"type": "quit"} /
 * {"type": "mousemove", "x": 100, "y": 200} / etc.
 * Key, mouse, and wheel events all carry shift/ctrl/alt (0/1). */
Value* builtin_gfx_poll(Value *arg) {
    (void)arg;
    if (!g_window) return make_null();
    SDL_Event ev;
    if (!p_SDL_PollEvent(&ev)) return make_null();

    Value *d = make_dict(4);
    switch (ev.type) {
        case MY_SDL_QUIT_EVENT:
            dict_set_owned(d, "type", make_str("quit"));
            break;
        case MY_SDL_KEYDOWN:
            dict_set_owned(d, "type", make_str("keydown"));
            dict_set_owned(d, "key", make_str(scancode_name(ev.key.keysym.scancode)));
            dict_set_owned(d, "scancode", make_num(ev.key.keysym.scancode));
            poll_set_mods(d, ev.key.keysym.mod);
            break;
        case MY_SDL_KEYUP:
            dict_set_owned(d, "type", make_str("keyup"));
            dict_set_owned(d, "key", make_str(scancode_name(ev.key.keysym.scancode)));
            dict_set_owned(d, "scancode", make_num(ev.key.keysym.scancode));
            poll_set_mods(d, ev.key.keysym.mod);
            break;
        case MY_SDL_MOUSEMOTION:
            dict_set_owned(d, "type", make_str("mousemove"));
            dict_set_owned(d, "x", make_num(ev.motion.x));
            dict_set_owned(d, "y", make_num(ev.motion.y));
            poll_set_mods(d, poll_mod_state());
            break;
        case MY_SDL_MOUSEBUTTONDOWN:
            dict_set_owned(d, "type", make_str("mousedown"));
            dict_set_owned(d, "button", make_num(ev.button.button));
            dict_set_owned(d, "x", make_num(ev.button.x));
            dict_set_owned(d, "y", make_num(ev.button.y));
            poll_set_mods(d, poll_mod_state());
            break;
        case MY_SDL_MOUSEBUTTONUP:
            dict_set_owned(d, "type", make_str("mouseup"));
            dict_set_owned(d, "button", make_num(ev.button.button));
            dict_set_owned(d, "x", make_num(ev.button.x));
            dict_set_owned(d, "y", make_num(ev.button.y));
            poll_set_mods(d, poll_mod_state());
            break;
        case MY_SDL_MOUSEWHEEL:
            dict_set_owned(d, "type", make_str("wheel"));
            dict_set_owned(d, "x", make_num(ev.wheel.x));
            dict_set_owned(d, "y", make_num(ev.wheel.y));
            poll_set_mods(d, poll_mod_state());
            break;
        case MY_SDL_WINDOWEVENT:
            /* SDL_WINDOWEVENT_RESIZED = 6 */
            if (ev.window.event == 6) {
                dict_set_owned(d, "type", make_str("resize"));
                dict_set_owned(d, "w", make_num(ev.window.data1));
                dict_set_owned(d, "h", make_num(ev.window.data2));
            } else {
                return make_null();
            }
            break;
        default:
            return make_null();
    }
    return d;
}

/* gfx_ticks of null — milliseconds since SDL_Init */
Value* builtin_gfx_ticks(Value *arg) {
    (void)arg;
    return make_num(g_sdl_lib ? (double)p_SDL_GetTicks() : 0.0);
}

/* gfx_delay of ms */
Value* builtin_gfx_delay(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    if (g_sdl_lib) p_SDL_Delay((Uint32)arg->data.num);
    return make_null();
}

/* gfx_title of "new title" */
Value* builtin_gfx_title(Value *arg) {
    if (!g_window || !arg || arg->type != VAL_STR) return make_null();
    p_SDL_SetWindowTitle(g_window, arg->data.str);
    return make_null();
}

/* 5x7 bitmap font — printable ASCII 32..126 */
static const unsigned char font5x7[95][7] = {
    {0x00,0x00,0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x04,0x04,0x04,0x04,0x04,0x00,0x04}, /* '!' */
    {0x0A,0x0A,0x0A,0x00,0x00,0x00,0x00}, /* '"' */
    {0x0A,0x0A,0x1F,0x0A,0x1F,0x0A,0x0A}, /* '#' */
    {0x04,0x0F,0x14,0x0E,0x05,0x1E,0x04}, /* '$' */
    {0x18,0x19,0x02,0x04,0x08,0x13,0x03}, /* '%' */
    {0x0C,0x12,0x14,0x08,0x15,0x12,0x0D}, /* '&' */
    {0x04,0x04,0x08,0x00,0x00,0x00,0x00}, /* ''' */
    {0x02,0x04,0x08,0x08,0x08,0x04,0x02}, /* '(' */
    {0x08,0x04,0x02,0x02,0x02,0x04,0x08}, /* ')' */
    {0x00,0x04,0x15,0x0E,0x15,0x04,0x00}, /* '*' */
    {0x00,0x04,0x04,0x1F,0x04,0x04,0x00}, /* '+' */
    {0x00,0x00,0x00,0x00,0x04,0x04,0x08}, /* ',' */
    {0x00,0x00,0x00,0x1F,0x00,0x00,0x00}, /* '-' */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x04}, /* '.' */
    {0x00,0x01,0x02,0x04,0x08,0x10,0x00}, /* '/' */
    {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E}, /* '0' */
    {0x04,0x0C,0x04,0x04,0x04,0x04,0x0E}, /* '1' */
    {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F}, /* '2' */
    {0x1F,0x02,0x04,0x02,0x01,0x11,0x0E}, /* '3' */
    {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02}, /* '4' */
    {0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E}, /* '5' */
    {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E}, /* '6' */
    {0x1F,0x01,0x02,0x04,0x08,0x08,0x08}, /* '7' */
    {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E}, /* '8' */
    {0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C}, /* '9' */
    {0x00,0x00,0x04,0x00,0x04,0x00,0x00}, /* ':' */
    {0x00,0x00,0x04,0x00,0x04,0x04,0x08}, /* ';' */
    {0x02,0x04,0x08,0x10,0x08,0x04,0x02}, /* '<' */
    {0x00,0x00,0x1F,0x00,0x1F,0x00,0x00}, /* '=' */
    {0x08,0x04,0x02,0x01,0x02,0x04,0x08}, /* '>' */
    {0x0E,0x11,0x01,0x02,0x04,0x00,0x04}, /* '?' */
    {0x0E,0x11,0x17,0x15,0x17,0x10,0x0E}, /* '@' */
    {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11}, /* 'A' */
    {0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E}, /* 'B' */
    {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E}, /* 'C' */
    {0x1C,0x12,0x11,0x11,0x11,0x12,0x1C}, /* 'D' */
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F}, /* 'E' */
    {0x1F,0x10,0x10,0x1E,0x10,0x10,0x10}, /* 'F' */
    {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F}, /* 'G' */
    {0x11,0x11,0x11,0x1F,0x11,0x11,0x11}, /* 'H' */
    {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E}, /* 'I' */
    {0x07,0x02,0x02,0x02,0x02,0x12,0x0C}, /* 'J' */
    {0x11,0x12,0x14,0x18,0x14,0x12,0x11}, /* 'K' */
    {0x10,0x10,0x10,0x10,0x10,0x10,0x1F}, /* 'L' */
    {0x11,0x1B,0x15,0x15,0x11,0x11,0x11}, /* 'M' */
    {0x11,0x19,0x15,0x13,0x11,0x11,0x11}, /* 'N' */
    {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E}, /* 'O' */
    {0x1E,0x11,0x11,0x1E,0x10,0x10,0x10}, /* 'P' */
    {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D}, /* 'Q' */
    {0x1E,0x11,0x11,0x1E,0x14,0x12,0x11}, /* 'R' */
    {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E}, /* 'S' */
    {0x1F,0x04,0x04,0x04,0x04,0x04,0x04}, /* 'T' */
    {0x11,0x11,0x11,0x11,0x11,0x11,0x0E}, /* 'U' */
    {0x11,0x11,0x11,0x11,0x11,0x0A,0x04}, /* 'V' */
    {0x11,0x11,0x11,0x15,0x15,0x1B,0x11}, /* 'W' */
    {0x11,0x11,0x0A,0x04,0x0A,0x11,0x11}, /* 'X' */
    {0x11,0x11,0x0A,0x04,0x04,0x04,0x04}, /* 'Y' */
    {0x1F,0x01,0x02,0x04,0x08,0x10,0x1F}, /* 'Z' */
    {0x0E,0x08,0x08,0x08,0x08,0x08,0x0E}, /* '[' */
    {0x00,0x10,0x08,0x04,0x02,0x01,0x00}, /* '\' */
    {0x0E,0x02,0x02,0x02,0x02,0x02,0x0E}, /* ']' */
    {0x04,0x0A,0x11,0x00,0x00,0x00,0x00}, /* '^' */
    {0x00,0x00,0x00,0x00,0x00,0x00,0x1F}, /* '_' */
    {0x08,0x04,0x02,0x00,0x00,0x00,0x00}, /* '`' */
    {0x00,0x00,0x0E,0x01,0x0F,0x11,0x0F}, /* 'a' */
    {0x10,0x10,0x16,0x19,0x11,0x11,0x1E}, /* 'b' */
    {0x00,0x00,0x0E,0x10,0x10,0x11,0x0E}, /* 'c' */
    {0x01,0x01,0x0D,0x13,0x11,0x11,0x0F}, /* 'd' */
    {0x00,0x00,0x0E,0x11,0x1F,0x10,0x0E}, /* 'e' */
    {0x06,0x09,0x08,0x1C,0x08,0x08,0x08}, /* 'f' */
    {0x00,0x0F,0x11,0x11,0x0F,0x01,0x0E}, /* 'g' */
    {0x10,0x10,0x16,0x19,0x11,0x11,0x11}, /* 'h' */
    {0x04,0x00,0x0C,0x04,0x04,0x04,0x0E}, /* 'i' */
    {0x02,0x00,0x06,0x02,0x02,0x12,0x0C}, /* 'j' */
    {0x10,0x10,0x12,0x14,0x18,0x14,0x12}, /* 'k' */
    {0x0C,0x04,0x04,0x04,0x04,0x04,0x0E}, /* 'l' */
    {0x00,0x00,0x1A,0x15,0x15,0x11,0x11}, /* 'm' */
    {0x00,0x00,0x16,0x19,0x11,0x11,0x11}, /* 'n' */
    {0x00,0x00,0x0E,0x11,0x11,0x11,0x0E}, /* 'o' */
    {0x00,0x00,0x1E,0x11,0x1E,0x10,0x10}, /* 'p' */
    {0x00,0x00,0x0D,0x13,0x0F,0x01,0x01}, /* 'q' */
    {0x00,0x00,0x16,0x19,0x10,0x10,0x10}, /* 'r' */
    {0x00,0x00,0x0E,0x10,0x0E,0x01,0x1E}, /* 's' */
    {0x08,0x08,0x1C,0x08,0x08,0x09,0x06}, /* 't' */
    {0x00,0x00,0x11,0x11,0x11,0x13,0x0D}, /* 'u' */
    {0x00,0x00,0x11,0x11,0x11,0x0A,0x04}, /* 'v' */
    {0x00,0x00,0x11,0x11,0x15,0x15,0x0A}, /* 'w' */
    {0x00,0x00,0x11,0x0A,0x04,0x0A,0x11}, /* 'x' */
    {0x00,0x00,0x11,0x11,0x0F,0x01,0x0E}, /* 'y' */
    {0x00,0x00,0x1F,0x02,0x04,0x08,0x1F}, /* 'z' */
    {0x02,0x04,0x04,0x08,0x04,0x04,0x02}, /* '{' */
    {0x04,0x04,0x04,0x04,0x04,0x04,0x04}, /* '|' */
    {0x08,0x04,0x04,0x02,0x04,0x04,0x08}, /* '}' */
    {0x00,0x04,0x02,0x1F,0x02,0x04,0x00}, /* '~' */
};

/* gfx_text of [x, y, text, r, g, b] or [x, y, text, r, g, b, scale]
 * Proportional antialiased TTF text when SDL2_ttf + a font are available
 * (#593); the 5x7 bitmap path below is the exact pre-#593 behavior and
 * runs whenever any part of the TTF path is missing or fails. */
Value* builtin_gfx_text(Value *arg) {
    if (!g_renderer || !arg || arg->type != VAL_LIST || arg->data.list.count < 6) return make_null();
    int x = (int)arg->data.list.items[0]->data.num;
    int y = (int)arg->data.list.items[1]->data.num;
    const char *text = arg->data.list.items[2]->type == VAL_STR ? arg->data.list.items[2]->data.str : "";
    int r = (int)arg->data.list.items[3]->data.num;
    int g = (int)arg->data.list.items[4]->data.num;
    int b = (int)arg->data.list.items[5]->data.num;
    int scale = (arg->data.list.count >= 7) ? (int)arg->data.list.items[6]->data.num : 1;
    if (scale < 1) scale = 1;

    if (*text && ttf_available() && p_SDL_CreateTextureFromSurface
        && p_SDL_FreeSurface && p_SDL_QueryTexture && p_SDL_DestroyTexture
        && p_SDL_RenderCopy) {
        void *font = ttf_font_for_scale(scale);
        if (font) {
            SDL_Color col = { (Uint8)r, (Uint8)g, (Uint8)b, 255 };
            void *surf = p_TTF_RenderUTF8_Blended(font, text, col);
            if (surf) {
                SDL_Texture *tex = p_SDL_CreateTextureFromSurface(g_renderer, surf);
                p_SDL_FreeSurface(surf);
                if (tex) {
                    int tw = 0, th = 0;
                    p_SDL_QueryTexture(tex, NULL, NULL, &tw, &th);
                    SDL_Rect dst = { x, y, tw, th };
                    p_SDL_RenderCopy(g_renderer, tex, NULL, &dst);
                    p_SDL_DestroyTexture(tex);
                    return make_null();
                }
            }
        }
        /* fall through to the bitmap path on any failure */
    }

    p_SDL_SetRenderDrawColor(g_renderer, r, g, b, 255);
    int cx = x;
    for (const char *p = text; *p; p++) {
        int ch = (unsigned char)*p;
        if (ch < 32 || ch > 126) ch = '?';
        const unsigned char *glyph = font5x7[ch - 32];
        for (int row = 0; row < 7; row++) {
            unsigned char bits = glyph[row];
            for (int col = 0; col < 5; col++) {
                if (bits & (0x10 >> col)) {
                    if (scale == 1) {
                        p_SDL_RenderDrawPoint(g_renderer, cx + col, y + row);
                    } else {
                        SDL_Rect pr = { cx + col * scale, y + row * scale, scale, scale };
                        p_SDL_RenderFillRect(g_renderer, &pr);
                    }
                }
            }
        }
        cx += (5 + 1) * scale; /* 5 pixel width + 1 pixel gap */
    }
    return make_null();
}

/* gfx_text_width of [text, scale?] (or of "text") — pixel width of `text`
 * under the ACTIVE text renderer: TTF metrics when SDL2_ttf + a font are
 * loaded, the bitmap advance (len * 6 * scale) otherwise. lib/ui layout
 * routes through this so proportional text doesn't break centering (#593).
 * Works without an open window (layout can be computed before gfx_open). */
Value* builtin_gfx_text_width(Value *arg) {
    const char *text = NULL;
    int scale = 1;
    if (arg && arg->type == VAL_STR) {
        text = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1
               && arg->data.list.items[0]->type == VAL_STR) {
        text = arg->data.list.items[0]->data.str;
        if (arg->data.list.count >= 2 && arg->data.list.items[1]->type == VAL_NUM)
            scale = (int)arg->data.list.items[1]->data.num;
    }
    if (!text) return make_num(0);
    if (scale < 1) scale = 1;
    if (*text && ttf_available()) {
        void *font = ttf_font_for_scale(scale);
        int w = 0, h = 0;
        if (font && p_TTF_SizeUTF8(font, text, &w, &h) == 0)
            return make_num((double)w);
    }
    return make_num((double)strlen(text) * 6.0 * (double)scale);
}

/* gfx_text_height of scale? (number, [scale], or null → 1) — pixel line
 * height under the ACTIVE text renderer: TTF font height when active,
 * the bitmap glyph height (7 * scale) otherwise. */
Value* builtin_gfx_text_height(Value *arg) {
    int scale = 1;
    if (arg && arg->type == VAL_NUM) {
        scale = (int)arg->data.num;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1
               && arg->data.list.items[0]->type == VAL_NUM) {
        scale = (int)arg->data.list.items[0]->data.num;
    }
    if (scale < 1) scale = 1;
    if (ttf_available()) {
        void *font = ttf_font_for_scale(scale);
        if (font) return make_num((double)p_TTF_FontHeight(font));
    }
    return make_num(7.0 * (double)scale);
}

/* ---- Audio Builtins ---- */

/* ================================================================
 * AUDIO CHANNEL MIXER (Tidepool GAP-002 / GAP-003)
 * ================================================================
 * The device runs in callback mode; up to AUDIO_MAX_CHANNELS clips play
 * concurrently, each with its own live volume and loop count (-1 =
 * infinite — the callback rewinds, so looping no longer multiplies
 * memory the way queue-mode audio_play_loop's N queued copies did).
 * Channel state is mutated only under SDL_LockAudioDevice. The pool
 * always succeeds: when full, the oldest finite channel is recycled
 * (callers historically ignore audio_play's return value, so a refusal
 * would be silent — see the fixed-pool rule). */
#define AUDIO_MAX_CHANNELS 16
typedef struct {
    int16_t *samples;   /* owned; freed on recycle/clear/close */
    int      count;
    int      pos;
    int      loops;     /* -1 infinite, else passes remaining */
    double   volume;    /* 0.0 .. 4.0 */
    int      active;
    unsigned seq;       /* recycle-oldest ordering */
} AudioChannel;
static AudioChannel g_audio_ch[AUDIO_MAX_CHANNELS];
static unsigned g_audio_seq = 0;

static void audio_mix_callback(void *ud, uint8_t *stream, int len) {
    (void)ud;
    int16_t *out = (int16_t*)stream;
    int n = len / 2;
    memset(stream, 0, (size_t)len);
    for (int c = 0; c < AUDIO_MAX_CHANNELS; c++) {
        AudioChannel *ch = &g_audio_ch[c];
        if (!ch->active || !ch->samples || ch->count <= 0) continue;
        for (int i = 0; i < n; i++) {
            if (ch->pos >= ch->count) {
                if (ch->loops < 0) { ch->pos = 0; }
                else if (ch->loops > 1) { ch->loops--; ch->pos = 0; }
                else { ch->active = 0; break; }
            }
            int32_t v = (int32_t)out[i]
                      + (int32_t)((double)ch->samples[ch->pos++] * ch->volume);
            if (v > 32767) v = 32767;
            if (v < -32768) v = -32768;
            out[i] = (int16_t)v;
        }
    }
}

/* Convert samples (floats -1..1) to an owned int16 buffer. Accepts a
 * VAL_LIST or a VAL_BUFFER (#578 — the buffer is the type the language
 * recommends for bulk samples and what a DAW render produces; forcing a
 * buffer→list conversion per play meant millions of appends + VAL_NUM
 * allocations just to feed the mixer). Returns NULL on bad shape or an
 * over-64MB clip. */
static int16_t* audio_convert_samples(Value *samples, int *out_n) {
    if (!samples) return NULL;
    if (samples->type == VAL_BUFFER) {
        int n = samples->data.buffer.count;
        if (n <= 0 || (double)n * sizeof(int16_t) > 64.0 * 1024.0 * 1024.0) return NULL;
        int16_t *buf = xmalloc_array(n, sizeof(int16_t));
        const double *src = samples->data.buffer.data;
        for (int i = 0; i < n; i++) {
            double s = src[i];
            if (s > 1.0) s = 1.0;
            if (s < -1.0) s = -1.0;
            buf[i] = (int16_t)(s * 32767);
        }
        *out_n = n;
        return buf;
    }
    if (samples->type != VAL_LIST) return NULL;
    int n = samples->data.list.count;
    if (n <= 0 || (double)n * sizeof(int16_t) > 64.0 * 1024.0 * 1024.0) return NULL;
    int16_t *buf = xmalloc_array(n, sizeof(int16_t));
    for (int i = 0; i < n; i++) {
        Value *v = samples->data.list.items[i];
        double s = (v && v->type == VAL_NUM) ? v->data.num : 0;
        if (s > 1.0) s = 1.0;
        if (s < -1.0) s = -1.0;
        buf[i] = (int16_t)(s * 32767);
    }
    *out_n = n;
    return buf;
}

/* Install a clip on a free (else oldest-finite, else oldest) channel.
 * Takes ownership of buf. Returns the 1-based channel id. */
static int audio_install_channel(int16_t *buf, int n, int loops) {
    int slot = -1;
    p_SDL_LockAudioDevice(g_audio_device);
    for (int c = 0; c < AUDIO_MAX_CHANNELS; c++)
        if (!g_audio_ch[c].active) { slot = c; break; }
    if (slot < 0) {
        unsigned best = 0; int best_c = -1;
        for (int c = 0; c < AUDIO_MAX_CHANNELS; c++) {
            AudioChannel *ch = &g_audio_ch[c];
            if (ch->loops >= 0 && (best_c < 0 || ch->seq < best)) {
                best = ch->seq; best_c = c;
            }
        }
        if (best_c < 0) {
            for (int c = 0; c < AUDIO_MAX_CHANNELS; c++)
                if (best_c < 0 || g_audio_ch[c].seq < best) {
                    best = g_audio_ch[c].seq; best_c = c;
                }
        }
        slot = best_c;
    }
    AudioChannel *ch = &g_audio_ch[slot];
    if (ch->samples) free(ch->samples);
    ch->samples = buf;
    ch->count = n;
    ch->pos = 0;
    ch->loops = loops;
    ch->volume = 1.0;
    ch->active = 1;
    ch->seq = ++g_audio_seq;
    p_SDL_UnlockAudioDevice(g_audio_device);
    return slot + 1;
}

static void audio_free_channels(int lock) {
    if (lock && g_audio_device) p_SDL_LockAudioDevice(g_audio_device);
    for (int c = 0; c < AUDIO_MAX_CHANNELS; c++) {
        if (g_audio_ch[c].samples) free(g_audio_ch[c].samples);
        memset(&g_audio_ch[c], 0, sizeof(AudioChannel));
    }
    if (lock && g_audio_device) p_SDL_UnlockAudioDevice(g_audio_device);
}

/* audio_open of [freq, channels] — open the mixer device (callback mode) */
Value* builtin_audio_open(Value *arg) {
    if (!g_sdl_lib) { if (!load_sdl2()) return make_num(0); }
    if (!p_SDL_OpenAudioDevice) {
        fprintf(stderr, "audio_open: SDL2 audio symbols not available\n");
        return make_num(0);
    }
    p_SDL_Init(MY_SDL_INIT_AUDIO);

    SDL_AudioSpec want = {0}, have = {0};
    want.freq = 44100;
    want.format = MY_SDL_AUDIO_S16LSB;
    want.channels = 1;
    want.samples = 1024;
    want.callback = audio_mix_callback;

    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 2) {
        want.freq = (int)arg->data.list.items[0]->data.num;
        want.channels = (int)arg->data.list.items[1]->data.num;
    }

    g_audio_device = p_SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (g_audio_device < 2) { g_audio_device = 0; return make_num(0); }
    g_audio_freq = have.freq;
    g_audio_channels = have.channels;
    p_SDL_PauseAudioDevice(g_audio_device, 0); /* start playing */
    return make_num(g_audio_device);
}

/* audio_close of null */
Value* builtin_audio_close(Value *arg) {
    (void)arg;
    if (g_audio_device) {
        p_SDL_CloseAudioDevice(g_audio_device); /* joins the audio thread */
        g_audio_device = 0;
        audio_free_channels(0);
    }
    return make_null();
}

/* audio_pause of flag — 1=pause, 0=unpause */
Value* builtin_audio_pause(Value *arg) {
    if (!g_audio_device) return make_null();
    int pause = (arg && arg->type == VAL_NUM) ? (int)arg->data.num : 1;
    p_SDL_PauseAudioDevice(g_audio_device, pause);
    return make_null();
}

/* ================================================================
 * AUDIO CAPTURE (#579 — DeslanStudio F-DS-17, live recording input)
 * ================================================================
 * Pull-model recording: SDL_OpenAudioDevice(iscapture=1) in queue mode
 * (callback == NULL) accumulates samples in SDL's internal queue;
 * audio_capture_read drains them with SDL_DequeueAudio. No callback
 * means no C->eigs re-entry and no new threading surface — the shape
 * matches the existing polling clients (gfx_poll loops,
 * DeslanStudio's transport_tick_recording).
 *
 * Tape-first: captured audio is the textbook nondeterministic input,
 * so audio_capture_open and audio_capture_read are TAKE/RECORD
 * builtins. Under EIGS_REPLAY the TAKE short-circuits before any SDL
 * call — replay never opens or reads a real microphone; the recorded
 * device id and sample buffers are served off the tape. The b[…]
 * buffer encoding round-trips through N records natively.
 *
 * AUDIO_CAPTURE_READ_MAX bounds one read at 2048 samples so a single
 * N record always fits the tape's TRACE_NONDET_MAX (64 KiB) budget:
 * worst-case %.17g is ~24 bytes/sample + ", " → ~53 KiB. An over-
 * budget record would be …<truncated> and replay would silently fall
 * back to the LIVE microphone — the exact divergence the tape exists
 * to prevent. Callers drain by looping until the read comes back
 * empty; the loop replays faithfully (one N record per call). */
#define AUDIO_CAPTURE_READ_MAX 2048

/* Build a VAL_BUFFER of `n` float samples in [-1, 1] from int16 PCM.
 * 32767 → 1.0 exactly (mirror of audio_convert_samples' s*32767). */
static Value* capture_samples_to_buffer(const int16_t *pcm, int n) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->refcount = 1;
    v->data.buffer.count = n;
    v->data.buffer.data = xcalloc(n > 0 ? (size_t)n : 1, sizeof(double));
    for (int i = 0; i < n; i++) {
        double s = (double)pcm[i] / 32767.0;
        if (s < -1.0) s = -1.0;   /* only -32768 exceeds */
        v->data.buffer.data[i] = s;
    }
    return v;
}

/* audio_capture_open of [freq, channels] — open the recording device
 * (queue mode, iscapture=1). Defaults 44100/1 like audio_open;
 * allowed_changes=0 so SDL converts to exactly the requested format.
 * Returns the device id (>= 2), or 0 when SDL/capture is unavailable.
 * Re-opening closes the previous capture device first. */
Value* builtin_audio_capture_open(Value *arg) {
    TRACE_NONDET_TAKE("audio_capture_open");
    if (!g_sdl_lib) {
        if (!load_sdl2()) TRACE_NONDET_RECORD("audio_capture_open", make_num(0));
    }
    if (!p_SDL_OpenAudioDevice || !p_SDL_DequeueAudio) {
        fprintf(stderr, "audio_capture_open: SDL2 capture symbols not available\n");
        TRACE_NONDET_RECORD("audio_capture_open", make_num(0));
    }
    p_SDL_Init(MY_SDL_INIT_AUDIO);

    SDL_AudioSpec want = {0}, have = {0};
    want.freq = 44100;
    want.format = MY_SDL_AUDIO_S16LSB;
    want.channels = 1;
    want.samples = 1024;
    want.callback = NULL;   /* queue mode: drain via SDL_DequeueAudio */

    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 2) {
        want.freq = (int)arg->data.list.items[0]->data.num;
        want.channels = (int)arg->data.list.items[1]->data.num;
    }

    if (g_capture_device) {
        p_SDL_CloseAudioDevice(g_capture_device);
        g_capture_device = 0;
    }
    g_capture_device = p_SDL_OpenAudioDevice(NULL, 1, &want, &have, 0);
    if (g_capture_device < 2) {
        g_capture_device = 0;
        TRACE_NONDET_RECORD("audio_capture_open", make_num(0));
    }
    p_SDL_PauseAudioDevice(g_capture_device, 0); /* start recording */
    TRACE_NONDET_RECORD("audio_capture_open", make_num(g_capture_device));
}

/* audio_capture_read of null — drain accumulated samples since the
 * last read as a buffer of floats in [-1, 1] (interleaved when the
 * device was opened with channels > 1). At most
 * AUDIO_CAPTURE_READ_MAX samples per call — loop until the returned
 * buffer is empty to drain fully. Empty buffer = nothing new yet;
 * null = no capture device open. */
Value* builtin_audio_capture_read(Value *arg) {
    (void)arg;
    TRACE_NONDET_TAKE("audio_capture_read");
    if (!g_capture_device)
        TRACE_NONDET_RECORD("audio_capture_read", make_null());
    int16_t pcm[AUDIO_CAPTURE_READ_MAX];
    Uint32 got = p_SDL_DequeueAudio(g_capture_device, pcm, sizeof pcm);
    TRACE_NONDET_RECORD("audio_capture_read",
                        capture_samples_to_buffer(pcm, (int)(got / 2)));
}

/* audio_capture_close of null — stop and close the recording device.
 * Undrained samples are dropped. Safe to call twice / with no device. */
Value* builtin_audio_capture_close(Value *arg) {
    (void)arg;
    if (g_capture_device) {
        p_SDL_CloseAudioDevice(g_capture_device);
        g_capture_device = 0;
    }
    return make_null();
}

/* audio_music_play of [path, loops] — stream a music file (mp3/ogg/wav) via
 * SDL_mixer. loops: -1 = loop forever, 0 = play once, N = N+1 plays. Replaces
 * any current track. Returns 1 on success, 0 on failure (missing mixer lib,
 * unreadable/undecodable file, no audio device). */
Value* builtin_audio_music_play(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1) return make_num(0);
    Value *pv = arg->data.list.items[0];
    if (pv->type != VAL_STR) return make_num(0);
    const char *path = pv->data.str;
    int loops = (arg->data.list.count >= 2 && arg->data.list.items[1]->type == VAL_NUM)
                ? (int)arg->data.list.items[1]->data.num : -1;
    if (!load_sdl2()) return make_num(0);
    p_SDL_Init(MY_SDL_INIT_AUDIO);      /* ensure the audio subsystem is up */
    if (!load_sdl_mixer()) return make_num(0);
    if (!g_mixer_open) {
        p_Mix_Init(MY_MIX_INIT_MP3);
        /* Mix_OpenAudioDevice (not the legacy Mix_OpenAudio) so the music
         * device coexists with the SFX device opened via SDL_OpenAudioDevice. */
        if (p_Mix_OpenAudioDevice(44100, MY_AUDIO_S16SYS, 2, 2048, NULL, 0) < 0) {
            fprintf(stderr, "audio_music: Mix_OpenAudioDevice failed: %s\n",
                    p_SDL_GetError ? p_SDL_GetError() : "?");
            return make_num(0);
        }
        g_mixer_open = 1;
    }
    if (g_music) { p_Mix_HaltMusic(); p_Mix_FreeMusic(g_music); g_music = NULL; }
    g_music = p_Mix_LoadMUS(path);
    if (!g_music) {
        fprintf(stderr, "audio_music: cannot load '%s': %s\n", path,
                p_SDL_GetError ? p_SDL_GetError() : "?");
        return make_num(0);
    }
    if (p_Mix_PlayMusic(g_music, loops) < 0) {
        fprintf(stderr, "audio_music: play failed: %s\n",
                p_SDL_GetError ? p_SDL_GetError() : "?");
        return make_num(0);
    }
    return make_num(1);
}

/* audio_music_volume of v — music volume 0..128 */
Value* builtin_audio_music_volume(Value *arg) {
    if (!g_mixer_open || !p_Mix_VolumeMusic) return make_null();
    int v = 0;
    if (arg && arg->type == VAL_NUM) v = (int)arg->data.num;
    else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1
             && arg->data.list.items[0]->type == VAL_NUM)
        v = (int)arg->data.list.items[0]->data.num;
    if (v < 0) v = 0;
    if (v > MY_MIX_MAX_VOLUME) v = MY_MIX_MAX_VOLUME;
    p_Mix_VolumeMusic(v);
    return make_null();
}

/* audio_music_stop of null — halt and free the current track. */
Value* builtin_audio_music_stop(Value *arg) {
    (void)arg;
    if (g_mixer_open && p_Mix_HaltMusic) p_Mix_HaltMusic();
    if (g_music && p_Mix_FreeMusic) { p_Mix_FreeMusic(g_music); g_music = NULL; }
    return make_null();
}

/* audio_play of samples — convert float list [-1,1] to int16, queue */
Value* builtin_audio_play(Value *arg) {
    if (!g_audio_device) return make_num(0);
    int n = 0;
    int16_t *buf = audio_convert_samples(arg, &n);
    if (!buf) return make_num(0);
    return make_num(audio_install_channel(buf, n, 1));
}

/* audio_play_loop of [samples, loops] — play `samples` `loops` times on
 * one mixer channel. loops == -1 loops forever (the callback rewinds;
 * no memory multiplication — Tidepool GAP-002). Returns the channel id,
 * or 0 on a bad arg / closed device. */
Value* builtin_audio_play_loop(Value *arg) {
    if (!g_audio_device || !arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *samples = arg->data.list.items[0];
    Value *loops_v = arg->data.list.items[1];
    if (!loops_v || loops_v->type != VAL_NUM) return make_num(0);
    /* #152: NaN/huge casts are UB; -1 is the one negative with meaning. */
    double loops_d = loops_v->data.num;
    int loops;
    if (loops_d == -1.0) loops = -1;
    else if (isnan(loops_d) || loops_d < 1.0 || loops_d > 10000.0) return make_num(0);
    else loops = (int)loops_d;
    int n = 0;
    int16_t *buf = audio_convert_samples(samples, &n);
    if (!buf) return make_num(0);
    return make_num(audio_install_channel(buf, n, loops));
}

/* audio_volume of [channel, vol] — live per-channel volume, 0.0..4.0
 * (Tidepool GAP-003). Returns 1, or 0 on a bad channel/arg. */
Value* builtin_audio_volume(Value *arg) {
    if (!g_audio_device || !arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *ch_v = arg->data.list.items[0];
    Value *vol_v = arg->data.list.items[1];
    if (!ch_v || ch_v->type != VAL_NUM || !vol_v || vol_v->type != VAL_NUM)
        return make_num(0);
    int c = (int)ch_v->data.num - 1;
    if (c < 0 || c >= AUDIO_MAX_CHANNELS) return make_num(0);
    double vol = vol_v->data.num;
    if (isnan(vol) || vol < 0.0) vol = 0.0;
    if (vol > 4.0) vol = 4.0;
    p_SDL_LockAudioDevice(g_audio_device);
    int ok = g_audio_ch[c].active;
    if (ok) g_audio_ch[c].volume = vol;
    p_SDL_UnlockAudioDevice(g_audio_device);
    return make_num(ok);
}

/* audio_stop of channel — stop one mixer channel. Returns 1, or 0 on a
 * bad/inactive channel. */
Value* builtin_audio_stop(Value *arg) {
    if (!g_audio_device || !arg || arg->type != VAL_NUM) return make_num(0);
    int c = (int)arg->data.num - 1;
    if (c < 0 || c >= AUDIO_MAX_CHANNELS) return make_num(0);
    p_SDL_LockAudioDevice(g_audio_device);
    int ok = g_audio_ch[c].active;
    g_audio_ch[c].active = 0;
    p_SDL_UnlockAudioDevice(g_audio_device);
    return make_num(ok);
}

/* audio_queue_size of null — bytes queued */
Value* builtin_audio_queue_size(Value *arg) {
    (void)arg;
    if (!g_audio_device) return make_num(0);
    /* Mixer equivalent of the old queued-bytes count: unplayed bytes
     * summed over active FINITE channels (infinite loops would be
     * infinity; they are excluded so refill-style polls terminate). */
    double bytes = 0;
    p_SDL_LockAudioDevice(g_audio_device);
    for (int c = 0; c < AUDIO_MAX_CHANNELS; c++) {
        AudioChannel *ch = &g_audio_ch[c];
        if (!ch->active || ch->loops < 0) continue;
        double rem = (double)(ch->count - ch->pos)
                   + (double)(ch->loops - 1) * (double)ch->count;
        bytes += rem * (double)sizeof(int16_t);
    }
    p_SDL_UnlockAudioDevice(g_audio_device);
    return make_num(bytes);
}

/* audio_clear of null — stop all mixer channels and free their clips */
Value* builtin_audio_clear(Value *arg) {
    (void)arg;
    if (g_audio_device) audio_free_channels(1);
    return make_null();
}

/* audio_sine of [freq, duration, amplitude] — generate sine wave samples */
Value* builtin_audio_sine(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_list(0);
    double freq = arg->data.list.items[0]->data.num;
    double dur = arg->data.list.items[1]->data.num;
    double amp = arg->data.list.items[2]->data.num;
    int rate = g_audio_freq > 0 ? g_audio_freq : 44100;
    int n = (int)(dur * rate);
    if (n <= 0 || n > rate * 30) return make_list(0);

    Value *list = make_list(n);
    for (int i = 0; i < n; i++) {
        double t = (double)i / rate;
        double s = sin(2.0 * M_PI * freq * t) * amp;
        list_append_owned(list, make_num(s));
    }
    return list;
}

/* audio_saw of [freq, duration, amplitude] — sawtooth wave */
Value* builtin_audio_saw(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_list(0);
    double freq = arg->data.list.items[0]->data.num;
    double dur = arg->data.list.items[1]->data.num;
    double amp = arg->data.list.items[2]->data.num;
    int rate = g_audio_freq > 0 ? g_audio_freq : 44100;
    int n = (int)(dur * rate);
    if (n <= 0 || n > rate * 30) return make_list(0);

    Value *list = make_list(n);
    for (int i = 0; i < n; i++) {
        double t = (double)i / rate;
        double s = 2.0 * (t * freq - floor(t * freq + 0.5)) * amp;
        list_append_owned(list, make_num(s));
    }
    return list;
}

/* audio_square of [freq, duration, amplitude] — square wave */
Value* builtin_audio_square(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_list(0);
    double freq = arg->data.list.items[0]->data.num;
    double dur = arg->data.list.items[1]->data.num;
    double amp = arg->data.list.items[2]->data.num;
    int rate = g_audio_freq > 0 ? g_audio_freq : 44100;
    int n = (int)(dur * rate);
    if (n <= 0 || n > rate * 30) return make_list(0);

    Value *list = make_list(n);
    for (int i = 0; i < n; i++) {
        double t = (double)i / rate;
        double s = (sin(2.0 * M_PI * freq * t) >= 0 ? 1.0 : -1.0) * amp;
        list_append_owned(list, make_num(s));
    }
    return list;
}

/* audio_sweep of [freq_start, freq_end, duration, amplitude, waveform]
   waveform: 0=sine, 1=sawtooth.  Continuous phase sweep. */
Value* builtin_audio_sweep(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 5) return make_list(0);
    double f0 = arg->data.list.items[0]->data.num;
    double f1 = arg->data.list.items[1]->data.num;
    double dur = arg->data.list.items[2]->data.num;
    double amp = arg->data.list.items[3]->data.num;
    int wave = (int)arg->data.list.items[4]->data.num;
    int rate = g_audio_freq > 0 ? g_audio_freq : 44100;
    int n = (int)(dur * rate);
    if (n <= 0 || n > rate * 30) return make_list(0);

    Value *list = make_list(n);
    double phase = 0.0;
    for (int i = 0; i < n; i++) {
        double t = (double)i / n;
        double freq = f0 + (f1 - f0) * t;
        phase += freq / rate;
        if (phase > 1.0) phase -= 1.0;
        double s;
        if (wave == 0)
            s = sin(2.0 * M_PI * phase) * amp;
        else
            s = (2.0 * phase - 1.0) * amp;
        list_append_owned(list, make_num(s));
    }
    return list;
}

/* audio_noise of [duration, amplitude] — white noise */
Value* builtin_audio_noise(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_list(0);
    double dur = arg->data.list.items[0]->data.num;
    double amp = arg->data.list.items[1]->data.num;
    int rate = g_audio_freq > 0 ? g_audio_freq : 44100;
    int n = (int)(dur * rate);
    if (n <= 0 || n > rate * 30) return make_list(0);

    Value *list = make_list(n);
    for (int i = 0; i < n; i++) {
        double s = ((double)rand() / RAND_MAX * 2.0 - 1.0) * amp;
        list_append_owned(list, make_num(s));
    }
    return list;
}

/* audio_mix of [samples_a, samples_b] — add and clamp */
Value* builtin_audio_mix(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_list(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (a->type != VAL_LIST || b->type != VAL_LIST) return make_list(0);
    int n = a->data.list.count > b->data.list.count ? a->data.list.count : b->data.list.count;

    Value *out = make_list(n);
    for (int i = 0; i < n; i++) {
        double sa = (i < a->data.list.count && a->data.list.items[i]->type == VAL_NUM) ? a->data.list.items[i]->data.num : 0;
        double sb = (i < b->data.list.count && b->data.list.items[i]->type == VAL_NUM) ? b->data.list.items[i]->data.num : 0;
        double mixed = sa + sb;
        if (mixed > 1.0) mixed = 1.0;
        if (mixed < -1.0) mixed = -1.0;
        list_append_owned(out, make_num(mixed));
    }
    return out;
}

/* audio_gain of [samples, volume] — scale and clamp */
Value* builtin_audio_gain(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_list(0);
    Value *samples = arg->data.list.items[0];
    if (samples->type != VAL_LIST) return make_list(0);
    double vol = arg->data.list.items[1]->data.num;
    int n = samples->data.list.count;

    Value *out = make_list(n);
    for (int i = 0; i < n; i++) {
        double s = (samples->data.list.items[i]->type == VAL_NUM) ? samples->data.list.items[i]->data.num : 0;
        s *= vol;
        if (s > 1.0) s = 1.0;
        if (s < -1.0) s = -1.0;
        list_append_owned(out, make_num(s));
    }
    return out;
}

/* audio_envelope of [samples, attack, decay, sustain_level, release] — ADSR */
Value* builtin_audio_envelope(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 5) return make_list(0);
    Value *samples = arg->data.list.items[0];
    if (samples->type != VAL_LIST) return make_list(0);
    double attack = arg->data.list.items[1]->data.num;
    double decay = arg->data.list.items[2]->data.num;
    double sustain = arg->data.list.items[3]->data.num;
    double release = arg->data.list.items[4]->data.num;

    int n = samples->data.list.count;
    int rate = g_audio_freq > 0 ? g_audio_freq : 44100;
    int a_samples = (int)(attack * rate);
    int d_samples = (int)(decay * rate);
    int r_samples = (int)(release * rate);
    int s_start = a_samples + d_samples;
    int r_start = n - r_samples;
    if (r_start < s_start) r_start = s_start;

    Value *out = make_list(n);
    for (int i = 0; i < n; i++) {
        double env;
        if (i < a_samples) {
            /* Attack: 0 -> 1 */
            env = (a_samples > 0) ? (double)i / a_samples : 1.0;
        } else if (i < s_start) {
            /* Decay: 1 -> sustain */
            double frac = (d_samples > 0) ? (double)(i - a_samples) / d_samples : 1.0;
            env = 1.0 - (1.0 - sustain) * frac;
        } else if (i < r_start) {
            /* Sustain */
            env = sustain;
        } else {
            /* Release: sustain -> 0 */
            double frac = (r_samples > 0) ? (double)(i - r_start) / r_samples : 1.0;
            env = sustain * (1.0 - frac);
        }
        double s = (samples->data.list.items[i]->type == VAL_NUM) ? samples->data.list.items[i]->data.num : 0;
        s *= env;
        list_append_owned(out, make_num(s));
    }
    return out;
}

/* gfx_fb of [buffer, width, height, x, y, scale]
 * Blit a framebuffer (VAL_BUFFER of width*height palette indices 0-3) to the
 * renderer as a scaled texture.  One C call replaces width*height draw calls.
 * Palette: 0 → white (0xFF), 1 → light (0xAA), 2 → dark (0x55), 3 → black (0x00). */
Value* builtin_gfx_fb(Value *arg) {
    if (!g_renderer || !p_SDL_CreateTexture || !p_SDL_UpdateTexture || !p_SDL_RenderCopy)
        return make_null();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 6)
        return make_null();
    Value *buf  = arg->data.list.items[0];
    int    w    = (int)arg->data.list.items[1]->data.num;
    int    h    = (int)arg->data.list.items[2]->data.num;
    int    dx   = (int)arg->data.list.items[3]->data.num;
    int    dy   = (int)arg->data.list.items[4]->data.num;
    int    sc   = (int)arg->data.list.items[5]->data.num;
    if (!buf || buf->type != VAL_BUFFER || w <= 0 || h <= 0 || sc <= 0)
        return make_null();
    if (buf->data.buffer.count < w * h)
        return make_null();

    /* Recreate texture if size changed */
    if (!g_fb_texture || g_fb_w != w || g_fb_h != h) {
        if (g_fb_texture) p_SDL_DestroyTexture(g_fb_texture);
        g_fb_texture = p_SDL_CreateTexture(g_renderer,
            MY_SDL_PIXELFORMAT_ARGB8888, MY_SDL_TEXTUREACCESS_STREAMING, w, h);
        if (!g_fb_texture) return make_null();
        g_fb_w = w;
        g_fb_h = h;
    }

    /* GB shade palette: index → ARGB */
    static const Uint32 palette[4] = {
        0xFFFFFFFF, /* 0 = white  */
        0xFFAAAAAA, /* 1 = light  */
        0xFF555555, /* 2 = dark   */
        0xFF000000  /* 3 = black  */
    };

    /* Convert buffer → ARGB pixel array */
    int total = w * h;
    Uint32 *pixels = xmalloc_array(total, sizeof(Uint32));
    double *src = buf->data.buffer.data;
    for (int i = 0; i < total; i++) {
        int idx = (int)src[i];
        pixels[i] = palette[idx & 3];
    }

    p_SDL_UpdateTexture(g_fb_texture, NULL, pixels, w * (int)sizeof(Uint32));
    free(pixels);

    SDL_Rect dst = { dx, dy, w * sc, h * sc };
    p_SDL_RenderCopy(g_renderer, g_fb_texture, NULL, &dst);
    return make_null();
}

/* ================================================================
 * ppu_render_frame of [mem_buf, fb_buf]
 * Full Game Boy PPU rendering in C — all 144 scanlines, BG + window + sprites.
 * mem_buf: VAL_BUFFER of 65536 (Game Boy memory map)
 * fb_buf:  VAL_BUFFER of 23040 (160x144 framebuffer, palette indices 0-3)
 * Reads LCDC, scroll, palette, VRAM, OAM registers directly from mem_buf.
 * ================================================================ */
Value* builtin_ppu_render_frame(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_null();
    Value *mem_v = arg->data.list.items[0];
    Value *fb_v  = arg->data.list.items[1];
    if (!mem_v || mem_v->type != VAL_BUFFER || mem_v->data.buffer.count < 65536)
        return make_null();
    if (!fb_v || fb_v->type != VAL_BUFFER || fb_v->data.buffer.count < 23040)
        return make_null();

    double *mem = mem_v->data.buffer.data;
    double *fb  = fb_v->data.buffer.data;

    int lcdc = (int)mem[0xFF40];
    if (!(lcdc & 0x80)) {
        /* LCD off — blank */
        for (int i = 0; i < 23040; i++) fb[i] = 0;
        return make_null();
    }

    int scy = (int)mem[0xFF42];
    int scx = (int)mem[0xFF43];
    int bgp_raw = (int)mem[0xFF47];
    int obp0_raw = (int)mem[0xFF48];
    int obp1_raw = (int)mem[0xFF49];
    int wy = (int)mem[0xFF4A];
    int wx = (int)mem[0xFF4B];

    /* Decode palettes */
    int bgp[4]  = { bgp_raw & 3, (bgp_raw >> 2) & 3, (bgp_raw >> 4) & 3, (bgp_raw >> 6) & 3 };
    int obp0[4] = { obp0_raw & 3, (obp0_raw >> 2) & 3, (obp0_raw >> 4) & 3, (obp0_raw >> 6) & 3 };
    int obp1[4] = { obp1_raw & 3, (obp1_raw >> 2) & 3, (obp1_raw >> 4) & 3, (obp1_raw >> 6) & 3 };

    int bg_map_base  = (lcdc & 0x08) ? 0x9C00 : 0x9800;
    int win_map_base = (lcdc & 0x40) ? 0x9C00 : 0x9800;
    int unsigned_mode = (lcdc & 0x10) != 0;
    int sprite_h = (lcdc & 0x04) ? 16 : 8;
    int bg_en  = lcdc & 0x01;
    int spr_en = lcdc & 0x02;
    /* On DMG, LCDC bit 0 disables the window as well as the BG — keep in
     * lockstep with the script PPU twin (DMG src/ppu.eigs, DMG#31). */
    int win_en = bg_en && (lcdc & 0x20);

    /* Per-scanline BG priority for sprite compositing */
    uint8_t bg_pri[160];

    /* Window internal line counter: advances only on scanlines where the
     * window actually renders (DMG#18) — `ly - wy` is wrong when the
     * window is toggled or WY changes mid-frame. Kept in lockstep with
     * the script-PPU twin (DMG src/ppu.eigs). */
    int win_line = 0;

    for (int ly = 0; ly < 144; ly++) {
        int base = ly * 160;

        /* ---- Background ---- */
        if (bg_en) {
            int bg_y = (ly + scy) & 0xFF;
            int tile_row = bg_y & 7;
            int map_row = (bg_y >> 3) * 32;
            int prev_tile_x = -1;
            int tile_lo = 0, tile_hi = 0;

            for (int px = 0; px < 160; px++) {
                int bg_x = (px + scx) & 0xFF;
                int tile_x = bg_x >> 3;

                if (tile_x != prev_tile_x) {
                    prev_tile_x = tile_x;
                    int tile_num = (int)mem[bg_map_base + map_row + tile_x];
                    int tile_addr;
                    if (unsigned_mode)
                        tile_addr = 0x8000 + tile_num * 16 + tile_row * 2;
                    else
                        tile_addr = (tile_num >= 128)
                            ? 0x8800 + (tile_num - 128) * 16 + tile_row * 2
                            : 0x9000 + tile_num * 16 + tile_row * 2;
                    tile_lo = (int)mem[tile_addr];
                    tile_hi = (int)mem[tile_addr + 1];
                }

                int bit = 7 - (bg_x & 7);
                int cid = ((tile_hi >> bit) & 1) << 1 | ((tile_lo >> bit) & 1);
                fb[base + px] = bgp[cid];
                bg_pri[px] = (uint8_t)cid;
            }
        } else {
            for (int px = 0; px < 160; px++) {
                fb[base + px] = 0;
                bg_pri[px] = 0;
            }
        }

        /* ---- Window ---- */
        if (win_en && ly >= wy && wx <= 166) {
            int win_y = win_line++;
            int win_row = win_y & 7;
            int win_map_row = (win_y >> 3) * 32;
            int start_x = wx - 7;
            if (start_x < 0) start_x = 0;
            int prev_wtx = -1;
            int wtile_lo = 0, wtile_hi = 0;

            for (int sx = start_x; sx < 160; sx++) {
                int win_x = sx - (wx - 7);
                int wtx = win_x >> 3;
                if (wtx != prev_wtx) {
                    prev_wtx = wtx;
                    int wtn = (int)mem[win_map_base + win_map_row + wtx];
                    int wta;
                    if (unsigned_mode)
                        wta = 0x8000 + wtn * 16 + win_row * 2;
                    else
                        wta = (wtn >= 128)
                            ? 0x8800 + (wtn - 128) * 16 + win_row * 2
                            : 0x9000 + wtn * 16 + win_row * 2;
                    wtile_lo = (int)mem[wta];
                    wtile_hi = (int)mem[wta + 1];
                }
                int wbit = 7 - (win_x & 7);
                int wcid = ((wtile_hi >> wbit) & 1) << 1 | ((wtile_lo >> wbit) & 1);
                fb[base + sx] = bgp[wcid];
                bg_pri[sx] = (uint8_t)wcid;
            }
        }

        /* ---- Sprites ---- */
        if (spr_en) {
            /* Collect sprites on this scanline (max 10) */
            typedef struct { int sx, sy, tile, flags, oam_idx; } SprEntry;
            SprEntry sprites[10];
            int spr_count = 0;

            for (int i = 0; i < 40 && spr_count < 10; i++) {
                int oam = 0xFE00 + i * 4;
                int sy = (int)mem[oam] - 16;
                int sx = (int)mem[oam + 1] - 8;
                if (ly >= sy && ly < sy + sprite_h) {
                    sprites[spr_count].sx = sx;
                    sprites[spr_count].sy = sy;
                    sprites[spr_count].tile = (int)mem[oam + 2];
                    sprites[spr_count].flags = (int)mem[oam + 3];
                    sprites[spr_count].oam_idx = i;
                    spr_count++;
                }
            }

            /* Sort by X (insertion sort, stable) */
            for (int i = 1; i < spr_count; i++) {
                SprEntry tmp = sprites[i];
                int j = i;
                while (j > 0 && sprites[j-1].sx > tmp.sx) {
                    sprites[j] = sprites[j-1];
                    j--;
                }
                sprites[j] = tmp;
            }

            /* Render in reverse (higher priority overwrites) */
            for (int si = spr_count - 1; si >= 0; si--) {
                int sx = sprites[si].sx;
                int sy = sprites[si].sy;
                int tile = sprites[si].tile;
                int flags = sprites[si].flags;
                int bg_over = flags & 0x80;
                int y_flip  = flags & 0x40;
                int x_flip  = flags & 0x20;
                int *spal = (flags & 0x10) ? obp1 : obp0;

                int row = ly - sy;
                if (y_flip) row = (sprite_h - 1) - row;
                if (sprite_h == 16) {
                    tile &= 0xFE;
                    if (row >= 8) { tile++; row -= 8; }
                }

                int taddr = 0x8000 + tile * 16 + row * 2;
                int slo = (int)mem[taddr];
                int shi = (int)mem[taddr + 1];

                for (int col = 0; col < 8; col++) {
                    int scr_x = sx + col;
                    if (scr_x < 0 || scr_x >= 160) continue;
                    int bit = x_flip ? col : (7 - col);
                    int cid = ((shi >> bit) & 1) << 1 | ((slo >> bit) & 1);
                    if (cid == 0) continue; /* transparent */
                    if (bg_over && bg_pri[scr_x] != 0) continue;
                    fb[base + scr_x] = spal[cid];
                }
            }
        }
    }
    return make_null();
}

void register_gfx_builtins(Env *env) {
    /* Expanded from ext_names.h — the shared name list the linter's E003
     * binding base also expands, so registration and name-resolution
     * cannot drift. Add a builtin there, not here. */
#define X(name, fn) env_set_local_owned(env, #name, make_builtin(fn));
    EIGS_GFX_BUILTINS(X)
#undef X
}

#endif /* EIGENSCRIPT_EXT_GFX */
