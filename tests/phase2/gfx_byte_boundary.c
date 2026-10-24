/* #1758 R1.6e: pre-registered deferred buffer_read_byte boundary.
 * Stock buffers receive raw stored payloads after construction, so this
 * reaches the actual gfx_fb/ppu_render_frame consumers before a scalar
 * producer can normalize or reject the fixture. SDL's real dummy renderer
 * supplies gfx_fb's sink; no SDL function is replaced.
 * Intended home: tests/phase2/gfx_byte_boundary.c. Success is 247 checks. */
#define EIGENSCRIPT_EXT_GFX 1
#include "eigenscript_all.c"
#include "../../src/ext_gfx.c"

static int gfx_byte_checks, gfx_byte_failures, gfx_byte_calls;

static void gfx_byte_check(int ok, const char *client, int strict,
                           const char *fixture, const char *claim) {
    ++gfx_byte_checks;
    if (!ok) {
        ++gfx_byte_failures;
        fprintf(stderr, "phase2-gfx-byte-test: FAIL %s strict=%d %s: %s\n",
                client, strict, fixture, claim);
    }
}

static void gfx_byte_clear_error(void) {
    eigs_clear_error_value();
    g_has_error = g_error_print_pending = 0;
    g_error_msg[0] = g_error_raw[0] = 0;
    g_math_flags = 0;
}

static Value *gfx_byte_stock_buffer(int count, const char *name) {
    Value *size = make_int(count);
    Value *buffer = builtin_buffer(size);
    val_decref(size);
    gfx_byte_check(buffer && buffer->type == VAL_BUFFER
                   && buffer->data.buffer.count == count,
                   "setup", 1, name, "stock buffer constructor");
    return buffer;
}

typedef struct {
    const char *name;
    double first, later;
    int reject, strict_nan;
    const char *diagnostic;
} GfxByteCase;

static const GfxByteCase gfx_byte_cases[] = {
    {"stored-NaN", NAN, 0.0, 1, 1, "expected a finite number"},
    {"stored-positive-infinity", INFINITY, 0.0, 1, 0, "expected a finite number"},
    {"stored-negative-infinity", -INFINITY, 0.0, 1, 0, "expected a finite number"},
    {"NaN-before-infinity", NAN, INFINITY, 1, 1, "expected a finite number"},
    {"fractional-byte", 1.5, 0.0, 1, 0, "no integer representation"},
    {"above-byte-domain", 256.0, 0.0, 1, 0, "outside [0, 255]"},
    {"integral-float-byte-255", 255.0, 0.0, 0, 0, NULL}
};

static uint64_t gfx_byte_raw_bits(const double *cell) {
    uint64_t bits;
    memcpy(&bits, cell, sizeof bits);
    return bits;
}

static int gfx_byte_frame_is(const Value *frame, double expected) {
    for (int i = 0; i < frame->data.buffer.count; ++i)
        if (frame->data.buffer.data[i] != expected) return 0;
    return 1;
}

static void gfx_byte_exercise(int ppu, int strict, const GfxByteCase *c,
                              Value *args, Value *source, Value *frame) {
    const char *client = ppu ? "ppu_render_frame" : "gfx_fb";
    int first = ppu ? 0xFF40 : 0;
    int later = ppu ? 0xFF42 : 1;
    memset(source->data.buffer.data, 0,
           (size_t)source->data.buffer.count * sizeof(double));
    /* These writes deliberately bypass scalar constructors and num_guard. */
    source->data.buffer.data[first] = c->first;
    source->data.buffer.data[later] = c->later;
    uint64_t first_bits = gfx_byte_raw_bits(&source->data.buffer.data[first]);
    uint64_t later_bits = gfx_byte_raw_bits(&source->data.buffer.data[later]);
    if (ppu) {
        for (int i = 0; i < frame->data.buffer.count; ++i)
            frame->data.buffer.data[i] = -17.0;
    } else {
        int rc = p_SDL_SetRenderDrawColor(g_renderer, 255, 255, 255, 255);
        int clear_rc = p_SDL_RenderClear(g_renderer);
        gfx_byte_check(rc == 0 && clear_rc == 0, client, strict, c->name,
                       "real renderer starts white");
    }
    g_strict = strict;
    gfx_byte_clear_error();
    int arg_refs = args->refcount, source_refs = source->refcount;
    int frame_refs = frame ? frame->refcount : 0;
    ++gfx_byte_calls;
    Value *answer = ppu ? builtin_ppu_render_frame(args) : builtin_gfx_fb(args);

    gfx_byte_check(answer && answer->type == VAL_NULL, client, strict, c->name,
                   "builtin returns its null value");
    gfx_byte_check(!!g_has_error == c->reject, client, strict, c->name,
                   "stored payload is refused or accepted as declared");
    gfx_byte_check(!c->reject || g_error_kind == EK_VALUE, client, strict, c->name,
                   "refusal is value");
    unsigned flags = strict && c->strict_nan ? EIGS_MATH_INVALID : 0;
    gfx_byte_check(g_math_flags == flags, client, strict, c->name,
                   "only strict NaN sets INVALID, no overflow flag");
    const char *diagnostic = strict && c->strict_nan ? "not a number" : c->diagnostic;
    gfx_byte_check(diagnostic ? strstr(g_error_raw, diagnostic) != NULL
                              : g_error_raw[0] == 0,
                   client, strict, c->name,
                   "first NaN diagnostic wins before any later infinity");
    gfx_byte_check(args->refcount == arg_refs && source->refcount == source_refs
                   && (!frame || frame->refcount == frame_refs),
                   client, strict, c->name, "builtin borrows every buffer and argument");
    gfx_byte_check(gfx_byte_raw_bits(&source->data.buffer.data[first]) == first_bits
                   && gfx_byte_raw_bits(&source->data.buffer.data[later]) == later_bits,
                   client, strict, c->name, "read leaves stored raw payloads unchanged");
    if (ppu) {
        /* LCDC=255 is a valid byte. Zero VRAM/palettes produce shade zero;
         * a refused first register must leave the framebuffer untouched. */
        gfx_byte_check(gfx_byte_frame_is(frame, c->reject ? -17.0 : 0.0),
                       client, strict, c->name, "refusal preserves output; valid LCDC renders");
    } else {
        SDL_Rect pixel_rect = {0, 0, 1, 1};
        Uint32 pixel = 0;
        int rc = p_SDL_RenderReadPixels(g_renderer, &pixel_rect,
                                        MY_SDL_PIXELFORMAT_ARGB8888,
                                        &pixel, (int)sizeof pixel);
        Uint32 expected = c->reject ? UINT32_C(0x00FFFFFF) : 0;
        gfx_byte_check(rc == 0 && (pixel & UINT32_C(0x00FFFFFF)) == expected,
                       client, strict, c->name,
                       "refusal preserves real pixels; byte 255 selects black");
    }
    val_decref(answer);
    gfx_byte_clear_error();
}

int main(void) {
    EigsState *st = eigs_open();
    gfx_byte_check(st != NULL, "setup", 1, "state", "eigs_open");
    if (!st) goto summary;
    g_try_depth = 1;
    g_strict = 1;
    Value *pixels = NULL, *memory = NULL, *frame = NULL;
    Value *gfx_args = NULL, *ppu_args = NULL;
    gfx_byte_check(setenv("SDL_VIDEODRIVER", "dummy", 1) == 0,
                   "setup", 1, "SDL", "select real dummy video driver");
    Value *open_args = make_list_heap(3);
    list_append_owned(open_args, make_int(16));
    list_append_owned(open_args, make_int(16));
    list_append_owned(open_args, make_str("phase2 gfx byte boundary"));
    Value *opened = builtin_gfx_open(open_args);
    int ready = opened && opened->type == VAL_BOOL && opened->data.boolean
                && g_window && g_renderer && p_SDL_RenderReadPixels;
    gfx_byte_check(ready, "setup", 1, "SDL", "gfx_open creates a real 16x16 renderer");
    val_decref(opened);
    val_decref(open_args);
    if (!ready) goto cleanup;

    pixels = gfx_byte_stock_buffer(2, "gfx pixels");
    memory = gfx_byte_stock_buffer(65536, "GB memory");
    frame = gfx_byte_stock_buffer(23040, "GB framebuffer");
    gfx_byte_check(!g_has_error, "setup", 1, "buffers", "constructors are error-free");
    if (g_has_error || !pixels || pixels->type != VAL_BUFFER
        || !memory || memory->type != VAL_BUFFER || !frame || frame->type != VAL_BUFFER)
        goto cleanup;

    gfx_args = make_list_heap(6);
    list_append(gfx_args, pixels);
    list_append_owned(gfx_args, make_int(2));
    list_append_owned(gfx_args, make_int(1));
    list_append_owned(gfx_args, make_int(0));
    list_append_owned(gfx_args, make_int(0));
    list_append_owned(gfx_args, make_int(1));
    ppu_args = make_list_heap(2);
    list_append(ppu_args, memory);
    list_append(ppu_args, frame);
    for (int strict = 0; strict <= 1; ++strict) {
        for (unsigned i = 0; i < sizeof gfx_byte_cases / sizeof gfx_byte_cases[0]; ++i) {
            gfx_byte_exercise(0, strict, &gfx_byte_cases[i], gfx_args, pixels, NULL);
            gfx_byte_exercise(1, strict, &gfx_byte_cases[i], ppu_args, memory, frame);
        }
    }
    gfx_byte_check(gfx_byte_calls == 28, "population", 1, "both clients",
                   "all seven fixtures run through both clients in both strict modes");

cleanup:
    gfx_byte_clear_error();
    Value *closed = builtin_gfx_close(make_null());
    gfx_byte_check(closed && closed->type == VAL_NULL && !g_has_error
                   && !g_window && !g_renderer,
                   "cleanup", 1, "SDL", "gfx_close releases the real renderer");
    val_decref(closed);
    val_decref(gfx_args);
    val_decref(ppu_args);
    val_decref(pixels);
    val_decref(memory);
    val_decref(frame);
    gfx_byte_clear_error();
    g_try_depth = 0;
    eigs_close(st);
summary:
    printf("phase2-gfx-byte-test: %s checks=%d failures=%d\n",
           gfx_byte_failures ? "FAIL" : "PASS", gfx_byte_checks, gfx_byte_failures);
    return gfx_byte_failures ? 1 : 0;
}
