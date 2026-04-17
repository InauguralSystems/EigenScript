/*
 * EigenScript Graphics Extension — SDL2 builtins.
 * Dynamically loads libSDL2 at runtime (no dev headers needed).
 *
 * Builtins: gfx_open, gfx_close, gfx_clear, gfx_rect, gfx_line,
 *           gfx_point, gfx_circle, gfx_present, gfx_poll, gfx_ticks, gfx_delay
 */

#include "eigenscript.h"

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

typedef union {
    Uint32 type;
    SDL_KeyboardEvent key;
    SDL_MouseMotionEvent motion;
    SDL_MouseButtonEvent button;
    Uint8 padding[64];
} SDL_Event;

typedef void SDL_Window;
typedef void SDL_Renderer;

/* SDL2 constants */
#define MY_SDL_INIT_VIDEO       0x00000020u
#define MY_SDL_QUIT_EVENT       0x100u
#define MY_SDL_KEYDOWN          0x300u
#define MY_SDL_KEYUP            0x301u
#define MY_SDL_MOUSEMOTION      0x400u
#define MY_SDL_MOUSEBUTTONDOWN  0x401u
#define MY_SDL_MOUSEBUTTONUP    0x402u
#define MY_SDL_WINDOWPOS_CENTERED 0x2FFF0000
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
static Uint32 (*p_SDL_GetTicks)(void);
static void (*p_SDL_Delay)(Uint32);

static int load_sdl2(void) {
    if (g_sdl_lib) return 1;
    g_sdl_lib = dlopen("libSDL2-2.0.so.0", RTLD_LAZY);
    if (!g_sdl_lib) g_sdl_lib = dlopen("libSDL2.so", RTLD_LAZY);
    if (!g_sdl_lib) return 0;

    #define LOAD(name) p_##name = dlsym(g_sdl_lib, #name)
    LOAD(SDL_Init); LOAD(SDL_Quit); LOAD(SDL_GetError);
    LOAD(SDL_CreateWindow); LOAD(SDL_DestroyWindow); LOAD(SDL_SetWindowTitle);
    LOAD(SDL_CreateRenderer); LOAD(SDL_DestroyRenderer);
    LOAD(SDL_SetRenderDrawColor); LOAD(SDL_SetRenderDrawBlendMode);
    LOAD(SDL_RenderClear); LOAD(SDL_RenderFillRect);
    LOAD(SDL_RenderDrawLine); LOAD(SDL_RenderDrawPoint);
    LOAD(SDL_RenderPresent); LOAD(SDL_PollEvent);
    LOAD(SDL_GetTicks); LOAD(SDL_Delay);
    #undef LOAD
    return 1;
}

/* Scancode to key name */
static const char* scancode_name(int sc) {
    switch (sc) {
        case 4: return "a"; case 7: return "d"; case 8: return "e";
        case 18: return "o"; case 19: return "p"; case 20: return "q";
        case 21: return "r"; case 22: return "s"; case 26: return "w";
        case 30: return "1"; case 31: return "2"; case 32: return "3";
        case 33: return "4"; case 34: return "5"; case 35: return "6";
        case 41: return "escape"; case 43: return "tab"; case 44: return "space";
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
    g_window = p_SDL_CreateWindow(title, MY_SDL_WINDOWPOS_CENTERED, MY_SDL_WINDOWPOS_CENTERED, w, h, 0);
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
        return make_num(0);
    }
    p_SDL_SetRenderDrawBlendMode(g_renderer, MY_SDL_BLENDMODE_BLEND);
    return make_num(1);
}

/* gfx_close of null */
Value* builtin_gfx_close(Value *arg) {
    (void)arg;
    if (g_renderer) { p_SDL_DestroyRenderer(g_renderer); g_renderer = NULL; }
    if (g_window) { p_SDL_DestroyWindow(g_window); g_window = NULL; }
    if (g_sdl_lib) p_SDL_Quit();
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

/* gfx_present of null — flip buffer to screen */
Value* builtin_gfx_present(Value *arg) {
    (void)arg;
    if (g_renderer) p_SDL_RenderPresent(g_renderer);
    return make_null();
}

/* gfx_poll of null — return next event as dict, or null if none.
 * {"type": "keydown", "key": "up"} / {"type": "quit"} /
 * {"type": "mousemove", "x": 100, "y": 200} / etc. */
Value* builtin_gfx_poll(Value *arg) {
    (void)arg;
    if (!g_window) return make_null();
    SDL_Event ev;
    if (!p_SDL_PollEvent(&ev)) return make_null();

    Value *d = make_dict(4);
    switch (ev.type) {
        case MY_SDL_QUIT_EVENT:
            dict_set(d, "type", make_str("quit"));
            break;
        case MY_SDL_KEYDOWN:
            dict_set(d, "type", make_str("keydown"));
            dict_set(d, "key", make_str(scancode_name(ev.key.keysym.scancode)));
            dict_set(d, "scancode", make_num(ev.key.keysym.scancode));
            break;
        case MY_SDL_KEYUP:
            dict_set(d, "type", make_str("keyup"));
            dict_set(d, "key", make_str(scancode_name(ev.key.keysym.scancode)));
            dict_set(d, "scancode", make_num(ev.key.keysym.scancode));
            break;
        case MY_SDL_MOUSEMOTION:
            dict_set(d, "type", make_str("mousemove"));
            dict_set(d, "x", make_num(ev.motion.x));
            dict_set(d, "y", make_num(ev.motion.y));
            break;
        case MY_SDL_MOUSEBUTTONDOWN:
            dict_set(d, "type", make_str("mousedown"));
            dict_set(d, "button", make_num(ev.button.button));
            dict_set(d, "x", make_num(ev.button.x));
            dict_set(d, "y", make_num(ev.button.y));
            break;
        case MY_SDL_MOUSEBUTTONUP:
            dict_set(d, "type", make_str("mouseup"));
            dict_set(d, "button", make_num(ev.button.button));
            dict_set(d, "x", make_num(ev.button.x));
            dict_set(d, "y", make_num(ev.button.y));
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

/* gfx_text of [x, y, text, r, g, b] or [x, y, text, r, g, b, scale] */
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

void register_gfx_builtins(Env *env) {
    env_set_local(env, "gfx_open", make_builtin(builtin_gfx_open));
    env_set_local(env, "gfx_close", make_builtin(builtin_gfx_close));
    env_set_local(env, "gfx_clear", make_builtin(builtin_gfx_clear));
    env_set_local(env, "gfx_rect", make_builtin(builtin_gfx_rect));
    env_set_local(env, "gfx_line", make_builtin(builtin_gfx_line));
    env_set_local(env, "gfx_point", make_builtin(builtin_gfx_point));
    env_set_local(env, "gfx_circle", make_builtin(builtin_gfx_circle));
    env_set_local(env, "gfx_present", make_builtin(builtin_gfx_present));
    env_set_local(env, "gfx_poll", make_builtin(builtin_gfx_poll));
    env_set_local(env, "gfx_ticks", make_builtin(builtin_gfx_ticks));
    env_set_local(env, "gfx_delay", make_builtin(builtin_gfx_delay));
    env_set_local(env, "gfx_title", make_builtin(builtin_gfx_title));
    env_set_local(env, "gfx_text", make_builtin(builtin_gfx_text));
}

#endif /* EIGENSCRIPT_EXT_GFX */
