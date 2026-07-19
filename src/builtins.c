/*
 * EigenScript built-in functions.
 * Core language builtins plus the registration table.
 * Extension builtins (HTTP, DB, model) live in ext_*.c and model_*.c.
 */

#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "builtins_internal.h"
#include "trace.h"
#include <limits.h>

/* TRACE_NONDET_RET lives in trace.h — centralized in Phase 3 so the
 * replay short-circuit applies to every nondet builtin uniformly. */

#include <pthread.h>
#include <termios.h>

#if EIGENSCRIPT_EXT_HTTP
#include "ext_http_internal.h"
#endif

#if EIGENSCRIPT_EXT_DB
#include "ext_db_internal.h"
#endif

#if EIGENSCRIPT_EXT_MODEL
#include "model_internal.h"
#endif

/* Internal helpers defined in eigenscript.c. */
Value* make_num_permanent(double n);
const char* val_type_name(ValType t);
int dict_has(Value *dict, const char *key);
void dict_remove(Value *dict, const char *key);
extern int env_hash_find_dict(Value *dict, const char *key, uint32_t h);

Value* builtin_print(Value *arg) {
    char *s = value_to_string(arg);
    printf("%s\n", s);
    fflush(stdout);
    free(s);
    return make_null();
}

/* write of value — output without trailing newline */
Value* builtin_write(Value *arg) {
    char *s = value_to_string(arg);
    fputs(s, stdout);
    free(s);
    return make_null();
}

/* flush of null — flush stdout */
Value* builtin_flush(Value *arg) {
    (void)arg;
    fflush(stdout);
    return make_null();
}

/* raw_key of null — non-blocking single keypress read.
 * Returns the key as a string, or "" if no key pressed.
 * Sets terminal to raw mode on first call, restores on exit. */
static struct termios g_orig_termios;
static int g_raw_mode = 0;

#if !EIGENSCRIPT_FREESTANDING
static void restore_terminal(void) {
    if (g_raw_mode) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
        g_raw_mode = 0;
    }
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
static void enable_raw_mode(void) {
    if (g_raw_mode) return;
    tcgetattr(STDIN_FILENO, &g_orig_termios);
    atexit(restore_terminal);
    struct termios raw = g_orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON);
    raw.c_cc[VMIN] = 0;   /* non-blocking */
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    g_raw_mode = 1;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_raw_key(Value *arg) {
    (void)arg;
    enable_raw_mode();
    char buf[4] = {0};
    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
    if (n <= 0) return make_str("");
    buf[n] = '\0';
    /* Arrow keys come as ESC [ A/B/C/D */
    if (buf[0] == 27 && n >= 3 && buf[1] == '[') {
        switch (buf[2]) {
            case 'A': return make_str("up");
            case 'B': return make_str("down");
            case 'C': return make_str("right");
            case 'D': return make_str("left");
        }
    }
    return make_str(buf);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* usleep of microseconds — pause execution */
Value* builtin_usleep(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    int us = (int)arg->data.num;
    if (us > 0) usleep(us);
    return make_null();
}

/* screen_put of [row, col, char, color_code] — write a character at terminal position */
Value* builtin_screen_put(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    int row = (int)arg->data.list.items[0]->data.num;
    int col = (int)arg->data.list.items[1]->data.num;
    const char *ch = arg->data.list.items[2]->type == VAL_STR ? arg->data.list.items[2]->data.str : " ";
    int color = (arg->data.list.count >= 4 && arg->data.list.items[3]->type == VAL_NUM)
                ? (int)arg->data.list.items[3]->data.num : 0;
    if (color > 0)
        printf("\033[%d;%dH\033[%dm%s", row, col, color, ch);
    else
        printf("\033[%d;%dH%s", row, col, ch);
    return make_null();
}

/* screen_clear of null — clear terminal and hide cursor */
Value* builtin_screen_clear(Value *arg) {
    (void)arg;
    printf("\033[2J\033[H\033[?25l");
    fflush(stdout);
    return make_null();
}

/* screen_end of null — show cursor and reset */
Value* builtin_screen_end(Value *arg) {
    (void)arg;
    printf("\033[?25h\033[0m\n");
    fflush(stdout);
    return make_null();
}

/* screen_render of [entities_list, screen_w, screen_h, player_x, player_y, world_w, world_h]
 * entities_list: [[wx, wy, char, color], ...]
 * Clears screen, projects all entities, flushes once. All in C. */
Value* builtin_screen_render(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 7) return make_null();
    Value *entities = arg->data.list.items[0];
    int sw = (int)arg->data.list.items[1]->data.num;
    int sh = (int)arg->data.list.items[2]->data.num;
    double px = arg->data.list.items[3]->data.num;
    double py = arg->data.list.items[4]->data.num;
    double ww = arg->data.list.items[5]->data.num;
    double wh = arg->data.list.items[6]->data.num;

    if (!entities || entities->type != VAL_LIST) return make_null();
    if (sw <= 0 || sh <= 0 || sw > 10000 || sh > 10000) return make_null();

    double vw = sw * 0.5;
    double vh = sh * 0.5;
    double hvw = vw / 2.0;
    double hvh = vh / 2.0;

    /* Allocate screen buffer */
    size_t buf_size = (size_t)sw * (size_t)sh;
    char *chars = xcalloc_array(buf_size, 1);
    int *cols = xcalloc_array(buf_size, sizeof(int));
    memset(chars, ' ', buf_size);

    /* Project entities */
    for (int i = 0; i < entities->data.list.count; i++) {
        Value *ent = entities->data.list.items[i];
        if (!ent || ent->type != VAL_LIST || ent->data.list.count < 4) continue;
        double ex = ent->data.list.items[0]->data.num;
        double ey = ent->data.list.items[1]->data.num;
        const char *ch = ent->data.list.items[2]->type == VAL_STR ? ent->data.list.items[2]->data.str : " ";
        int color = (int)ent->data.list.items[3]->data.num;

        /* Torus delta */
        double dx = ex - px;
        double half_ww = ww * 0.5;
        if (dx > half_ww) dx -= ww;
        else if (dx < -half_ww) dx += ww;
        double dy = ey - py;
        double half_wh = wh * 0.5;
        if (dy > half_wh) dy -= wh;
        else if (dy < -half_wh) dy += wh;

        int col = (int)((dx + hvw) / vw * sw);
        int row = (int)((dy + hvh) / vh * sh);
        if (col >= 0 && col < sw && row >= 0 && row < sh) {
            int idx = row * sw + col;
            chars[idx] = ch[0];
            cols[idx] = color;
        }
    }

    /* Dump to terminal */
    printf("\033[H"); /* home */
    int prev_color = 0;
    for (int row = 0; row < sh; row++) {
        for (int col = 0; col < sw; col++) {
            int idx = row * sw + col;
            int c = cols[idx];
            if (c != prev_color) {
                if (c > 0) printf("\033[%dm", c);
                else printf("\033[0m");
                prev_color = c;
            }
            putchar(chars[idx]);
        }
        putchar('\n');
    }
    printf("\033[0m");
    fflush(stdout);

    free(chars);
    free(cols);
    return make_null();
}

/* join of [list, separator] — concatenate list elements into a string.
 * C-backed for performance — single allocation instead of O(n²) concat. */
Value* builtin_join(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    Value *list = arg->data.list.items[0];
    Value *sep_val = arg->data.list.items[1];
    if (!list || list->type != VAL_LIST) return make_str("");
    const char *sep = (sep_val && sep_val->type == VAL_STR) ? sep_val->data.str : "";
    size_t sep_len = strlen(sep);

    /* First pass: compute total length */
    int count = list->data.list.count;
    if (count == 0) return make_str("");

    char **parts = xmalloc_array(count, sizeof(char*));
    size_t *lengths = xmalloc_array(count, sizeof(size_t));
    size_t total = 0;
    for (int i = 0; i < count; i++) {
        parts[i] = value_to_string(list->data.list.items[i]);
        lengths[i] = strlen(parts[i]);
        total += lengths[i];
        if (i > 0) total += sep_len;
    }

    /* Single allocation */
    char *result = xmalloc(total + 1);
    int pos = 0;
    for (int i = 0; i < count; i++) {
        if (i > 0 && sep_len > 0) {
            memcpy(result + pos, sep, sep_len);
            pos += sep_len;
        }
        memcpy(result + pos, parts[i], lengths[i]);
        pos += lengths[i];
        free(parts[i]);
    }
    result[pos] = '\0';
    free(parts);
    free(lengths);

    Value *v = make_str(result);
    free(result);
    return v;
}

static void text_builder_reserve(Value *builder, size_t extra) {
    size_t need = builder->data.text_builder.len + extra + 1;
    if (need <= builder->data.text_builder.cap) return;
    size_t cap = builder->data.text_builder.cap ? builder->data.text_builder.cap : 256;
    while (cap < need) {
        if (cap > ((size_t)-1) / 2) {
            cap = need;
            break;
        }
        cap *= 2;
    }
    builder->data.text_builder.data = xrealloc(builder->data.text_builder.data, cap);
    builder->data.text_builder.cap = cap;
}

static void text_builder_append_raw(Value *builder, const char *s, int count_part) {
    if (!builder || builder->type != VAL_TEXT_BUILDER || !s) return;
    size_t n = strlen(s);
    text_builder_reserve(builder, n);
    memcpy(builder->data.text_builder.data + builder->data.text_builder.len, s, n);
    builder->data.text_builder.len += n;
    builder->data.text_builder.data[builder->data.text_builder.len] = '\0';
    if (count_part) builder->data.text_builder.parts += 1;
}

static void text_builder_append_value(Value *builder, Value *value) {
    if (!builder || builder->type != VAL_TEXT_BUILDER) return;
    if (value && value->type == VAL_STR) {
        text_builder_append_raw(builder, value->data.str, 1);
        return;
    }
    if (value && value->type == VAL_TEXT_BUILDER) {
        text_builder_append_raw(builder, value->data.text_builder.data, 1);
        return;
    }
    char *s = value_to_string(value);
    text_builder_append_raw(builder, s, 1);
    free(s);
}

Value* builtin_text_builder_new(Value *arg) {
    (void)arg;
    return make_text_builder();
}

Value* builtin_text_builder_append(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *builder = arg->data.list.items[0];
    if (!builder || builder->type != VAL_TEXT_BUILDER) return make_null();
    text_builder_append_value(builder, arg->data.list.items[1]);
    return builder;
}

Value* builtin_text_builder_append_line(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *builder = arg->data.list.items[0];
    if (!builder || builder->type != VAL_TEXT_BUILDER) return make_null();
    text_builder_append_value(builder, arg->data.list.items[1]);
    text_builder_append_raw(builder, "\n", 1);
    return builder;
}

Value* builtin_text_builder_extend(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *builder = arg->data.list.items[0];
    Value *values = arg->data.list.items[1];
    if (!builder || builder->type != VAL_TEXT_BUILDER || !values || values->type != VAL_LIST) return make_null();
    for (int i = 0; i < values->data.list.count; i++)
        text_builder_append_value(builder, values->data.list.items[i]);
    return builder;
}

Value* builtin_text_builder_part_count(Value *arg) {
    if (!arg || arg->type != VAL_TEXT_BUILDER) return make_num(0);
    return make_num(arg->data.text_builder.parts);
}

Value* builtin_text_builder_clear(Value *arg) {
    if (!arg || arg->type != VAL_TEXT_BUILDER) return make_null();
    arg->data.text_builder.len = 0;
    arg->data.text_builder.parts = 0;
    if (arg->data.text_builder.data) arg->data.text_builder.data[0] = '\0';
    return arg;
}

Value* builtin_text_builder_to_string(Value *arg) {
    if (!arg || arg->type != VAL_TEXT_BUILDER) return make_str("");
    return make_str(arg->data.text_builder.data ? arg->data.text_builder.data : "");
}

/* ==== Bitwise operations ====
 * Semantics: operate on 32-bit two's-complement ints. Shift amounts are
 * masked to [0,31] so large/negative shifts are defined behavior, not UB.
 * Non-numeric args raise a runtime error (consistent with the strict error
 * model used by the arithmetic operators and the '& | ^ << >> ~' operators). */

/* The bit_* builtins are the SAME operation as the infix operators
 * (& | ^ << >>): int64 two's-complement over the numeric value (vm.c's
 * INT_BINOP). They used to be a second, divergent implementation —
 * (uint32_t)(int32_t) conversion, UB for inputs >= 2^31 and
 * sign-extended results — so `0xEDB88320 & x` worked while
 * `bit_and of [0xEDB88320, x]` returned garbage (found by the CRC-32
 * stdlib module, the first consumer needing the full unsigned-32
 * range). Shift counts are masked to 0..63 like the hardware would. */
static int bit_pair(Value *arg, int64_t *a_out, int64_t *b_out) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return 0;
    Value *va = arg->data.list.items[0];
    Value *vb = arg->data.list.items[1];
    if (!va || va->type != VAL_NUM || !vb || vb->type != VAL_NUM) return 0;
    *a_out = (int64_t)va->data.num;
    *b_out = (int64_t)vb->data.num;
    return 1;
}

Value* builtin_bit_and(Value *arg) {
    int64_t a, b;
    if (!bit_pair(arg, &a, &b)) { rt_error(EK_TYPE, 0, "bit_and expects [number, number]"); return make_null(); }
    return make_num((double)(a & b));
}

Value* builtin_bit_or(Value *arg) {
    int64_t a, b;
    if (!bit_pair(arg, &a, &b)) { rt_error(EK_TYPE, 0, "bit_or expects [number, number]"); return make_null(); }
    return make_num((double)(a | b));
}

Value* builtin_bit_xor(Value *arg) {
    int64_t a, b;
    if (!bit_pair(arg, &a, &b)) { rt_error(EK_TYPE, 0, "bit_xor expects [number, number]"); return make_null(); }
    return make_num((double)(a ^ b));
}

Value* builtin_bit_not(Value *arg) {
    if (!arg || arg->type != VAL_NUM) { rt_error(EK_TYPE, 0, "bit_not expects a number"); return make_null(); }
    int64_t a = (int64_t)arg->data.num;
    return make_num((double)(~a));
}

Value* builtin_bit_shift_left(Value *arg) {
    int64_t a, b;
    if (!bit_pair(arg, &a, &b)) { rt_error(EK_TYPE, 0, "bit_shl expects [number, number]"); return make_null(); }
    return make_num((double)(a << (b & 63)));
}

Value* builtin_bit_shift_right(Value *arg) {
    int64_t a, b;
    if (!bit_pair(arg, &a, &b)) { rt_error(EK_TYPE, 0, "bit_shr expects [number, number]"); return make_null(); }
    /* Arithmetic shift, like the infix >> on int64 (negative operands
     * keep their sign); mask a non-negative operand first for a
     * logical u32 shift. */
    return make_num((double)(a >> (b & 63)));
}

/* monotonic_ns of null — nanoseconds from CLOCK_MONOTONIC */
Value* builtin_monotonic_ns(Value *arg) {
    (void)arg;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    TRACE_NONDET_RET("monotonic_ns", make_num((double)ts.tv_sec * 1e9 + (double)ts.tv_nsec));
}

/* monotonic_ms of null — milliseconds from CLOCK_MONOTONIC */
Value* builtin_monotonic_ms(Value *arg) {
    (void)arg;
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    TRACE_NONDET_RET("monotonic_ms", make_num((double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6));
}

Value* builtin_len(Value *arg) {
    if (arg->type == VAL_LIST)
        return make_num(arg->data.list.count);
    if (arg->type == VAL_STR)
        return make_num(strlen(arg->data.str));
    if (arg->type == VAL_DICT)
        return make_num(arg->data.dict.count);
    if (arg->type == VAL_BUFFER)
        return make_num(arg->data.buffer.count);
    if (arg->type == VAL_TEXT_BUILDER)
        return make_num((double)arg->data.text_builder.len);
    /* #508: a type with no length (number, fn, null, …) used to fold to 0,
     * silently masking a wrong value. Raise. Callers that legitimately mean
     * "empty if absent" already guard with `x != null and len of x` — and
     * `and` short-circuits, so the guarded len is never reached. */
    rt_error(EK_TYPE, 0, "len: %s has no length",
             arg ? val_type_name(arg->type) : "null");
    return make_num(0);
}

Value* builtin_str(Value *arg) {
    char *s = value_to_string(arg);
    Value *v = make_str(s);
    free(s);
    return v;
}

Value* builtin_num(Value *arg) {
    if (!arg) return make_num(0);
    if (arg->type == VAL_NUM) return arg;
    if (arg->type == VAL_STR) {
        /* Hex strings are converted HERE, never by strtod — same contract
         * as the lexer (#378/#381): glibc's strtod reads hex floats
         * ("0x.8" -> 0.5, "0x1p4" -> 16) while the freestanding
         * mini_strtod reads 0, a silent profile divergence through the
         * string path. Hex is integer-only; conversion stops at the
         * first non-hex-digit (matching strtod's partial-parse shape,
         * "12abc" -> 12); a prefix with no hex digit converts to 0
         * like any other non-numeric string. */
        const char *p = arg->data.str;
        while (*p == ' ' || *p == '\t') p++;
        int neg = 0;
        if (*p == '+' || *p == '-') { neg = (*p == '-'); p++; }
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
            if (!isxdigit((unsigned char)p[2])) return make_num(0);
            double v = 0;
            p += 2;
            while (isxdigit((unsigned char)*p)) {
                int d = *p <= '9' ? *p - '0' : (*p | 32) - 'a' + 10;
                v = v * 16 + d;
                p++;
            }
            return make_num(neg ? -v : v);
        }
        return make_num(strtod(arg->data.str, NULL));
    }
    if (arg->type == VAL_NULL) return make_num(0);
    return make_num(0);
}

Value* builtin_append(Value *arg) {
    /* #506: append requires exactly a [list, item] pair. Fewer than two
     * elements (or a non-list arg-vector) was a silent no-op returning the
     * target unchanged. NB a bare list is the builtin's arg-vector (#405),
     * so `append of xs` with xs=[a,b] arrives here as target=a, item=b — if
     * a isn't a list this now raises instead of silently doing nothing. Pass
     * a literal list whole with the paren form: `append of ([ys, item])`. */
    if (arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "append requires [list, item]");
        return make_null();
    }
    Value *target = arg->data.list.items[0];
    Value *item = arg->data.list.items[1];
    if (target->type != VAL_LIST) {
        rt_error(EK_TYPE, 0, "append: target must be a list (got %s)",
                 val_type_name(target->type));
        return make_null();
    }
    list_append(target, item);
    return target;
}


Value* builtin_report(Value *arg) {
    /* #262 Step E: observer trajectories live on the Env slot, never on the
     * Value. `report of <ident>` is a slot-keyed special form (REPORT_SLOT/
     * REPORT_NAME); this builtin is reached only for a value-based operand with
     * no binding (a computed expr, or an unobserved param), which has no
     * trajectory → the no-observation band, "equilibrium". */
    (void)arg;
    return make_str("equilibrium");
}

/* Set observer classification thresholds.
 * Usage: set_observer_thresholds of [dh_zero, dh_small, h_low]
 *   dh_zero:  |dH| below this is "essentially zero change"  (default 0.001)
 *   dh_small: |dH| below this is "small but nonzero change"  (default 0.01)
 *   h_low:    entropy below this is "low information content" (default 0.1)
 *
 * WARNING: Changing these affects ALL observer predicates (converged, stable,
 * improving, oscillating, diverging, equilibrium) and the report builtin.
 * The defaults are precisely tuned. Only adjust for studying slow convergence
 * or when working with values whose entropy changes are unusually small. */
Value* builtin_set_observer_thresholds(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "set_observer_thresholds requires [dh_zero, dh_small, h_low]");
        return make_null();
    }
    double dh_zero  = arg->data.list.items[0]->data.num;
    double dh_small = arg->data.list.items[1]->data.num;
    double h_low    = arg->data.list.items[2]->data.num;
    if (dh_zero <= 0 || dh_small <= 0 || h_low <= 0) {
        rt_error(EK_VALUE, 0, "observer thresholds must be positive");
        return make_null();
    }
    if (dh_zero >= dh_small) {
        rt_error(EK_VALUE, 0, "dh_zero must be less than dh_small");
        return make_null();
    }
    fprintf(stderr, "Warning: observer thresholds changed — dh_zero=%.6f dh_small=%.6f h_low=%.6f\n",
            dh_zero, dh_small, h_low);
    g_obs_dh_zero  = dh_zero;
    g_obs_dh_small = dh_small;
    g_obs_h_low    = h_low;
    return make_null();
}

/* Get current observer thresholds.
 * Returns [dh_zero, dh_small, h_low]. */
Value* builtin_get_observer_thresholds(Value *arg) {
    (void)arg;
    Value *result = make_list(3);
    list_append_owned(result, make_num(g_obs_dh_zero));
    list_append_owned(result, make_num(g_obs_dh_small));
    list_append_owned(result, make_num(g_obs_h_low));
    return result;
}

/* Process-global exit request (declared in eigenscript.h). */
int g_exit_requested = 0;
int g_exit_code = 0;

/* exit of N — request a clean process exit with code N (default 0). Sets the
 * unwind flag (g_has_error) so vm_run returns to main, plus g_exit_requested so
 * the unwind is UNCATCHABLE (a `try` must not swallow `exit`) and main exits
 * with the code after its normal teardown — leak-clean, unlike a raw exit(). */
Value* builtin_exit(Value *arg) {
    int code = 0;
    if (arg && arg->type == VAL_NUM) {
        code = (int)arg->data.num;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1 &&
               arg->data.list.items[0] &&
               arg->data.list.items[0]->type == VAL_NUM) {
        code = (int)arg->data.list.items[0]->data.num;
    }
    g_exit_code = code;
    g_exit_requested = 1;
    g_has_error = 1;   /* triggers CHECK_ERROR -> unwind to main */
    return make_null();
}

Value* builtin_assert(Value *arg) {
    /* Failure path raises a normal runtime error (g_has_error + g_error_msg)
     * rather than exit(1); that lets vm_run unwind to main, which runs the
     * standard teardown (env_decref, gc_collect_at_exit, chunk_free). Direct
     * exit leaked the global env and every registered builtin. Side effect:
     * assert failures are now catchable in `try`/`catch`, matching `throw`. */
    if (arg->type == VAL_LIST && arg->data.list.count >= 2) {
        Value *cond = arg->data.list.items[0];
        Value *msg = arg->data.list.items[1];
        if (!is_truthy(cond)) {
            char *msg_str = value_to_string(msg);
            rt_error(EK_ASSERT, 0, "ASSERT FAIL: %s", msg_str);
            free(msg_str);
        }
        return make_null();
    }
    if (!is_truthy(arg)) {
        rt_error(EK_ASSERT, 0, "ASSERT FAIL");
    }
    return make_null();
}

Value* builtin_throw(Value *arg) {
    /* g_error_msg always carries the stringified form (uncaught
     * printing, traces); g_error_value preserves the thrown value
     * itself so `catch e` binds a dict/list/string/... unchanged —
     * user throws do NOT get the #406 {kind, message, line} wrapping.
     * Kind/line are still stamped for host/embed introspection. */
    char *msg = value_to_string(arg);
    snprintf(g_error_msg, sizeof(g_error_msg), "%s", msg);
    snprintf(g_error_raw, sizeof(g_error_raw), "%s", msg);
    g_error_kind = (int)EK_USER;
    g_error_line = vm_current_line();
    g_has_error = 1;
    eigs_clear_error_value();
    if (arg) {
        val_incref(arg);
        g_error_value = arg;
    }
    if (g_try_depth == 0) {
        /* #407 residual: defer to CHECK_ERROR for the caret excerpt when
         * the VM is live — mirrors rt_error. */
        if (eigs_current && eigs_current->vm && g_vm.frame_count > 0) {
            g_error_print_pending = 1;
        } else {
            fprintf(stderr, "%s\n", g_error_msg);
            vm_print_stack_trace(stderr);
        }
    }
    free(msg);
    return make_null();
}

/* ==== Dict builtins ==== */

Value* builtin_keys(Value *arg) {
    if (arg->type == VAL_DICT) {
        Value *list = make_list(arg->data.dict.count);
        for (int i = 0; i < arg->data.dict.count; i++)
            list_append_owned(list, make_str(arg->data.dict.keys[i]));
        return list;
    }
    return make_list(0);
}

Value* builtin_values(Value *arg) {
    if (arg->type == VAL_DICT) {
        Value *list = make_list(arg->data.dict.count);
        for (int i = 0; i < arg->data.dict.count; i++)
            list_append(list, arg->data.dict.vals[i]);
        return list;
    }
    return make_list(0);
}

Value* builtin_has_key(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    if (d->type != VAL_DICT || key->type != VAL_STR) return make_num(0);
    return make_num(dict_has(d, key->data.str) ? 1 : 0);
}

Value* builtin_dict_set(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    Value *val = arg->data.list.items[2];
    if (d->type != VAL_DICT || key->type != VAL_STR) return make_null();
    dict_set(d, key->data.str, val);
    return d;
}

Value* builtin_dict_remove(Value *arg) {
    if (arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    if (d->type != VAL_DICT || key->type != VAL_STR) return make_null();
    dict_remove(d, key->data.str);
    return d;
}

Value* builtin_observe(Value *arg) {
    /* #262 Step E: value-based fallback for `observe of <expr>` — no binding,
     * no trajectory. `observe of <ident>` is the slot-keyed special form
     * (OP_OBSERVE_VALUE_SLOT/NAME). Returns the no-observation tuple. */
    (void)arg;
    Value *list = make_list(4);
    list_append_owned(list, make_str("equilibrium"));
    list_append_owned(list, make_num(0.0));
    list_append_owned(list, make_num(0.0));
    list_append_owned(list, make_num(0.0));
    return list;
}

Value* builtin_classify(Value *arg) {
    /* #421 `classify of t` — classify a trajectory SNAPSHOT (the dict
     * `trajectory of x` builds), so a callee can classify what its CALLER
     * observed: the snapshot crosses the call boundary; the binding slot
     * cannot. One arg → the #294 value-channel label (same classifier as
     * `report_value of x`, including the #422 raw-step signals). Two args
     * `classify of [t, "entropy"]` → the entropy-channel label (same as
     * `report of x`). A non-trajectory argument is a loud EK_TYPE error —
     * classifying an arbitrary value would silently mean "no trajectory". */
    Value *t = arg;
    const char *channel = "value";
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        t = arg->data.list.items[0];
        if (arg->data.list.count >= 2) {
            Value *ch = arg->data.list.items[1];
            if (!ch || ch->type != VAL_STR ||
                (strcmp(ch->data.str, "value") != 0 &&
                 strcmp(ch->data.str, "entropy") != 0)) {
                rt_error(EK_VALUE, 0,
                         "classify: channel must be \"value\" or \"entropy\"");
                return make_null();
            }
            channel = ch->data.str;
        }
    }
    ObserverSlot s;
    if (!observer_slot_from_trajectory(&s, t)) {
        rt_error(EK_TYPE, 0, "classify: expected a trajectory snapshot "
                 "(from `trajectory of x`), got %s",
                 t ? val_type_name(t->type) : "none");
        return make_null();
    }
    const char *label = (strcmp(channel, "entropy") == 0)
                        ? observer_slot_report(&s)
                        : observer_slot_report_value(&s);
    Value *out = make_str(label ? label : "equilibrium");
    free(s.dh_window);
    free(s.v_window);
    free(s.vr_window);
    return out;
}

Value* builtin_type(Value *arg) {
    if (!arg) return make_str("none");
    switch (arg->type) {
        case VAL_NUM: return make_str("num");
        case VAL_STR: return make_str("str");
        case VAL_LIST: return make_str("list");
        case VAL_FN: return make_str("fn");
        case VAL_BUILTIN: return make_str("builtin");
        case VAL_NULL: return make_str("none");
        case VAL_JSON_RAW: return make_str("json_raw");
        case VAL_DICT: return make_str("dict");
        case VAL_BUFFER: return make_str("buffer");
        case VAL_TEXT_BUILDER: return make_str("text_builder");
    }
    return make_str("none");
}

static void eigs_json_encode_value(Value *v, strbuf *out) {
    if (!v || v->type == VAL_NULL || v->type == VAL_FN || v->type == VAL_BUILTIN) {
        strbuf_append(out, "null");
        return;
    }
    switch (v->type) {
        case VAL_NUM: {
            double n = v->data.num;
            if (n == (int)n && fabs(n) < 1e15)
                strbuf_append_fmt(out, "%d", (int)n);
            else
                strbuf_append_fmt(out, "%.15g", n);
            break;
        }
        case VAL_STR: {
            strbuf_append_char(out, '"');
            for (const char *c = v->data.str; *c; c++) {
                switch (*c) {
                    case '"': strbuf_append_n(out, "\\\"", 2); break;
                    case '\\': strbuf_append_n(out, "\\\\", 2); break;
                    case '\n': strbuf_append_n(out, "\\n", 2); break;
                    case '\r': strbuf_append_n(out, "\\r", 2); break;
                    case '\t': strbuf_append_n(out, "\\t", 2); break;
                    default:
                        if ((unsigned char)*c < 0x20)
                            strbuf_append_fmt(out, "\\u%04x", (unsigned char)*c);
                        else
                            strbuf_append_char(out, *c);
                        break;
                }
            }
            strbuf_append_char(out, '"');
            break;
        }
        case VAL_TEXT_BUILDER: {
            eigs_json_escape_string(out, v->data.text_builder.data ? v->data.text_builder.data : "");
            break;
        }
        case VAL_LIST: {
            strbuf_append_char(out, '[');
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) strbuf_append_char(out, ',');
                eigs_json_encode_value(v->data.list.items[i], out);
            }
            strbuf_append_char(out, ']');
            break;
        }
        case VAL_DICT: {
            strbuf_append_char(out, '{');
            for (int i = 0; i < v->data.dict.count; i++) {
                if (i > 0) strbuf_append_char(out, ',');
                strbuf_append_char(out, '"');
                for (const char *c = v->data.dict.keys[i]; *c; c++) {
                    switch (*c) {
                        case '"': strbuf_append_n(out, "\\\"", 2); break;
                        case '\\': strbuf_append_n(out, "\\\\", 2); break;
                        case '\n': strbuf_append_n(out, "\\n", 2); break;
                        case '\r': strbuf_append_n(out, "\\r", 2); break;
                        case '\t': strbuf_append_n(out, "\\t", 2); break;
                        default:
                            if ((unsigned char)*c < 0x20)
                                strbuf_append_fmt(out, "\\u%04x", (unsigned char)*c);
                            else
                                strbuf_append_char(out, *c);
                            break;
                    }
                }
                strbuf_append_char(out, '"');
                strbuf_append_char(out, ':');
                eigs_json_encode_value(v->data.dict.vals[i], out);
            }
            strbuf_append_char(out, '}');
            break;
        }
        default:
            strbuf_append(out, "null");
            break;
    }
}

Value* builtin_json_encode(Value *arg) {
    strbuf out;
    strbuf_init(&out);
    eigs_json_encode_value(arg, &out);
    Value *result = make_str(out.data);
    strbuf_free(&out);
    return result;
}

char* eigs_json_encode(Value *v) {
    strbuf out;
    strbuf_init(&out);
    eigs_json_encode_value(v, &out);
    char *result = xstrdup(out.data);
    strbuf_free(&out);
    return result;
}

Value* eigs_json_parse_value(const char *s, int *pos);

/* #495: strict-parse error flag. The recursive-descent parser has no error
 * channel (it returns a Value* and, historically, a partial container on
 * malformed input). This thread-local flag is SET by the parse functions on
 * any malformed condition (unexpected token, truncation, unterminated
 * string, over-deep nesting) and CHECKED only by builtin_json_decode, which
 * resets it on entry and raises. Other callers (json_path, ext_http) ignore
 * it and keep the historical lenient behavior. Thread-local like g_json_depth
 * because JSON parsing is per-thread and non-reentrant across threads. */
static __thread int g_json_parse_err = 0;

static void eigs_json_skip_ws(const char *s, int *pos) {
    while (s[*pos] && (s[*pos] == ' ' || s[*pos] == '\t' || s[*pos] == '\n' || s[*pos] == '\r'))
        (*pos)++;
}

static Value* eigs_json_parse_string(const char *s, int *pos) {
    if (s[*pos] != '"') { g_json_parse_err = 1; return NULL; }   /* #495 */
    (*pos)++;
    strbuf buf;
    strbuf_init(&buf);
    while (s[*pos] && s[*pos] != '"') {
        if (s[*pos] == '\\') {
            (*pos)++;
            switch (s[*pos]) {
                case '"': strbuf_append_char(&buf, '"'); break;
                case '\\': strbuf_append_char(&buf, '\\'); break;
                case 'n': strbuf_append_char(&buf, '\n'); break;
                case 'r': strbuf_append_char(&buf, '\r'); break;
                case 't': strbuf_append_char(&buf, '\t'); break;
                case '/': strbuf_append_char(&buf, '/'); break;
                case 'u': {
                    char hex[5] = {0};
                    for (int hi = 0; hi < 4; hi++) {
                        (*pos)++;
                        if (!s[*pos]) break;
                        hex[hi] = s[*pos];
                    }
                    unsigned int cp = (unsigned int)strtoul(hex, NULL, 16);
                    if (cp < 0x80) {
                        strbuf_append_char(&buf, (char)cp);
                    } else if (cp < 0x800) {
                        strbuf_append_char(&buf, (char)(0xC0 | (cp >> 6)));
                        strbuf_append_char(&buf, (char)(0x80 | (cp & 0x3F)));
                    } else {
                        strbuf_append_char(&buf, (char)(0xE0 | (cp >> 12)));
                        strbuf_append_char(&buf, (char)(0x80 | ((cp >> 6) & 0x3F)));
                        strbuf_append_char(&buf, (char)(0x80 | (cp & 0x3F)));
                    }
                    break;
                }
                default: strbuf_append_char(&buf, s[*pos]); break;
            }
        } else {
            strbuf_append_char(&buf, s[*pos]);
        }
        (*pos)++;
    }
    if (s[*pos] == '"') (*pos)++;
    else g_json_parse_err = 1;   /* #495: unterminated string (hit EOF) */
    Value *v = make_str(buf.data);
    strbuf_free(&buf);
    return v;
}

/* #557: RFC 8259 §6 number grammar — [ minus ] int [ frac ] [ exp ].
 * The old scanner accepted 'e'/'E'/'+' but never the '-' of a negative
 * exponent, so any mainstream producer's scientific notation (Python
 * json.dumps, JS JSON.stringify, serde: "1e-06") failed at the sign —
 * including json_encode's OWN %.15g output for tiny/huge magnitudes.
 * The grammar is scanned exactly; a malformed tail ("1e", "1e+", "1.")
 * sets g_json_parse_err instead of letting atof()/strtod() guess silently.
 * (Deliberately lax vs RFC in one spot: leading zeros ("01") stay
 * accepted, matching the old scanner.)
 *
 * #628: the scanner records the token span [start, p) and hands it straight
 * to strtod for the correctly-rounded double at any length. The previous
 * fixed 63-char numbuf silently DROPPED the tail of long tokens (a padded
 * "1.<60 zeros>e50" decoded to 1, a 70-digit integer to 1e62) while the scan
 * still advanced *pos correctly — so json_decode returned a valid-looking
 * number of the wrong magnitude with rc=0. strtod over the span has no cap.
 * The scanner validated a *decimal* JSON number, so strtod cannot "guess";
 * we still verify strtod's endptr landed exactly on the scanned end. The one
 * way strtod can disagree is a C99 hex-float prefix ("0x1p0"): strtod reads
 * "0x…" as hex, but JSON has no hex numbers so the scanner stops at 'x'. On
 * that (or any) endptr mismatch we re-parse the isolated token, keeping the
 * value tied to the grammar the scanner accepted. `s` is always a
 * NUL-terminated C string (the scanner's own `while (s[p])` loops rely on
 * it), so strtod(s + start) reads within bounds. */
static Value* eigs_json_parse_number(const char *s, int *pos) {
    int start = *pos;
    int p = start;
    if (s[p] == '-') p++;
    if (!isdigit((unsigned char)s[p])) {
        g_json_parse_err = 1; *pos = p; return make_num(0);
    }
    while (isdigit((unsigned char)s[p])) p++;
    if (s[p] == '.') {
        p++;
        if (!isdigit((unsigned char)s[p])) {   /* "1." — frac needs digits */
            g_json_parse_err = 1; *pos = p; return make_num(0);
        }
        while (isdigit((unsigned char)s[p])) p++;
    }
    if (s[p] == 'e' || s[p] == 'E') {
        p++;
        if (s[p] == '+' || s[p] == '-') p++;
        if (!isdigit((unsigned char)s[p])) {   /* "1e", "1e+" — exp needs digits */
            g_json_parse_err = 1; *pos = p; return make_num(0);
        }
        while (isdigit((unsigned char)s[p])) p++;
    }
    char *endp;
    double d = strtod(s + start, &endp);
    if (endp != s + p) {
        /* strtod ran past (or short of) the scanned decimal token — only
         * reachable via a C99 hex-float "0x" prefix, which the JSON scanner
         * stops before. Re-parse just the scanned span so the value matches
         * the grammar the scanner accepted. */
        int n = p - start;
        char *iso = xmalloc((size_t)n + 1);
        memcpy(iso, s + start, (size_t)n);
        iso[n] = '\0';
        d = strtod(iso, NULL);
        free(iso);
    }
    *pos = p;
    return make_num(d);
}

/* Bound JSON nesting depth: each array/object descent is a C recursion, so
 * untrusted input like "[[[[...]]]]" would otherwise exhaust the C stack and
 * crash (SIGSEGV). 200 is far beyond any legitimate document. */
#define JSON_MAX_DEPTH 200
/* g_json_depth lives on EigsThread (Phase 8); bridge macro from eigenscript.h. */

static Value* eigs_json_parse_array(const char *s, int *pos) {
    (*pos)++;
    Value *list = make_list(8);
    eigs_json_skip_ws(s, pos);
    if (s[*pos] == ']') { (*pos)++; return list; }
    while (s[*pos]) {
        eigs_json_skip_ws(s, pos);
        Value *val = eigs_json_parse_value(s, pos);
        if (val) list_append_owned(list, val);
        if (g_json_parse_err) return list;         /* #495: propagate */
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == ']') { (*pos)++; return list; }
        g_json_parse_err = 1;    /* #495: expected ',' or ']' */
        return list;
    }
    g_json_parse_err = 1;        /* #495: hit EOF before ']' (truncated) */
    return list;
}

static Value* eigs_json_parse_object(const char *s, int *pos) {
    (*pos)++;
    Value *dict = make_dict(8);
    eigs_json_skip_ws(s, pos);
    if (s[*pos] == '}') { (*pos)++; return dict; }
    while (s[*pos]) {
        eigs_json_skip_ws(s, pos);
        Value *key = eigs_json_parse_string(s, pos);
        if (!key || g_json_parse_err) {           /* #495: bad/absent key */
            if (key) val_decref(key);
            g_json_parse_err = 1;
            return dict;
        }
        eigs_json_skip_ws(s, pos);
        if (s[*pos] != ':') {                      /* #495: missing colon */
            val_decref(key);
            g_json_parse_err = 1;
            return dict;
        }
        (*pos)++;
        eigs_json_skip_ws(s, pos);
        Value *val = eigs_json_parse_value(s, pos);
        dict_set_owned(dict, key->data.str, val ? val : make_null());
        val_decref(key);   /* dict interns its own copy of the key */
        if (g_json_parse_err) return dict;         /* #495: propagate */
        eigs_json_skip_ws(s, pos);
        if (s[*pos] == ',') { (*pos)++; continue; }
        if (s[*pos] == '}') { (*pos)++; return dict; }
        g_json_parse_err = 1;    /* #495: expected ',' or '}' */
        return dict;
    }
    g_json_parse_err = 1;        /* #495: hit EOF before '}' (truncated) */
    return dict;
}

Value* eigs_json_parse_value(const char *s, int *pos) {
    eigs_json_skip_ws(s, pos);
    if (!s[*pos]) { g_json_parse_err = 1; return make_null(); }  /* #495: value expected, hit EOF */
    if (s[*pos] == '"') return eigs_json_parse_string(s, pos);
    /* Refuse to descend past the nesting limit (stack-exhaustion guard).
     * The enclosing array/object loop breaks on the unconsumed bracket, so
     * parsing terminates cleanly instead of crashing. */
    if (s[*pos] == '[') {
        if (g_json_depth >= JSON_MAX_DEPTH) { g_json_parse_err = 1; return make_null(); }
        g_json_depth++;
        Value *v = eigs_json_parse_array(s, pos);
        g_json_depth--;
        return v;
    }
    if (s[*pos] == '{') {
        if (g_json_depth >= JSON_MAX_DEPTH) { g_json_parse_err = 1; return make_null(); }
        g_json_depth++;
        Value *v = eigs_json_parse_object(s, pos);
        g_json_depth--;
        return v;
    }
    if (s[*pos] == '-' || isdigit(s[*pos])) return eigs_json_parse_number(s, pos);
    if (strncmp(s + *pos, "null", 4) == 0) { *pos += 4; return make_null(); }
    if (strncmp(s + *pos, "true", 4) == 0) { *pos += 4; return make_num(1); }
    if (strncmp(s + *pos, "false", 5) == 0) { *pos += 5; return make_num(0); }
    g_json_parse_err = 1;   /* #495: unrecognized token */
    return make_null();
}

Value* builtin_json_decode(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "json_decode requires a string, got %s",
                arg ? val_type_name(arg->type) : "null");
        return make_null();
    }
    /* #495: strict decode. Reset the parse-error flag, parse one value, then
     * require that only whitespace remains. A partial container, a truncated
     * document, an unterminated string, over-deep nesting, or trailing
     * garbage after a complete value now raises instead of silently
     * succeeding (which also made a genuine JSON `null` indistinguishable
     * from a parse failure). */
    g_json_parse_err = 0;
    int pos = 0;
    Value *v = eigs_json_parse_value(arg->data.str, &pos);
    eigs_json_skip_ws(arg->data.str, &pos);
    if (g_json_parse_err || arg->data.str[pos] != '\0') {
        if (v) val_decref(v);
        rt_error(EK_VALUE, 0, "json_decode: invalid JSON at position %d", pos);
        return make_null();
    }
    return v;
}

Value* builtin_coalesce(Value *arg) {
    /* coalesce of [value, default] — returns value unless empty/null */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return arg ? arg : make_null();
    Value *val = arg->data.list.items[0];
    Value *def = arg->data.list.items[1];
    if (!val || val->type == VAL_NULL) return def;
    if (val->type == VAL_STR && val->data.str[0] == '\0') return def;
    return val;
}

/* Escape a string for safe embedding in JSON (keys and values).
 * Shared across builtins.c, eigenscript.c, ext_store.c. */
void eigs_json_escape_string(strbuf *out, const char *s) {
    strbuf_append_char(out, '"');
    for (const char *c = s; *c; c++) {
        switch (*c) {
            case '"':  strbuf_append_n(out, "\\\"", 2); break;
            case '\\': strbuf_append_n(out, "\\\\", 2); break;
            case '\n': strbuf_append_n(out, "\\n", 2); break;
            case '\r': strbuf_append_n(out, "\\r", 2); break;
            case '\t': strbuf_append_n(out, "\\t", 2); break;
            default:
                if ((unsigned char)*c < 0x20) {
                    strbuf_append_fmt(out, "\\u%04x", (unsigned char)*c);
                } else {
                    strbuf_append_char(out, *c);
                }
                break;
        }
    }
    strbuf_append_char(out, '"');
}

Value* builtin_json_build(Value *arg) {
    /* json_build of [key1, val1, key2, val2, ...] — properly escaped JSON object */
    if (!arg || arg->type != VAL_LIST) return make_str("{}");
    int count = arg->data.list.count;
    strbuf out;
    strbuf_init(&out);
    strbuf_append_char(&out, '{');
    for (int i = 0; i + 1 < count; i += 2) {
        if (i > 0) strbuf_append_n(&out, ", ", 2);
        char *key = value_to_string(arg->data.list.items[i]);
        eigs_json_escape_string(&out, key);
        free(key);
        strbuf_append_n(&out, ": ", 2);
        Value *val = arg->data.list.items[i + 1];
        if (val->type == VAL_NUM) {
            double d = val->data.num;
            if (d == (double)(int)d && d >= -1e9 && d <= 1e9)
                strbuf_append_fmt(&out, "%d", (int)d);
            else
                strbuf_append_fmt(&out, "%.6f", d);
        } else if (val->type == VAL_NULL) {
            strbuf_append(&out, "null");
        } else if (val->type == VAL_JSON_RAW) {
            strbuf_append(&out, val->data.str);
        } else if (val->type == VAL_STR) {
            eigs_json_escape_string(&out, val->data.str);
        } else {
            char *vs = value_to_string(val);
            eigs_json_escape_string(&out, vs);
            free(vs);
        }
    }
    strbuf_append_char(&out, '}');
    Value *result = make_str(out.data);
    strbuf_free(&out);
    return result;
}

Value* builtin_json_raw(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    Value *v = xmalloc(sizeof(Value));
    memset(v, 0, sizeof(Value));
    v->type = VAL_JSON_RAW;
    v->data.str = xstrdup(arg->data.str);
    v->refcount = 1;
    return v;
}

/* ================================================================
 * GENERIC STRING PRIMITIVES — language-level, no product logic
 * ================================================================ */

Value* builtin_str_lower(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *s = xstrdup(arg->data.str);
    for (int i = 0; s[i]; i++) s[i] = tolower((unsigned char)s[i]);
    Value *r = make_str(s);
    free(s);
    return r;
}

/* #316: the string predicates reject non-string operands outright. The old
 * idiom folded them to "" — and an empty needle/prefix/suffix matches
 * everything, so `contains of [[1,2,3], 2]` reported a spurious hit. */
Value* builtin_contains(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *h = arg->data.list.items[0], *n = arg->data.list.items[1];
    if (!h || h->type != VAL_STR || !n || n->type != VAL_STR) return make_num(0);
    return make_num(strstr(h->data.str, n->data.str) != NULL ? 1 : 0);
}

Value* builtin_starts_with(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *s = arg->data.list.items[0], *p = arg->data.list.items[1];
    if (!s || s->type != VAL_STR || !p || p->type != VAL_STR) return make_num(0);
    return make_num(strncmp(s->data.str, p->data.str, strlen(p->data.str)) == 0 ? 1 : 0);
}

Value* builtin_split(Value *arg) {
    const char *str = "", *delim = " ";
    if (arg && arg->type == VAL_STR) {
        str = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
        if (arg->data.list.count >= 2 && arg->data.list.items[1]->type == VAL_STR)
            delim = arg->data.list.items[1]->data.str;
    }
    Value *list = make_list(0);
    size_t dlen = strlen(delim);
    if (dlen == 0) {
        list_append_owned(list, make_str(str));
        return list;
    }
    const char *p = str;
    const char *found;
    while ((found = strstr(p, delim)) != NULL) {
        size_t seg_len = (size_t)(found - p);
        char *seg = xmalloc(seg_len + 1);
        memcpy(seg, p, seg_len);
        seg[seg_len] = '\0';
        list_append_owned(list, make_str(seg));
        free(seg);
        p = found + dlen;
    }
    list_append_owned(list, make_str(p));
    return list;
}

/* scan_ints of text
 * scan_ints of [text, comment_marker]
 *
 * Scans whitespace-delimited signed integer tokens directly in C and returns
 * numeric values. Non-integer tokens are skipped. If comment_marker is a
 * non-empty string, lines whose first non-whitespace character matches its
 * first byte are skipped. */
Value* builtin_scan_ints(Value *arg) {
    const char *str = NULL;
    char comment_marker = '\0';

    if (arg && arg->type == VAL_STR) {
        str = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        Value *text_val = arg->data.list.items[0];
        if (text_val && text_val->type == VAL_STR) str = text_val->data.str;
        if (arg->data.list.count >= 2) {
            Value *comment_val = arg->data.list.items[1];
            if (comment_val && comment_val->type == VAL_STR && comment_val->data.str[0])
                comment_marker = comment_val->data.str[0];
        }
    }

    Value *out = make_list(128);
    if (!str) return out;

    const char *p = str;
    int line_leading = 1;
    while (*p) {
        unsigned char ch = (unsigned char)*p;
        if (isspace(ch)) {
            if (*p == '\n') line_leading = 1;
            p++;
            continue;
        }

        if (comment_marker && line_leading && *p == comment_marker) {
            while (*p && *p != '\n') p++;
            continue;
        }

        line_leading = 0;
        const char *start = p;
        int neg = 0;
        if (*p == '-' || *p == '+') {
            neg = (*p == '-');
            p++;
        }

        int digits = 0;
        double value = 0.0;
        while (*p && isdigit((unsigned char)*p)) {
            value = value * 10.0 + (double)(*p - '0');
            p++;
            digits++;
        }

        int valid = digits > 0;
        while (*p && !isspace((unsigned char)*p)) {
            valid = 0;
            p++;
        }

        if (valid) {
            if (neg) value = -value;
            list_append_owned(out, make_num(value));
        } else if (p == start) {
            p++;
        }
    }

    return out;
}

static int scan_integer_token_value(const char *start, size_t len, double *out_value) {
    if (!start || len == 0) return 0;

    size_t i = 0;
    int neg = 0;
    if (start[i] == '-' || start[i] == '+') {
        neg = (start[i] == '-');
        i++;
        if (i >= len) return 0;
    }

    double value = 0.0;
    for (; i < len; i++) {
        unsigned char ch = (unsigned char)start[i];
        if (!isdigit(ch)) return 0;
        value = value * 10.0 + (double)(ch - '0');
    }

    if (neg) value = -value;
    if (out_value) *out_value = value;
    return 1;
}

/* scan_tokens of text
 * scan_tokens of [text, comment_marker]
 *
 * Scans whitespace-delimited tokens directly in C and returns rows of
 * [token_text, line, col, start_offset, end_offset]. Lines are 1-based,
 * columns and offsets are 0-based, and end_offset is exclusive. If
 * comment_marker is non-empty, lines whose first non-whitespace character
 * matches its first byte are skipped. */
Value* builtin_scan_tokens(Value *arg) {
    const char *str = NULL;
    char comment_marker = '\0';

    if (arg && arg->type == VAL_STR) {
        str = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        Value *text_val = arg->data.list.items[0];
        if (text_val && text_val->type == VAL_STR) str = text_val->data.str;
        if (arg->data.list.count >= 2) {
            Value *comment_val = arg->data.list.items[1];
            if (comment_val && comment_val->type == VAL_STR && comment_val->data.str[0])
                comment_marker = comment_val->data.str[0];
        }
    }

    Value *out = make_list(128);
    if (!str) return out;

    const char *base = str;
    const char *p = str;
    int line = 1;
    int col = 0;
    int line_leading = 1;

    while (*p) {
        unsigned char ch = (unsigned char)*p;
        if (isspace(ch)) {
            if (*p == '\n') {
                line++;
                col = 0;
                line_leading = 1;
            } else {
                col++;
            }
            p++;
            continue;
        }

        if (comment_marker && line_leading && *p == comment_marker) {
            while (*p && *p != '\n') {
                p++;
                col++;
            }
            continue;
        }

        line_leading = 0;
        const char *start = p;
        int token_line = line;
        int token_col = col;
        while (*p && !isspace((unsigned char)*p)) {
            p++;
            col++;
        }

        size_t len = (size_t)(p - start);
        char *token = xmalloc(len + 1);
        memcpy(token, start, len);
        token[len] = '\0';

        Value *row = make_list(5);
        list_append_owned(row, make_str(token));
        list_append_owned(row, make_num((double)token_line));
        list_append_owned(row, make_num((double)token_col));
        list_append_owned(row, make_num((double)(start - base)));
        list_append_owned(row, make_num((double)(p - base)));
        list_append_owned(out, row);  /* adopt the freshly-built row */
        free(token);
    }

    return out;
}

/* scan_int_tokens of text
 * scan_int_tokens of [text, comment_marker]
 *
 * Scans whitespace-delimited tokens directly in C and returns rows of
 * [token_text, line, col, start_offset, end_offset, is_int, value]. This keeps
 * scan_tokens-compatible spans while classifying signed integer tokens in the
 * same pass. Invalid integer tokens keep their text/span, set is_int=0, and
 * use value=0. */
Value* builtin_scan_int_tokens(Value *arg) {
    const char *str = NULL;
    char comment_marker = '\0';

    if (arg && arg->type == VAL_STR) {
        str = arg->data.str;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        Value *text_val = arg->data.list.items[0];
        if (text_val && text_val->type == VAL_STR) str = text_val->data.str;
        if (arg->data.list.count >= 2) {
            Value *comment_val = arg->data.list.items[1];
            if (comment_val && comment_val->type == VAL_STR && comment_val->data.str[0])
                comment_marker = comment_val->data.str[0];
        }
    }

    Value *out = make_list(128);
    if (!str) return out;

    const char *base = str;
    const char *p = str;
    int line = 1;
    int col = 0;
    int line_leading = 1;

    while (*p) {
        unsigned char ch = (unsigned char)*p;
        if (isspace(ch)) {
            if (*p == '\n') {
                line++;
                col = 0;
                line_leading = 1;
            } else {
                col++;
            }
            p++;
            continue;
        }

        if (comment_marker && line_leading && *p == comment_marker) {
            while (*p && *p != '\n') {
                p++;
                col++;
            }
            continue;
        }

        line_leading = 0;
        const char *start = p;
        int token_line = line;
        int token_col = col;
        while (*p && !isspace((unsigned char)*p)) {
            p++;
            col++;
        }

        size_t len = (size_t)(p - start);
        char *token = xmalloc(len + 1);
        memcpy(token, start, len);
        token[len] = '\0';

        double int_value = 0.0;
        int is_int = scan_integer_token_value(start, len, &int_value);

        Value *row = make_list(7);
        list_append_owned(row, make_str(token));
        list_append_owned(row, make_num((double)token_line));
        list_append_owned(row, make_num((double)token_col));
        list_append_owned(row, make_num((double)(start - base)));
        list_append_owned(row, make_num((double)(p - base)));
        list_append_owned(row, make_num((double)is_int));
        list_append_owned(row, make_num(int_value));
        list_append_owned(out, row);  /* adopt the freshly-built row */
        free(token);
    }

    return out;
}

Value* builtin_trim(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    while (*s && (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r')) s++;
    int len = strlen(s);
    while (len > 0 && (s[len-1] == ' ' || s[len-1] == '\t' || s[len-1] == '\n' || s[len-1] == '\r')) len--;
    char *r = xmalloc(len + 1);
    memcpy(r, s, len);
    r[len] = '\0';
    Value *result = make_str(r);
    free(r);
    return result;
}

/* Upper bound on a str_replace result, beyond which it raises rather than
 * attempt the allocation (a pathological count × replacement expansion). */
#define STR_REPLACE_MAX ((size_t)256 * 1024 * 1024)

Value* builtin_str_replace(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    const char *str = "", *old_s = "", *new_s = "";
    if (arg->data.list.items[0]->type == VAL_STR) str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) old_s = arg->data.list.items[1]->data.str;
    if (arg->data.list.items[2]->type == VAL_STR) new_s = arg->data.list.items[2]->data.str;
    size_t old_len = strlen(old_s), new_len = strlen(new_s), str_len = strlen(str);
    if (old_len == 0) return make_str(str);
    /* Count occurrences to size buffer */
    size_t count = 0;
    const char *p = str;
    while ((p = strstr(p, old_s)) != NULL) { count++; p += old_len; }
    /* result_len = str_len + count*(new_len - old_len), computed in size_t.
     * The old int form overflowed count*(new_len-old_len) to a small positive
     * value, undersized the malloc, then overran it. Cap the expansion with a
     * catchable error (as tensor/model ops cap their sizes) so a pathological
     * blow-up neither overflows nor attempts a multi-gigabyte allocation. */
    size_t result_len;
    if (new_len > old_len) {
        size_t grow = new_len - old_len;
        if (count != 0 && grow > (STR_REPLACE_MAX - str_len) / count) {
            rt_error(EK_LIMIT, 0, "str_replace result too large");
            return make_null();
        }
        result_len = str_len + count * grow;
    } else {
        result_len = str_len - count * (old_len - new_len);
    }
    char *result = xmalloc(result_len + 1);
    char *dst = result;
    p = str;
    while (*p) {
        if (strncmp(p, old_s, old_len) == 0) {
            memcpy(dst, new_s, new_len);
            dst += new_len;
            p += old_len;
        } else {
            *dst++ = *p++;
        }
    }
    *dst = '\0';
    Value *r = make_str(result);
    free(result);
    return r;
}

/* ==== BUILTIN: match — regex match, return list of groups ==== */
/* match of [string, pattern] -> [full_match, group1, ...] or [] */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_match(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "regex_match requires [string, pattern]");
        return make_list(0);
    }
    if (arg->data.list.items[0]->type != VAL_STR || arg->data.list.items[1]->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_match: string and pattern must be strings");
        return make_list(0);
    }
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;

    regex_t re;
    /* #500: an invalid pattern used to return [] — indistinguishable from a
     * clean no-match. Raise so a broken pattern is visible. */
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {
        rt_error(EK_VALUE, 0, "regex_match: invalid pattern '%s'", pattern);
        return make_list(0);
    }

    /* #629: size the match array from the compiled pattern (full match + one
     * slot per capture group) rather than a fixed 16. A fixed cap silently
     * dropped groups past 15; a loop CONDITION of `rm_so >= 0` also terminated
     * emission at the first non-participating optional group, deleting every
     * later capture. re_nsub is bounded by POSIX pattern complexity;
     * xmalloc_array guards the +1 and *sizeof against size_t overflow. */
    size_t ng = re.re_nsub + 1;
    regmatch_t *matches = xmalloc_array(ng, sizeof(regmatch_t));
    if (regexec(&re, str, ng, matches, 0) != 0) {
        free(matches);
        regfree(&re);
        return make_list(0);
    }

    Value *result = make_list(8);
    for (size_t i = 0; i < ng; i++) {
        /* POSIX sets rm_so = -1 for a group that didn't participate (e.g. an
         * unmatched optional (x)?). Emit null so positional indexing holds —
         * group n stays at index n — rather than stopping the loop (#629). */
        if (matches[i].rm_so < 0) {
            list_append_owned(result, make_null());
            continue;
        }
        int len = matches[i].rm_eo - matches[i].rm_so;
        char *buf = xmalloc(len + 1);
        memcpy(buf, str + matches[i].rm_so, len);
        buf[len] = '\0';
        list_append_owned(result, make_str(buf));
        free(buf);
    }
    free(matches);
    regfree(&re);
    return result;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: match_all — find all matches of pattern ==== */
/* match_all of [string, pattern] -> [match1, match2, ...] */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_match_all(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "regex_find requires [string, pattern]");
        return make_list(0);
    }
    if (arg->data.list.items[0]->type != VAL_STR || arg->data.list.items[1]->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_find: string and pattern must be strings");
        return make_list(0);
    }
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;

    regex_t re;
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {           /* #500 */
        rt_error(EK_VALUE, 0, "regex_find: invalid pattern '%s'", pattern);
        return make_list(0);
    }

    Value *result = make_list(16);
    regmatch_t m[1];
    const char *p = str;
    while (regexec(&re, p, 1, m, 0) == 0) {
        int len = m[0].rm_eo - m[0].rm_so;
        char *buf = xmalloc(len + 1);
        memcpy(buf, p + m[0].rm_so, len);
        buf[len] = '\0';
        list_append_owned(result, make_str(buf));
        free(buf);
        p += m[0].rm_eo;
        if (len == 0) p++; /* avoid infinite loop on zero-length match */
        if (!*p) break;
    }
    regfree(&re);
    return result;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: regex_replace — replace all matches ==== */
/* regex_replace of [string, pattern, replacement] -> string */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_regex_replace(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "regex_replace requires [string, pattern, replacement]");
        return make_str("");
    }
    if (arg->data.list.items[0]->type != VAL_STR ||
        arg->data.list.items[1]->type != VAL_STR ||
        arg->data.list.items[2]->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_replace: string, pattern and replacement must be strings");
        return make_str("");
    }
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;
    const char *replacement = arg->data.list.items[2]->data.str;

    regex_t re;
    /* #500: an invalid pattern used to return the input unchanged — a silent
     * no-op that hides the broken pattern. Raise. */
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {
        rt_error(EK_VALUE, 0, "regex_replace: invalid pattern '%s'", pattern);
        return make_str("");
    }

    strbuf out;
    strbuf_init(&out);
    const char *p = str;
    regmatch_t m[1];
    size_t rep_len = strlen(replacement);

    while (regexec(&re, p, 1, m, 0) == 0) {
        strbuf_append_n(&out, p, (size_t)m[0].rm_so);
        strbuf_append_n(&out, replacement, rep_len);
        p += m[0].rm_eo;
        if (m[0].rm_eo == m[0].rm_so) {
            if (*p) strbuf_append_char(&out, *p++);
            else break;
        }
    }
    strbuf_append(&out, p);

    regfree(&re);
    Value *v = make_str(out.data);
    strbuf_free(&out);
    return v;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: str_upper ==== */
Value* builtin_str_upper(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    char *s = xstrdup(arg->data.str);
    for (int i = 0; s[i]; i++) s[i] = toupper((unsigned char)s[i]);
    Value *r = make_str(s);
    free(s);
    return r;
}

/* ==== BUILTIN: char_at ==== */
/* char_at of [string, index] → single character as string, or "" if out of range.
 * Negative indices count from the end, matching the [] operator (#312). */
Value* builtin_char_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    Value *str_val = arg->data.list.items[0];
    Value *idx_val = arg->data.list.items[1];
    if (!str_val || str_val->type != VAL_STR || !idx_val || idx_val->type != VAL_NUM)
        return make_str("");
    int idx = (int)idx_val->data.num;
    int len = strlen(str_val->data.str);
    if (idx < 0) idx += len;
    if (idx < 0 || idx >= len) return make_str("");
    char buf[2] = { str_val->data.str[idx], '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: ends_with ==== */
Value* builtin_ends_with(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *sv = arg->data.list.items[0], *xv = arg->data.list.items[1];
    if (!sv || sv->type != VAL_STR || !xv || xv->type != VAL_STR) return make_num(0);
    const char *str = sv->data.str, *suffix = xv->data.str;
    int slen = strlen(str), xlen = strlen(suffix);
    if (xlen > slen) return make_num(0);
    return make_num(strcmp(str + slen - xlen, suffix) == 0 ? 1 : 0);
}

/* ==== BUILTIN: substr ==== */
/* substr of [string, start, length] → substring */
Value* builtin_substr(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_str("");
    Value *str_val = arg->data.list.items[0];
    Value *start_val = arg->data.list.items[1];
    Value *len_val = arg->data.list.items[2];
    if (!str_val || str_val->type != VAL_STR) return make_str("");
    if (!start_val || start_val->type != VAL_NUM) return make_str("");
    if (!len_val || len_val->type != VAL_NUM) return make_str("");
    int slen = strlen(str_val->data.str);
    int start = (int)start_val->data.num;
    int rlen = (int)len_val->data.num;
    /* #504: a negative start counts from the end, matching char_at and the
     * [] operator (was a flat clamp-to-0 — inconsistent). A start still
     * negative after the adjustment (before the string) clamps to 0. */
    if (start < 0) start += slen;
    if (start < 0) start = 0;
    if (start >= slen) return make_str("");
    if (rlen < 0) rlen = 0;
    /* Subtraction form, not `start + rlen > slen`: a huge len (e.g. INT_MAX)
     * overflowed the int add to a negative value, skipping the clamp, and then
     * rlen+1 overflowed the allocation (SIGABRT). start < slen here, so
     * slen - start is a safe positive bound. */
    if (rlen > slen - start) rlen = slen - start;
    char *buf = xmalloc(rlen + 1);
    memcpy(buf, str_val->data.str + start, rlen);
    buf[rlen] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* ==== BUILTIN: index_of ==== */
/* index_of of [haystack, needle] → first index, or -1. Non-string operands
 * are a miss (-1), never a fold-to-"" false positive at index 0 (#316). */
Value* builtin_index_of(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(-1);
    Value *h = arg->data.list.items[0], *n = arg->data.list.items[1];
    if (!h || h->type != VAL_STR || !n || n->type != VAL_STR) return make_num(-1);
    const char *p = strstr(h->data.str, n->data.str);
    if (!p) return make_num(-1);
    return make_num((double)(p - h->data.str));
}

/* ================================================================
 * MATH BUILTINS — trig, rounding, abs
 * ================================================================ */

Value* builtin_sin(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(sin(arg->data.num));
}

Value* builtin_cos(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(cos(arg->data.num));
}

Value* builtin_tan(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(tan(arg->data.num));
}

Value* builtin_asin(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    double x = arg->data.num;
    if (x < -1.0) x = -1.0;
    if (x > 1.0) x = 1.0;
    return make_num(asin(x));
}

Value* builtin_acos(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    double x = arg->data.num;
    if (x < -1.0) x = -1.0;
    if (x > 1.0) x = 1.0;
    return make_num(acos(x));
}

Value* builtin_atan(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(atan(arg->data.num));
}

Value* builtin_atan2(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *y = arg->data.list.items[0];
    Value *x = arg->data.list.items[1];
    if (!y || y->type != VAL_NUM || !x || x->type != VAL_NUM) return make_num(0);
    return make_num(atan2(y->data.num, x->data.num));
}

Value* builtin_floor(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(floor(arg->data.num));
}

Value* builtin_ceil(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(ceil(arg->data.num));
}

Value* builtin_round(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(round(arg->data.num));
}

Value* builtin_abs(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    return make_num(fabs(arg->data.num));
}

/* #317: min/max are N-ary reductions over a flat list of numbers — the old
 * code silently read only items[0..1] (`max of [1,2,3]` was 2) and returned 0
 * for a 1-element list. A single bare number returns itself (mirrors `sum`);
 * an empty list or any non-number element keeps the old 0 fallback rather
 * than inventing a partial answer. */
static Value* minmax_reduce(Value *arg, int want_max) {
    if (arg && arg->type == VAL_NUM) return make_num(arg->data.num);
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1) return make_num(0);
    double best = 0.0;
    for (int i = 0; i < arg->data.list.count; i++) {
        Value *v = arg->data.list.items[i];
        if (!v || v->type != VAL_NUM) return make_num(0);
        if (i == 0 || (want_max ? v->data.num > best : v->data.num < best))
            best = v->data.num;
    }
    return make_num(best);
}

Value* builtin_min(Value *arg) { return minmax_reduce(arg, 0); }

Value* builtin_max(Value *arg) { return minmax_reduce(arg, 1); }

Value* builtin_pi(Value *arg) {
    (void)arg;
    return make_num(3.14159265358979323846);
}

/* ================================================================
 * SYSTEM BUILTINS — random, args, paths, filesystem
 * ================================================================ */

static int g_random_seeded = 0;

static void ensure_random_seeded(void) {
    if (!g_random_seeded) {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
#if EIGENSCRIPT_FREESTANDING
        srand48(ts.tv_sec ^ ts.tv_nsec);   /* no pids on bare metal */
#else
        srand48(ts.tv_sec ^ ts.tv_nsec ^ getpid());
#endif
        g_random_seeded = 1;
    }
}

/* random of null → float in [0, 1) */
Value* builtin_random(Value *arg) {
    (void)arg;
    ensure_random_seeded();
    TRACE_NONDET_RET("random", make_num(drand48()));
}

/* random_int of [lo, hi] → integer in [lo, hi] inclusive */
Value* builtin_random_int(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        TRACE_NONDET_RET("random_int", make_num(0));
    Value *lo = arg->data.list.items[0];
    Value *hi = arg->data.list.items[1];
    if (!lo || lo->type != VAL_NUM || !hi || hi->type != VAL_NUM)
        TRACE_NONDET_RET("random_int", make_num(0));
    ensure_random_seeded();
    int lo_i = (int)lo->data.num;
    int hi_i = (int)hi->data.num;
    if (hi_i < lo_i) TRACE_NONDET_RET("random_int", make_num(lo_i));
    TRACE_NONDET_RET("random_int", make_num(lo_i + (lrand48() % (hi_i - lo_i + 1))));
}

/* seed_random of n → seeds the RNG, returns 1 */
Value* builtin_seed_random(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    srand48((long)arg->data.num);
    g_random_seeded = 1;
    return make_num(1);
}

/* ================================================================
 * STREAMING BINARY WRITER — write tensor-format data incrementally
 * ================================================================
 * stream_open of ["path", count]  → opens file, writes header with count, returns 1
 * stream_write of value           → writes one float64, returns 1
 * stream_close of null            → closes the stream file, returns 1
 *
 * Format: [uint32 ndim=1][uint32 rows=1][uint32 cols=count][uint32 flags=0]
 *         then count × float64 values (written one at a time via stream_write)
 */

static FILE *g_stream_file = NULL;

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_stream_open(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *count_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR || !count_val || count_val->type != VAL_NUM)
        return make_num(0);
    if (g_stream_file) { fclose(g_stream_file); g_stream_file = NULL; }
    g_stream_file = xfopen_write(path_val->data.str, "wb");
    if (!g_stream_file) return make_num(0);
    uint32_t count = (uint32_t)count_val->data.num;
    uint32_t header[4] = { 1, 1, count, 0 }; /* ndim=1, rows=1, cols=count, flags=0 */
    if (fwrite(header, sizeof(uint32_t), 4, g_stream_file) != 4) {
        fclose(g_stream_file);
        g_stream_file = NULL;
        return make_num(0);
    }
    return make_num(1);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_stream_write(Value *arg) {
    if (!g_stream_file || !arg || arg->type != VAL_NUM) return make_num(0);
    double val = arg->data.num;
    if (fwrite(&val, sizeof(double), 1, g_stream_file) != 1) {
        fclose(g_stream_file);
        g_stream_file = NULL;
        return make_num(0);
    }
    return make_num(1);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_stream_close(Value *arg) {
    (void)arg;
    if (!g_stream_file) return make_num(0);
    int ok = (fclose(g_stream_file) == 0);
    g_stream_file = NULL;
    return make_num(ok ? 1 : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ---- Command-line arguments ---- */
static int g_argc = 0;
static char **g_argv = NULL;

void eigenscript_set_args(int argc, char **argv) {
    g_argc = argc;
    g_argv = argv;
}

/* args of null → list of command-line arguments (after the script name).
 *
 * argv is a nondeterminism source across invocations (the closed-world
 * replay invariant, #471): a program that branches on args records under
 * one argv and would silently diverge when replayed under another. So the
 * built list rides the tape as one N record and replay serves the recorded
 * list regardless of the live argv. The construction happens before the
 * return value exists, so this uses the TAKE/RECORD pair rather than
 * TRACE_NONDET_RET — under replay the early TAKE short-circuits before the
 * list is built, avoiding both the wasted work and the abandoned (leaked)
 * live list. */
Value* builtin_args(Value *arg) {
    (void)arg;
    TRACE_NONDET_TAKE("args");
    Value *list = make_list(g_argc > 2 ? g_argc - 2 : 0);
    /* g_argv[0] = eigenscript, g_argv[1] = script.eigs, g_argv[2..] = user args */
    for (int i = 2; i < g_argc; i++) {
        list_append_owned(list, make_str(g_argv[i]));
    }
    TRACE_NONDET_RECORD("args", list);
}

/* ---- Path manipulation ---- */

/* path_join of [a, b] → "a/b" */
Value* builtin_path_join(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_str("");
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_STR || !b || b->type != VAL_STR)
        return make_str("");
    int alen = strlen(a->data.str);
    int blen = strlen(b->data.str);
    /* Skip trailing slash on a, skip leading slash on b */
    int strip_a = (alen > 0 && a->data.str[alen-1] == '/') ? 1 : 0;
    int skip_b = (blen > 0 && b->data.str[0] == '/') ? 1 : 0;
    int rlen = (alen - strip_a) + 1 + (blen - skip_b);
    char *buf = xmalloc(rlen + 1);
    memcpy(buf, a->data.str, alen - strip_a);
    buf[alen - strip_a] = '/';
    memcpy(buf + alen - strip_a + 1, b->data.str + skip_b, blen - skip_b);
    buf[rlen] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* path_dir of "a/b/c.txt" → "a/b" */
Value* builtin_path_dir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    if (!last) return make_str(".");
    if (last == s) return make_str("/");
    int len = last - s;
    char *buf = xmalloc(len + 1);
    memcpy(buf, s, len);
    buf[len] = '\0';
    Value *r = make_str(buf);
    free(buf);
    return r;
}

/* path_base of "a/b/c.txt" → "c.txt" */
Value* builtin_path_base(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    return make_str(last ? last + 1 : s);
}

/* path_ext of "a/b/c.txt" → ".txt" */
Value* builtin_path_ext(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_str("");
    const char *base = strrchr(arg->data.str, '/');
    const char *s = base ? base + 1 : arg->data.str;
    const char *dot = strrchr(s, '.');
    return make_str(dot ? dot : "");
}

/* ---- Filesystem ---- */

/* mkdir of "path" → 1 on success, 0 on failure. Creates parents. */
#if !EIGENSCRIPT_FREESTANDING
/* #585: mkdir's return (a success bit) is filesystem-dependent, so it is a
 * taped nondeterminism source. Under EIGS_REPLAY the TAKE short-circuits
 * before any mkdir(2), so the recorded bit is served and the filesystem is
 * NOT mutated a second time — the same "don't re-run side effects on replay"
 * rule as the proc-star / audio-capture boundary. Its return IS pinnable by
 * the tape (unlike a proc fd), so it is Recorded, not #148-non-replayable. */
Value* builtin_mkdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("mkdir", make_num(0));
    TRACE_NONDET_TAKE("mkdir");
    /* Simple recursive mkdir */
    char *path = xstrdup(arg->data.str);
    int len = strlen(path);
    for (int i = 1; i <= len; i++) {
        if (path[i] == '/' || path[i] == '\0') {
            char saved = path[i];
            path[i] = '\0';
            mkdir(path, 0755); /* ignore errors on intermediate dirs */
            path[i] = saved;
        }
    }
    free(path);
    struct stat st;
    TRACE_NONDET_RECORD("mkdir",
        make_num(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : 0));
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ls of "path" → list of filenames in directory, or [] on failure.
 * Matches `ls -1` default behavior: hidden entries (starting with '.') are excluded. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_ls(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("ls", make_list(0));
    /* #585: builds its return (a list) via readdir, so under EIGS_REPLAY the
     * TAKE short-circuits before opendir — the recorded listing is served and
     * the live directory is never read. */
    TRACE_NONDET_TAKE("ls");
    Value *list = make_list(0);
    DIR *d = opendir(arg->data.str);
    if (!d) TRACE_NONDET_RECORD("ls", list);
    struct dirent *entry;
    while ((entry = readdir(d))) {
        if (entry->d_name[0] == '.') continue;
        list_append_owned(list, make_str(entry->d_name));
    }
    closedir(d);
    TRACE_NONDET_RECORD("ls", list);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* getcwd of null → current working directory as string */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_getcwd(Value *arg) {
    (void)arg;
    /* #585: the cwd is process environment, nondeterministic across
     * invocations and machines — taped so replay serves the recorded path. */
    TRACE_NONDET_TAKE("getcwd");
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) TRACE_NONDET_RECORD("getcwd", make_str(buf));
    TRACE_NONDET_RECORD("getcwd", make_str(""));
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* exe_path of null → absolute path of the running interpreter binary.
 * Lets an EigenScript program re-invoke the same interpreter — e.g. a
 * test runner spawning `exec_capture of [exe_path of null, testfile]`,
 * which is more robust than assuming `eigenscript` is on PATH. Reads
 * /proc/self/exe; falls back to argv[0]. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_exe_path(Value *arg) {
    (void)arg;
    /* #585: the interpreter path is machine-dependent — taped so replay
     * serves the recorded path without touching /proc/self/exe. */
    TRACE_NONDET_TAKE("exe_path");
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0 && n < (ssize_t)sizeof(buf)) {
        buf[n] = '\0';
        TRACE_NONDET_RECORD("exe_path", make_str(buf));
    }
    if (g_argv && g_argc > 0 && g_argv[0])
        TRACE_NONDET_RECORD("exe_path", make_str(g_argv[0]));
    TRACE_NONDET_RECORD("exe_path", make_str("eigenscript"));
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* chdir of "path" → 1 on success, 0 on failure */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_chdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(chdir(arg->data.str) == 0 ? 1 : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* mktemp of null → path to a new temporary file */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_mktemp(Value *arg) {
    (void)arg;
    char tmpl[] = "/tmp/eigen_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return make_str("");
    close(fd);
    return make_str(tmpl);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* free_val of value → frees a heap-allocated Value tree. Returns null.
 * Use this to release large temporary results (e.g. tokenize_with_names output)
 * when the arena is not active. No-op on arena-allocated values. */
Value* builtin_free_val(Value *arg) {
    if (arg && !g_arena.active) val_decref(arg);
    return make_null();
}

/* rm of "path" → 1 on success, 0 on failure */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_rm(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(unlink(arg->data.str) == 0 ? 1 : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ================================================================
 * BUILTIN: build_corpus — 3-pass corpus builder in C
 * ================================================================
 * build_corpus of [file_list, top_n, stream_path, vocab_path]
 *
 * file_list:    list of strings (paths to .eigs files)
 * top_n:        number of identifier tokens to promote (e.g. 64)
 * stream_path:  output path for binary token stream
 * vocab_path:   output path for identifier vocab JSON
 *
 * Returns: [stream_length, distinct_identifiers, files_found]
 */

/* Identifier frequency entry */
typedef struct {
    char *name;
    int count;
} IdentEntry;

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_build_corpus(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4)
        return make_null();

    Value *file_list = arg->data.list.items[0];
    Value *topn_val = arg->data.list.items[1];
    Value *stream_path_val = arg->data.list.items[2];
    Value *vocab_path_val = arg->data.list.items[3];

    if (!file_list || file_list->type != VAL_LIST) return make_null();
    if (!topn_val || topn_val->type != VAL_NUM) return make_null();
    if (!stream_path_val || stream_path_val->type != VAL_STR) return make_null();
    if (!vocab_path_val || vocab_path_val->type != VAL_STR) return make_null();

    int top_n = (int)topn_val->data.num;
    int n_files = file_list->data.list.count;

    /* ---- SLOT MODE (optional 6th arg: slot_count > 0) --------------------
     * Measured on the 2026-07 ecosystem corpus: of 379,321 identifier
     * occurrences, only 7.1% are builtin/stdlib names (219 distinct) and
     * 92.9% are local names (25,355 distinct). A correctness requirement
     * attaches only to the first group -- you cannot call `pront` -- while
     * ANY consistent renaming of a local yields an equally correct program.
     *
     * Frequency mode spends the whole budget memorising the 25,355 arbitrary
     * names and still drops 45.7% of occurrences into one fallback token, so
     * distinct variables become indistinguishable and a correct program is
     * not expressible: `v0 is v0 + v1` collapses to <ident> is <ident> +
     * <ident>.
     *
     * Slot mode instead gives every builtin an exact token and encodes each
     * local by WHICH local it is, via an LRU slot table. Distinct locals per
     * real 32-token window: median 5, p99 10, max 17 -- so 20 slots cover
     * 100% of windows, and no eviction can occur inside a window (all of a
     * window's locals are more recently used than anything it would evict).
     * Total vocabulary lands at ~324 against 341 today, with ZERO identifier
     * information lost. */
    int slot_count = 0;
    if (arg->data.list.count >= 6) {
        Value *sv = arg->data.list.items[5];
        if (sv && sv->type == VAL_NUM) slot_count = (int)sv->data.num;
    }
    if (slot_count < 0) slot_count = 0;
    /* Source of truth: the size of the TokType enum. Hardcoding 54 (which is
     * what this was before) silently aliases TOK_LBRACKET (=54) onto the most
     * common extended ident slot whenever the enum grows. */
    const int BASE_VOCAB = tok_base_string_id_count();
    const int FIRST_IDENT = BASE_VOCAB;

    /* ---- Pass 1: tokenize all files, count identifier frequencies ---- */
    IdentEntry *idents = NULL;
    int n_idents = 0;
    int idents_cap = 0;

    int *file_tok_counts = xcalloc(n_files, sizeof(int));
    int total_tokens = 0;
    int files_found = 0;

    for (int fi = 0; fi < n_files; fi++) {
        Value *path_val = file_list->data.list.items[fi];
        if (!path_val || path_val->type != VAL_STR) { file_tok_counts[fi] = 0; continue; }
        const char *path = path_val->data.str;

        /* Read file */
        long fsize = 0;
        char *source = read_file_util(path, &fsize);
        if (!source) {
            fprintf(stderr, "  skip: %s\n", path);
            file_tok_counts[fi] = 0;
            continue;
        }

        /* Tokenize */
        TokenList tl = tokenize(source);
        file_tok_counts[fi] = tl.count;
        total_tokens += tl.count;
        files_found++;

        /* Count identifiers */
        for (int i = 0; i < tl.count; i++) {
            if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                const char *name = tl.tokens[i].str_val;
                /* Linear scan for existing entry */
                int found = -1;
                for (int j = 0; j < n_idents; j++) {
                    if (strcmp(idents[j].name, name) == 0) { found = j; break; }
                }
                if (found >= 0) {
                    idents[found].count++;
                } else {
                    if (n_idents >= idents_cap) {
                        idents_cap = idents_cap < 256 ? 256 : idents_cap * 2;
                        idents = xrealloc_array(idents, idents_cap, sizeof(IdentEntry));
                    }
                    idents[n_idents].name = xstrdup(name);
                    idents[n_idents].count = 1;
                    n_idents++;
                }
            }
        }

        fprintf(stderr, "  %s: %d tokens\n", path, tl.count);
        free_tokenlist(&tl);
        free(source);
    }

    fprintf(stderr, "\nFiles: %d/%d\n", files_found, n_files);
    fprintf(stderr, "Distinct identifiers: %d\n", n_idents);

    /* ---- Pass 2: pick the exact-token identifiers ----
     * Slot mode asks the RUNTIME'S OWN registry which names are builtins,
     * rather than carrying a hardcoded list that would silently drift as
     * builtins are added. Everything else becomes a slot. */
    if (slot_count > 0) {
        int keep = 0;
        for (int i = 0; i < n_idents; i++) {
            Value *bv = env_get(g_global_env, idents[i].name);
            if (bv && (bv->type == VAL_BUILTIN || bv->type == VAL_FN)) {
                if (keep != i) { IdentEntry tmp = idents[keep]; idents[keep] = idents[i]; idents[i] = tmp; }
                keep++;
            }
        }
        top_n = keep;
        fprintf(stderr, "Slot mode: %d builtin names kept exact, %d locals -> %d slots\n",
                keep, n_idents - keep, slot_count);
    }
    int actual_top = top_n < n_idents ? top_n : n_idents;
    if (actual_top <= 0) actual_top = 0;
    char **top_names = xcalloc(actual_top > 0 ? actual_top : 1, sizeof(char*));
    int *top_ids = xcalloc(actual_top > 0 ? actual_top : 1, sizeof(int));

    /* Work on a copy of counts */
    int *work_counts = xmalloc_array(n_idents, sizeof(int));
    for (int i = 0; i < n_idents; i++) work_counts[i] = idents[i].count;

    if (slot_count > 0) {
        /* Slot mode already partitioned the builtins to the front; take them
         * verbatim. Re-selecting by frequency here would hand the exact tokens
         * to the most COMMON names (which are locals like `total`/`items`) and
         * push the builtins into slots -- exactly backwards, since a local's
         * name is arbitrary and a builtin's is not. */
        for (int t = 0; t < actual_top; t++) {
            top_names[t] = idents[t].name;
            top_ids[t] = FIRST_IDENT + t;
        }
    } else {
        for (int t = 0; t < actual_top; t++) {
            int best_idx = -1, best_val = -1;
            for (int j = 0; j < n_idents; j++) {
                if (work_counts[j] > best_val) { best_val = work_counts[j]; best_idx = j; }
            }
            if (best_idx < 0) break;
            top_names[t] = idents[best_idx].name;
            top_ids[t] = FIRST_IDENT + t;
            work_counts[best_idx] = -1;
        }
    }
    free(work_counts);

    /* LRU slot table state (slot mode only). */
    char **slot_names = NULL; long *slot_used = NULL; long slot_clock = 0;
    if (slot_count > 0) {
        slot_names = xcalloc(slot_count, sizeof(char*));
        slot_used  = xcalloc(slot_count, sizeof(long));
    }

    fprintf(stderr, "\nTop %d identifiers:\n", actual_top);
    for (int i = 0; i < 10 && i < actual_top; i++) {
        fprintf(stderr, "  %3d  %-20s  %d uses\n", top_ids[i], top_names[i],
                idents[top_ids[i] - FIRST_IDENT].count);
    }

    /* ---- Pass 3: re-tokenize and write binary stream ---- */
    int stream_size = total_tokens + files_found * 2; /* +2 EOF per file */

    FILE *stream_file = xfopen_write(stream_path_val->data.str, "wb");
    if (!stream_file) {
        fprintf(stderr, "Error: cannot open %s\n", stream_path_val->data.str);
        free(file_tok_counts); free(top_names); free(top_ids);
        for (int i = 0; i < n_idents; i++) free(idents[i].name);
        free(idents);
        return make_null();
    }

    /* Write header: ndim=1, rows=1, cols=stream_size, flags=0 */
    uint32_t header[4] = { 1, 1, (uint32_t)stream_size, 0 };
    fwrite(header, sizeof(uint32_t), 4, stream_file);
    int stream_pos = 0;

    for (int fi = 0; fi < n_files; fi++) {
        if (file_tok_counts[fi] <= 0) continue;

        Value *path_val = file_list->data.list.items[fi];
        long fsize = 0;
        char *source = read_file_util(path_val->data.str, &fsize);
        if (!source) continue;

        /* Write double-EOF separator */
        double eof_val = (double)TOK_EOF;
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        stream_pos += 2;

        TokenList tl = tokenize(source);

        for (int i = 0; i < tl.count; i++) {
            int tid = tl.tokens[i].type;
            /* Replace known identifiers with extended IDs */
            if (tid == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                int matched = 0;
                for (int j = 0; j < actual_top; j++) {
                    if (strcmp(top_names[j], tl.tokens[i].str_val) == 0) {
                        tid = top_ids[j];
                        matched = 1;
                        break;
                    }
                }
                if (!matched && slot_count > 0) {
                    /* LRU slot table: a name keeps its slot until evicted, so
                     * every occurrence inside a window maps to the SAME token
                     * -- which is precisely what lets the model express "the
                     * variable I just read" and what the fallback destroyed. */
                    int hit = -1;
                    for (int j = 0; j < slot_count; j++)
                        if (slot_names[j] && strcmp(slot_names[j], tl.tokens[i].str_val) == 0) { hit = j; break; }
                    if (hit < 0) {
                        int lru = 0;
                        for (int j = 1; j < slot_count; j++)
                            if (slot_used[j] < slot_used[lru]) lru = j;
                        free(slot_names[lru]);
                        slot_names[lru] = xstrdup(tl.tokens[i].str_val);
                        hit = lru;
                    }
                    slot_used[hit] = ++slot_clock;
                    tid = FIRST_IDENT + actual_top + hit;
                }
            }
            double d = (double)tid;
            fwrite(&d, sizeof(double), 1, stream_file);
            stream_pos++;
        }

        free_tokenlist(&tl);
        free(source);
    }

    fclose(stream_file);
    if (slot_names) {
        for (int j = 0; j < slot_count; j++) free(slot_names[j]);
        free(slot_names); free(slot_used);
    }
    fprintf(stderr, "\nWritten: %s (%d tokens)\n", stream_path_val->data.str, stream_pos);

    /* ---- Write identifier vocab JSON ----
     * Emits base_names[] (placeholder text for each base TokType, in ID order)
     * and structural_ids{} (the IDs the detokenizer special-cases). Downstream
     * scripts read these instead of hardcoding TokType ordinals so the stream
     * and detokenizer stay aligned when the enum grows. */
    FILE *vocab_file = xfopen_write(vocab_path_val->data.str, "w");
    if (vocab_file) {
        fprintf(vocab_file,
                "{\"first_ident_id\": %d, \"ext_vocab_size\": %d, \"base_vocab\": %d, \"slot_count\": %d, \"first_slot_id\": %d, \"top_n\": %d",
                FIRST_IDENT, BASE_VOCAB + actual_top + slot_count, BASE_VOCAB,
                slot_count, FIRST_IDENT + actual_top, actual_top);
        fprintf(vocab_file, ", \"structural_ids\": {\"newline\": %d, \"indent\": %d, \"dedent\": %d, \"eof\": %d, \"ident_fallback\": %d}",
                (int)TOK_NEWLINE, (int)TOK_INDENT, (int)TOK_DEDENT, (int)TOK_EOF, (int)TOK_IDENT);
        fprintf(vocab_file, ", \"base_names\": [");
        for (int i = 0; i < BASE_VOCAB; i++) {
            if (i > 0) fprintf(vocab_file, ", ");
            fprintf(vocab_file, "\"");
            const char *s = tok_base_string((TokType)i);
            for (const char *q = s; *q; q++) {
                if (*q == '"' || *q == '\\') fputc('\\', vocab_file);
                fputc(*q, vocab_file);
            }
            fprintf(vocab_file, "\"");
        }
        fprintf(vocab_file, "], \"names\": [");
        for (int i = 0; i < actual_top; i++) {
            if (i > 0) fprintf(vocab_file, ", ");
            fprintf(vocab_file, "\"%s\"", top_names[i]);
        }
        fprintf(vocab_file, "]}");
        fclose(vocab_file);
        fprintf(stderr, "Written: %s\n", vocab_path_val->data.str);
    }

    /* ---- Optional 5th arg: full identifier histogram JSON ----
     * Sorted by count descending. Enables exact coverage(top_n) curves
     * without re-running the full corpus build. */
    if (arg->data.list.count >= 5) {
        Value *idents_path_val = arg->data.list.items[4];
        if (idents_path_val && idents_path_val->type == VAL_STR && n_idents > 0) {
            /* Build index array, sort descending by count via simple sort */
            int *order = xmalloc_array(n_idents, sizeof(int));
            for (int i = 0; i < n_idents; i++) order[i] = i;
            /* Insertion sort is fine — n_idents is small thousands and runs once */
            for (int i = 1; i < n_idents; i++) {
                int key = order[i];
                int kc = idents[key].count;
                int j = i - 1;
                while (j >= 0 && idents[order[j]].count < kc) {
                    order[j+1] = order[j];
                    j--;
                }
                order[j+1] = key;
            }
            FILE *hist_file = xfopen_write(idents_path_val->data.str, "w");
            if (hist_file) {
                fprintf(hist_file, "{\"n_idents\": %d, \"entries\": [", n_idents);
                for (int i = 0; i < n_idents; i++) {
                    int idx = order[i];
                    if (i > 0) fprintf(hist_file, ", ");
                    fprintf(hist_file, "[\"%s\", %d]", idents[idx].name, idents[idx].count);
                }
                fprintf(hist_file, "]}");
                fclose(hist_file);
                fprintf(stderr, "Written: %s\n", idents_path_val->data.str);
            }
            free(order);
        }
    }

    /* ---- Cleanup ---- */
    free(file_tok_counts);
    free(top_names);
    free(top_ids);
    for (int i = 0; i < n_idents; i++) free(idents[i].name);
    free(idents);

    /* Return [stream_length, distinct_identifiers, files_found] */
    Value *result = make_list(3);
    list_append_owned(result, make_num(stream_pos));
    list_append_owned(result, make_num(n_idents));
    list_append_owned(result, make_num(files_found));
    return result;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ================================================================
 * GENERIC HTTP CLIENT — language-level, no product logic
 * ================================================================ */


/* ================================================================
 * JSON PATH — dot-notation extraction from nested JSON
 * ================================================================ */

/* json_obj_get: needed by json_path, defined here if model extension is disabled */
#if !(EIGENSCRIPT_EXT_MODEL)
static Value* json_obj_get(Value *obj, const char *key) {
    if (!obj || obj->type != VAL_LIST) return NULL;
    for (int i = 0; i + 1 < obj->data.list.count; i += 2) {
        Value *k = obj->data.list.items[i];
        if (k && k->type == VAL_STR && strcmp(k->data.str, key) == 0)
            return obj->data.list.items[i + 1];
    }
    return NULL;
}
#endif

Value* builtin_json_path(Value *arg) {
    /* json_path of [json_string, "dot.path"] -> value as string, or "" */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_str("");
    const char *json_str = "", *path = "";
    if (arg->data.list.items[0]->type == VAL_STR) json_str = arg->data.list.items[0]->data.str;
    if (arg->data.list.items[1]->type == VAL_STR) path = arg->data.list.items[1]->data.str;

    /* #507: reject empty path segments (a leading/trailing dot or a `..`).
     * strtok silently skips them, so "a..b", ".a" and "a." used to resolve
     * as if the empty piece weren't there — masking a malformed path. An
     * entirely empty path ("") still means the root document. */
    if (path[0] != '\0') {
        size_t plen = strlen(path);
        if (path[0] == '.' || path[plen - 1] == '.' || strstr(path, "..")) {
            rt_error(EK_VALUE, 0, "json_path: empty path segment in '%s'", path);
            return make_str("");
        }
    }

    int pos = 0;
    Value *root = eigs_json_parse_value(json_str, &pos);
    if (!root) return make_str("");
    Value *current = root;   /* walks borrowed children of root */

    char path_copy[1024];
    strncpy(path_copy, path, sizeof(path_copy) - 1);
    path_copy[sizeof(path_copy) - 1] = '\0';
    char *saveptr;
    char *segment = strtok_r(path_copy, ".", &saveptr);

    while (segment && current) {
        if (current->type == VAL_DICT) {
            current = dict_get(current, segment);
            if (!current) { val_decref(root); return make_str(""); }
        } else if (current->type == VAL_LIST) {
            /* Array — try numeric index */
            char *endp;
            long idx = strtol(segment, &endp, 10);
            if (*endp == '\0') {
                /* Numeric: treat as array index */
                /* Arrays from json_decode are VAL_LIST with sequential elements */
                if (idx >= 0 && idx < current->data.list.count) {
                    current = current->data.list.items[idx];
                } else {
                    val_decref(root); return make_str("");
                }
            } else {
                /* String key: treat as object lookup */
                current = json_obj_get(current, segment);
                if (!current) { val_decref(root); return make_str(""); }
            }
        } else {
            val_decref(root); return make_str("");
        }
        segment = strtok_r(NULL, ".", &saveptr);
    }

    if (!current) { val_decref(root); return make_str(""); }
    if (current->type == VAL_STR) {
        Value *r = make_str(current->data.str);
        val_decref(root);
        return r;
    }
    if (current->type == VAL_NUM) {
        char buf[64];
        double d = current->data.num;
        if (d == (double)(int)d && fabs(d) < 1e9)
            snprintf(buf, sizeof(buf), "%d", (int)d);
        else
            snprintf(buf, sizeof(buf), "%.6f", d);
        val_decref(root);
        return make_str(buf);
    }
    if (current->type == VAL_NULL) { val_decref(root); return make_str(""); }
    /* For complex types, json_encode them */
    strbuf out;
    strbuf_init(&out);
    eigs_json_encode_value(current, &out);
    Value *r = make_str(out.data);
    strbuf_free(&out);
    val_decref(root);
    return r;
}


/* ================================================================
 * LOAD_FILE — include mechanism for .eigs modules
 * ================================================================ */

/* File I/O helper — used by load_file and main() */
#if !EIGENSCRIPT_FREESTANDING
char* read_file_util(const char *path, long *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    /* #314: fopen succeeds on a directory, and ftell then reports LONG_MAX —
     * which sailed straight into xmalloc's fatal-OOM abort. Reject
     * directories here so callers hit their existing clean error paths. */
    struct stat st;
    if (fstat(fileno(f), &st) == 0 && !S_ISREG(st.st_mode)) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size < 0 || size == LONG_MAX) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    char *buf = xmalloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, size, f);
    fclose(f);
    if ((long)got != size) { free(buf); return NULL; }
    buf[size] = '\0';
    if (out_size) *out_size = size;
    return buf;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
static int try_resolve_path(const char *candidate, char *resolved, size_t resolved_cap) {
    if (!candidate || access(candidate, F_OK) != 0) return 0;
    snprintf(resolved, resolved_cap, "%s", candidate);
    return 1;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* Phase 0c: walk from `base` upward looking for
 *   <dir>/eigs_modules/<name>/<name>.eigs
 * at each level. Stop at the project root (a directory containing
 * eigs.json) — its eigs_modules/ is checked once, then we don't go
 * higher. Only fires for bare `<name>.eigs` requests (no slashes); the
 * resolver's existing chain still handles paths with directory
 * components. Bounded to 64 levels for safety. */
#if !EIGENSCRIPT_FREESTANDING
static int try_eigs_modules_walk(const char *base, const char *path,
                                  char *resolved, size_t resolved_cap) {
    if (!base || !base[0] || !path) return 0;
    if (strchr(path, '/')) return 0;
    size_t plen = strlen(path);
    if (plen < 6 || strcmp(path + plen - 5, ".eigs") != 0) return 0;
    if (plen - 5 >= 512) return 0;

    char name[512];
    memcpy(name, path, plen - 5);
    name[plen - 5] = '\0';

    char cur[4096];
    snprintf(cur, sizeof(cur), "%s", base);

    for (int i = 0; i < 64; i++) {
        char candidate[8192];
        snprintf(candidate, sizeof(candidate),
                 "%.3000s/eigs_modules/%.500s/%.500s.eigs",
                 cur, name, name);
        if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

        char marker[4400];
        snprintf(marker, sizeof(marker), "%.4000s/eigs.json", cur);
        if (access(marker, F_OK) == 0) return 0;

        char *slash = strrchr(cur, '/');
        if (!slash || slash == cur) return 0;
        *slash = '\0';
    }
    return 0;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if EIGENSCRIPT_FREESTANDING
int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap) {
    (void)base; (void)path; (void)resolved; (void)resolved_cap;
    return 0;   /* nothing resolves without a filesystem */
}
#else
int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap) {
    char candidate[8192];

    if (!path || !resolved || resolved_cap == 0) return 0;
    if (!base || !base[0]) base = g_script_dir;

    if (path[0] == '/') {
        return try_resolve_path(path, resolved, resolved_cap);
    }

    if (try_resolve_path(path, resolved, resolved_cap)) return 1;

    if (try_eigs_modules_walk(base, path, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/%.4000s", base, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../%.4000s", base, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../%.4000s", g_exe_dir, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../lib/eigenscript/%.4000s", g_exe_dir, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    if (strncmp(path, "lib/", 4) == 0) {
        snprintf(candidate, sizeof(candidate), "%.4000s/../lib/eigenscript/%.4000s", g_exe_dir, path + 4);
        if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;
    }

    const char *home = getenv("HOME");
    if (home) {
        snprintf(candidate, sizeof(candidate), "%.2000s/.local/lib/eigenscript/%.4000s", home, path);
        if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

        if (strncmp(path, "lib/", 4) == 0) {
            snprintf(candidate, sizeof(candidate), "%.2000s/.local/lib/eigenscript/%.4000s", home, path + 4);
            if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;
        }
    }

    return 0;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

int resolve_eigenscript_file(const char *path, char *resolved, size_t resolved_cap) {
    return resolve_eigenscript_file_from(g_script_dir, path, resolved, resolved_cap);
}

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_load_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "load_file requires a string path argument");
        return make_null();
    }
    char resolved[8192];
    const char *path = arg->data.str;
    long size = 0;
    char *source = NULL;

    if (resolve_eigenscript_file(arg->data.str, resolved, sizeof(resolved))) {
        path = resolved;
        source = read_file_util(path, &size);
    }

    if (!source) {
        /* #490: match import's severity — a missing path is a catchable io
         * error, not a stderr-warn + silent null (rc=0). Callers that ignore
         * the return otherwise run on half-initialized state. */
        rt_error(EK_IO, 0, "load_file: cannot read '%s'", arg->data.str);
        return make_null();
    }

    /* #496: circular-load guard. load_file has no module cache — it
     * re-executes every call — so a mutual load (a loads b, b loads a)
     * recurses through vm_execute to a C-stack SIGSEGV. Key on the
     * canonical path (shared with import's cycle stack) and raise if this
     * path's load is already on the stack. Sequential re-loads of the same
     * file stay legal: the entry pops when each load completes. */
    char abs_key[8192];
    if (!realpath(path, abs_key))
        snprintf(abs_key, sizeof(abs_key), "%s", path);
    if (eigs_loading_active(abs_key)) {
        free(source);
        rt_error(EK_IO, 0,
            "load_file: circular dependency — '%s' is already being loaded",
            arg->data.str);
        return make_null();
    }

    /* #560: silent by default — no other successful builtin announces
     * itself, and shipped CLI tools built on load_file must be able to keep
     * stderr clean. Set EIGS_VERBOSE_LOAD=1 for the development banner. */
    if (getenv("EIGS_VERBOSE_LOAD"))
        fprintf(stderr, "[load_file] Loading %s (%ld bytes)\n", path, size);

    /* A parse error in the loaded file must surface, not be silently run as a
     * partial/incorrect AST. Direct execution aborts on g_parse_errors; mirror
     * that here (and match builtin_eval) by raising a catchable runtime error.
     * Without this, malformed statements a module can't parse — e.g. an
     * expression-rooted lvalue like `(call).field is x` — were silently accepted
     * and their effect dropped (the load_file half of liferaft FINDINGS F1).
     * Save/restore g_parse_errors so a recovered (try/catch'd) load doesn't
     * perturb a caller's count. */
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);

    if (g_parse_errors > 0 || !ast) {
        g_parse_errors = saved_errors;
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        rt_error(EK_PARSE, 0, "load_file: parse error in '%s'", arg->data.str);
        return make_null();
    }
    /* Compile-stage diagnostics must fail the load too (#337) — same
     * rationale as eval above. */
    Env *target = g_load_env ? g_load_env : g_global_env;
    int saved_boundary = g_compile_module_boundary;
    g_compile_module_boundary = 1;                       /* #373 */
    EigsChunk *lf_chunk = compile_ast(ast, target, source);
    g_compile_module_boundary = saved_boundary;
    if (g_parse_errors > 0) {
        g_parse_errors = saved_errors;
        chunk_free(lf_chunk);
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        rt_error(EK_PARSE, 0, "load_file: compile error in '%s'", arg->data.str);
        return make_null();
    }
    g_parse_errors = saved_errors;
    eigs_loading_enter(abs_key);            /* #496 */
    Value *result = vm_execute(lf_chunk, target);
    eigs_loading_leave(abs_key);            /* #496 */
    chunk_free(lf_chunk);   /* creator ref; loaded fns hold their own */
    free_ast(ast);
    free(source);
    free_tokenlist(&tl);
    return result ? result : make_null();
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ================================================================
 * THIN BUILTINS — individual capabilities for .eigs orchestration
 * ================================================================ */


/* ================================================================
 * CORE PLATFORM BUILTINS (always available)
 * ================================================================ */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_file_exists(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("file_exists", make_num(0));
    /* #585: fs-dependent read — taped so replay serves the recorded answer.
     * TAKE short-circuits before the fopen probe under EIGS_REPLAY. */
    TRACE_NONDET_TAKE("file_exists");
    FILE *f = fopen(arg->data.str, "r");
    int ex = (f != NULL);
    if (f) fclose(f);
    TRACE_NONDET_RECORD("file_exists", make_num(ex));
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* is_dir of path — 1 if path names a directory, 0 for a plain file, a
 * missing path, or a non-string arg. Replaces the consumer-side
 * `file_exists of f"{path}/."` probe (#576). Nondeterministic fs read →
 * trace-recorded per the tape-first rule (NB: the older fs predicates —
 * file_exists, ls, mkdir, getcwd — predate the tape and are untraced;
 * that inconsistency is flagged on the PR, not silently copied here). */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_is_dir(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("is_dir", make_num(0));
    struct stat st;
    TRACE_NONDET_RET("is_dir",
        make_num(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : 0));
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* rename of [old_path, new_path] — rename/replace a file. On POSIX rename(2) is
 * atomic: a crash leaves either the old file or the new file fully in place,
 * never a torn mix — the basis for crash-safe log compaction (write a new log to
 * a temp file, then atomically swap it in). Returns 1 on success, 0 on failure. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_rename(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *from = arg->data.list.items[0];
    Value *to = arg->data.list.items[1];
    if (!from || from->type != VAL_STR || !to || to->type != VAL_STR) return make_num(0);
    return make_num(rename(from->data.str, to->data.str) == 0 ? 1 : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* remove_file of path — delete a file. Returns 1 on success, 0 on failure. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_remove_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(remove(arg->data.str) == 0 ? 1 : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

Value* builtin_env_get(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("env_get", make_str(""));
    const char *val = getenv(arg->data.str);
    TRACE_NONDET_RET("env_get", make_str(val ? val : ""));
}

/* ==== BUILTIN: read_text ==== */
/* read_text of "path" → file contents as string, or "" on failure. */
/* read_bytes of path — read binary file, return list of byte values (0-255) */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_read_bytes(Value *arg) {
    TRACE_NONDET_TAKE("read_bytes");
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RECORD("read_bytes", make_null());
    FILE *f = fopen(arg->data.str, "rb");
    if (!f) TRACE_NONDET_RECORD("read_bytes", make_null());
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 10 * 1024 * 1024) { /* 10 MB cap */
        fclose(f);
        TRACE_NONDET_RECORD("read_bytes", make_null());
    }
    unsigned char *buf = xmalloc(len);
    if (!buf) { fclose(f); TRACE_NONDET_RECORD("read_bytes", make_null()); }
    size_t nread = fread(buf, 1, len, f);
    fclose(f);
    Value *result = make_list((int)nread);
    for (size_t i = 0; i < nread; i++)
        list_append_owned(result, make_num((double)buf[i]));
    free(buf);
    TRACE_NONDET_RECORD("read_bytes", result);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* read_bytes_buf of path — read binary file, return VAL_BUFFER of byte values.
 * read_bytes_buf of [path, max_bytes] — opt-in cap override (#601).
 * Zero per-element allocation; O(1) indexed access.
 *
 * Cap policy (#601): the 1-arg form keeps the historical 10 MB cap (the
 * security posture is unchanged — a script that never asks for more never
 * gets more). An over-cap file RAISES a catchable `io` error naming the
 * size and the active cap; the old behavior returned null, which was
 * indistinguishable from "file missing" and surfaced downstream as a
 * misleading diagnosis (DeslanStudio: a >10 MB WAV died as "not a WAV
 * file"). max_bytes is bounded by a 512 MB hard ceiling: a VAL_BUFFER
 * holds one double per byte (8x expansion — 512 MB of file is already
 * ~4 GiB resident), so the ceiling keeps the opt-in from becoming an
 * unbounded fs->RAM amplifier while blocking no realistic asset.
 * Missing/unopenable file still returns null (existing contract). */
#if !EIGENSCRIPT_FREESTANDING
#define READ_BYTES_BUF_DEFAULT_CAP (10LL * 1024 * 1024)
#define READ_BYTES_BUF_HARD_CAP    (512LL * 1024 * 1024)

/* One raise site shared by the live and replay paths so the message
 * cannot drift between them. */
static void read_bytes_buf_cap_raise(const char *path, long long len,
                                     long long cap) {
    rt_error(EK_IO, 0,
             "read_bytes_buf: '%s' is %lld bytes, over the %lld-byte cap — "
             "pass read_bytes_buf of [path, max_bytes] (hard ceiling %lld) "
             "to raise it",
             path, len, cap, READ_BYTES_BUF_HARD_CAP);
}

Value* builtin_read_bytes_buf(Value *arg) {
    /* Deterministic argument parse, BEFORE the tape boundary: a bad call
     * shape takes the same path live and under replay, consuming no N
     * record either way. */
    Value *path = arg;
    long long cap = READ_BYTES_BUF_DEFAULT_CAP;
    if (arg && arg->type == VAL_LIST) {
        if (arg->data.list.count < 1) {
            rt_error(EK_TYPE, 0, "read_bytes_buf requires a path: "
                     "read_bytes_buf of path, or read_bytes_buf of [path, max_bytes]");
            return make_null();
        }
        path = arg->data.list.items[0];
        if (arg->data.list.count >= 2) {
            Value *mv = arg->data.list.items[1];
            if (!mv || mv->type != VAL_NUM) {
                rt_error(EK_VALUE, 0, "read_bytes_buf: max_bytes must be a number");
                return make_null();
            }
            if (!(mv->data.num >= 1 &&
                  mv->data.num <= (double)READ_BYTES_BUF_HARD_CAP)) {
                rt_error(EK_VALUE, 0,
                         "read_bytes_buf: max_bytes must be in 1..%lld (got %g)",
                         READ_BYTES_BUF_HARD_CAP, mv ? mv->data.num : 0.0);
                return make_null();
            }
            cap = (long long)mv->data.num;
        }
    }
    if (!path || path->type != VAL_STR) return make_null();

    /* Tape boundary. Success records the VAL_BUFFER; unopenable file
     * records null; the over-cap raise records the observed SIZE as a
     * VAL_NUM N record (unambiguous — no other path records a number) so
     * the identical raise is re-derived under EIGS_REPLAY without
     * touching the live filesystem. */
    if (__builtin_expect(g_replay_enabled, 0)) {
        Value *tv;
        if (trace_replay_take("read_bytes_buf", &tv)) {
            if (tv && tv->type == VAL_NUM) {
                long long len = (long long)tv->data.num;
                val_decref(tv);
                read_bytes_buf_cap_raise(path->data.str, len, cap);
                return make_null();
            }
            return tv;
        }
    }
    FILE *f = fopen(path->data.str, "rb");
    if (!f) TRACE_NONDET_RECORD("read_bytes_buf", make_null());
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) { /* unseekable (pipe/fifo): existing null contract */
        fclose(f);
        TRACE_NONDET_RECORD("read_bytes_buf", make_null());
    }
    if ((long long)len > cap) {
        fclose(f);
        if (__builtin_expect(g_trace_enabled, 0)) {
            Value *sz = make_num((double)len);
            trace_nondet_value("read_bytes_buf", sz);
            val_decref(sz);
        }
        read_bytes_buf_cap_raise(path->data.str, (long long)len, cap);
        return make_null();
    }
    unsigned char *buf = xmalloc(len);
    if (!buf) { fclose(f); TRACE_NONDET_RECORD("read_bytes_buf", make_null()); }
    size_t nread = fread(buf, 1, len, f);
    fclose(f);
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = (int)nread;
    v->data.buffer.data = xcalloc(nread > 0 ? nread : 1, sizeof(double));
    v->refcount = 1;
    for (size_t i = 0; i < nread; i++)
        v->data.buffer.data[i] = (double)buf[i];
    free(buf);
    TRACE_NONDET_RECORD("read_bytes_buf", v);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_read_text(Value *arg) {
    TRACE_NONDET_TAKE("read_text");
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RECORD("read_text", make_str(""));
    FILE *f = fopen(arg->data.str, "r");
    if (!f) TRACE_NONDET_RECORD("read_text", make_str(""));
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 10 * 1024 * 1024) { /* 10 MB cap */
        fclose(f);
        TRACE_NONDET_RECORD("read_text", make_str(""));
    }
    char *buf = xmalloc(len + 1);
    if (!buf) { fclose(f); TRACE_NONDET_RECORD("read_text", make_str("")); }
    size_t read = fread(buf, 1, len, f);
    fclose(f);
    buf[read] = '\0';
    Value *result = make_str(buf);
    free(buf);
    TRACE_NONDET_RECORD("read_text", result);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: read_line ==== */
/* read_line of null — blocking line read from stdin via getline(3):
 * returns the next line without its trailing newline (a "\r\n"
 * terminator is stripped as one unit), or null at EOF. An empty line is
 * "" — distinguishable from EOF. The stream-safe stdin primitive
 * (#558): read_text of "/dev/stdin" sizes with fseek/ftell, which fails
 * on an unseekable fd, so a PIPE silently reads as "" — any CLI meant to
 * sit in a shell pipeline needs this instead. Nondeterministic input →
 * tape-first: TAKE/RECORD like read_bytes, so under EIGS_REPLAY the
 * recorded lines are served and no live stdin read runs. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_read_line(Value *arg) {
    (void)arg;
    TRACE_NONDET_TAKE("read_line");
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) {
        free(line);
        TRACE_NONDET_RECORD("read_line", make_null());
    }
    if (n > 0 && line[n - 1] == '\n') line[--n] = '\0';
    if (n > 0 && line[n - 1] == '\r') line[--n] = '\0';
    Value *v = make_str(line);
    free(line);
    TRACE_NONDET_RECORD("read_line", v);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: write_text ==== */
/* write_text of ["path", text] → 1 on success, 0 on failure. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_write_text(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *text_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR ||
        !text_val || text_val->type != VAL_STR)
        return make_num(0);
    FILE *f = xfopen_write(path_val->data.str, "w");
    if (!f) return make_num(0);
    size_t len = strlen(text_val->data.str);
    size_t written = fwrite(text_val->data.str, 1, len, f);
    int close_ok = (fclose(f) == 0);
    return make_num(written == len && close_ok ? 1 : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: exec_capture ==== */
/* exec_capture of ["cmd", "arg1", ...]               → [exit_code, stdout_text]
 * exec_capture of [["cmd", "arg1", ...], timeout_sec] → same, with timeout
 *
 * Runs a subprocess with fork/exec, captures stdout. No shell.
 * Child stdin is /dev/null. 10 MB output cap.
 *
 * Timeout form: pass a 2-element list where the first element is the
 * command list and the second is the timeout in seconds.
 * On timeout the child is killed and the return is [-2, partial_stdout].
 *
 * Always returns a 2-item list. Returns [-1, ""] on failure. */

/* Issue #148 — subprocess and channel builtins cannot be safely replayed.
 * Forking real children, draining real fds, and waking real channel
 * waiters under EIGS_REPLAY would let a recorded script re-run its
 * side effects against a tape that does not carry the host-side causal
 * structure (child exit codes, channel ordering, syscall errnos).
 * Wrapping these with TRACE_NONDET_TAKE is not enough — the value the
 * tape carries does not pin down the host state — so the contract is
 * "fail loudly" at the boundary. Documented in docs/TRACE.md. */
static int replay_blocks(const char *fn) {
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0,
            "%s: not replayable under EIGS_REPLAY (subprocess/concurrency "
            "boundary; see docs/TRACE.md)", fn);
        return 1;
    }
    return 0;
}

static Value* exec_capture_result(int code, const char *text) {
    Value *result = make_list(2);
    result->data.list.items[0] = make_num(code);
    result->data.list.items[1] = make_str(text);
    result->data.list.count = 2;
    return result;
}

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_exec_capture(Value *arg) {
    if (replay_blocks("exec_capture")) return exec_capture_result(-1, "");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1)
        return exec_capture_result(-1, "");

    /* Detect timeout form: [["cmd", ...], timeout_num] */
    double timeout_sec = -1;
    Value *cmd_list = arg;
    if (arg->data.list.count == 2
        && arg->data.list.items[0] && arg->data.list.items[0]->type == VAL_LIST
        && arg->data.list.items[1] && arg->data.list.items[1]->type == VAL_NUM) {
        cmd_list = arg->data.list.items[0];
        timeout_sec = arg->data.list.items[1]->data.num;
        if (cmd_list->data.list.count < 1)
            return exec_capture_result(-1, "");
    }

    int total = cmd_list->data.list.count;

    /* Build argv array */
    char **argv = xmalloc_array((size_t)total + 1, sizeof(char*));
    if (!argv) return exec_capture_result(-1, "");
    for (int i = 0; i < total; i++) {
        Value *v = cmd_list->data.list.items[i];
        if (!v || v->type != VAL_STR) {
            free(argv);
            return exec_capture_result(-1, "");
        }
        argv[i] = v->data.str;
    }
    argv[total] = NULL;

    /* Create pipe for stdout capture. FD_CLOEXEC on both ends so the pipe
     * doesn't leak into siblings of subsequent exec_capture / proc_spawn
     * children — see issue #149. The child reroutes the write end into
     * stdout via dup2, which clears FD_CLOEXEC on the destination, so the
     * child's stdout still survives execvp. */
    int pipefd[2];
    if (pipe(pipefd) != 0) { free(argv); return exec_capture_result(-1, ""); }
    (void)fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return exec_capture_result(-1, "");
    }

    if (pid == 0) {
        /* Child: redirect stdout to pipe, stdin to /dev/null.
         * Reset SIGPIPE to SIG_DFL — proc_spawn installs a process-wide
         * SIG_IGN once, and that disposition survives fork; without an
         * explicit reset here the captured child silently no-ops on
         * broken-pipe writes instead of dying (issue #150). */
        signal(SIGPIPE, SIG_DFL);
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        execvp(argv[0], argv);
        _exit(127); /* exec failed */
    }

    /* Parent: read from pipe, close write end */
    close(pipefd[1]);
    free(argv);

    /* Compute deadline */
    struct timespec deadline;
    int has_timeout = (timeout_sec >= 0);
    if (has_timeout) {
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += (time_t)timeout_sec;
        deadline.tv_nsec += (long)((timeout_sec - (time_t)timeout_sec) * 1e9);
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000L;
        }
    }

    size_t cap = 4096, len = 0;
    char *buf = xmalloc(cap + 1);
    if (!buf) {
        close(pipefd[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return exec_capture_result(-1, "");
    }

    int timed_out = 0;

    /* Read loop with optional timeout via poll() */
    for (;;) {
        int poll_ms = -1; /* infinite */
        if (has_timeout) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long remaining_ms = (deadline.tv_sec - now.tv_sec) * 1000
                              + (deadline.tv_nsec - now.tv_nsec) / 1000000;
            if (remaining_ms <= 0) { timed_out = 1; break; }
            poll_ms = (int)remaining_ms;
        }

        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        int pr = poll(&pfd, 1, poll_ms);
        if (pr == 0) { timed_out = 1; break; }       /* timeout */
        if (pr < 0) { if (errno == EINTR) continue; break; } /* error */

        ssize_t n = read(pipefd[0], buf + len, cap - len);
        if (n <= 0) break; /* EOF or error */
        len += n;
        if (len >= cap) {
            if (cap >= 10 * 1024 * 1024) break;
            size_t newcap = cap * 2;
            if (newcap > 10 * 1024 * 1024) newcap = 10 * 1024 * 1024;
            char *newbuf = xrealloc(buf, newcap + 1);
            if (!newbuf) break;
            buf = newbuf;
            cap = newcap;
        }
    }
    close(pipefd[0]);
    buf[len] = '\0';

    int exit_code;
    if (timed_out) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        exit_code = -2;
    } else {
        int status = 0;
        waitpid(pid, &status, 0);
        exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    Value *result = exec_capture_result(exit_code, buf);
    free(buf);
    return result;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: proc_spawn / proc_write / proc_read_line / proc_read /
 *               proc_close / proc_wait — streaming subprocess I/O (0.13.0) ====
 *
 * Sibling API to exec_capture for cases where you need to interact with a
 * child process over time instead of waiting for it to terminate.
 *
 *   proc_spawn of ["cmd", "arg1", ...]     → [pid, in_fd, out_fd]  | [-1,-1,-1]
 *   proc_write of [in_fd, "text"]          → bytes_written | -1 on broken pipe
 *   proc_read_line of out_fd               → string (no trailing \n) | null EOF
 *   proc_read of [out_fd, max_bytes]       → string (raw bytes; NUL-truncates) | null EOF
 *   proc_read_buf of [out_fd, max_bytes]   → VAL_BUFFER (binary-safe) | null EOF
 *   proc_close of fd                       → null (idempotent on EBADF)
 *   proc_wait of pid                       → exit_code | -1 on error
 *
 * Pipes are raw read(2)/write(2); no stdio buffering on the parent side.
 * Children using stdio block-buffer their own stdout when not on a tty —
 * wrap unbuffered programs with stdbuf -oL / -o0 if you need line streaming.
 *
 * SIGPIPE is set to SIG_IGN once on first spawn so a writing parent gets
 * EPIPE instead of dying when the child exits. */

static pthread_once_t g_proc_sigpipe_once = PTHREAD_ONCE_INIT;
#if !EIGENSCRIPT_FREESTANDING
static void proc_install_sigpipe_ignore(void) {
    signal(SIGPIPE, SIG_IGN);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

static Value* proc_spawn_fail(void) {
    Value *r = make_list(3);
    r->data.list.items[0] = make_num(-1);
    r->data.list.items[1] = make_num(-1);
    r->data.list.items[2] = make_num(-1);
    r->data.list.count = 3;
    return r;
}

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_spawn(Value *arg) {
    if (replay_blocks("proc_spawn")) return proc_spawn_fail();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1)
        return proc_spawn_fail();

    int total = arg->data.list.count;
    char **argv = xmalloc_array((size_t)total + 1, sizeof(char*));
    if (!argv) return proc_spawn_fail();
    for (int i = 0; i < total; i++) {
        Value *v = arg->data.list.items[i];
        if (!v || v->type != VAL_STR) { free(argv); return proc_spawn_fail(); }
        argv[i] = v->data.str;
    }
    argv[total] = NULL;

    pthread_once(&g_proc_sigpipe_once, proc_install_sigpipe_ignore);

    /* FD_CLOEXEC on both ends of both pipes so subsequent proc_spawn /
     * exec_capture children don't inherit the parent's open pipes (#149).
     * The child re-dup2s these into stdin/stdout, which clears FD_CLOEXEC
     * on the destination, so the child's own stdin/stdout survives exec. */
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) != 0)  { free(argv); return proc_spawn_fail(); }
    if (pipe(out_pipe) != 0) { close(in_pipe[0]); close(in_pipe[1]);
                               free(argv); return proc_spawn_fail(); }
    (void)fcntl(in_pipe[0],  F_SETFD, FD_CLOEXEC);
    (void)fcntl(in_pipe[1],  F_SETFD, FD_CLOEXEC);
    (void)fcntl(out_pipe[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(out_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        free(argv);
        return proc_spawn_fail();
    }

    if (pid == 0) {
        /* Child: stdin from in_pipe read end, stdout to out_pipe write end.
         * Reset SIGPIPE to SIG_DFL — parent ignores SIGPIPE so it sees EPIPE
         * on write, but the child should die silently on broken pipe like
         * a conventional Unix process. */
        signal(SIGPIPE, SIG_DFL);
        dup2(in_pipe[0],  STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        close(in_pipe[0]);  close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        execvp(argv[0], argv);
        _exit(127);
    }

    /* Parent: keep in_pipe[1] (write to child) and out_pipe[0] (read from child). */
    close(in_pipe[0]);
    close(out_pipe[1]);
    free(argv);

    Value *r = make_list(3);
    r->data.list.items[0] = make_num((double)pid);
    r->data.list.items[1] = make_num((double)in_pipe[1]);
    r->data.list.items[2] = make_num((double)out_pipe[0]);
    r->data.list.count = 3;
    return r;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_write(Value *arg) {
    if (replay_blocks("proc_write")) return make_num(-1);
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return make_num(-1);
    Value *fd_v  = arg->data.list.items[0];
    Value *str_v = arg->data.list.items[1];
    if (!fd_v || fd_v->type != VAL_NUM || !str_v || str_v->type != VAL_STR)
        return make_num(-1);
    int fd = (int)fd_v->data.num;
    if (fd < 0) return make_num(-1);
    const char *buf = str_v->data.str;
    size_t total = strlen(buf);
    size_t off = 0;
    while (off < total) {
        ssize_t n = write(fd, buf + off, total - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            /* #159: return partial bytes-written instead of -1 so a
             * caller retrying on short-write doesn't double-send the
             * delivered prefix. -1 only when nothing was written. */
            return make_num(off > 0 ? (double)off : -1);
        }
        off += (size_t)n;
    }
    return make_num((double)off);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_read_line(Value *arg) {
    if (replay_blocks("proc_read_line")) return make_null();
    if (!arg || arg->type != VAL_NUM) return make_null();
    int fd = (int)arg->data.num;
    if (fd < 0) return make_null();
    size_t cap = 256, len = 0;
    char *buf = xmalloc(cap + 1);
    if (!buf) return make_null();
    for (;;) {
        if (len >= cap) {
            size_t newcap = cap * 2;
            char *nb = xrealloc(buf, newcap + 1);
            if (!nb) { free(buf); return make_null(); }
            buf = nb; cap = newcap;
        }
        char c;
        ssize_t n = read(fd, &c, 1);
        if (n == 0) break;        /* EOF */
        if (n < 0) {
            if (errno == EINTR) continue;
            /* #159: mid-stream read error — return the partial line
             * we already buffered (mirrors the EOF-with-partial path
             * just below). null is reserved for "EOF, nothing read". */
            if (len == 0) { free(buf); return make_null(); }
            break;
        }
        if (c == '\n') {
            buf[len] = '\0';
            Value *s = make_str(buf);
            free(buf);
            return s;
        }
        buf[len++] = c;
    }
    if (len == 0) { free(buf); return make_null(); }
    buf[len] = '\0';
    Value *s = make_str(buf);
    free(buf);
    return s;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_read(Value *arg) {
    if (replay_blocks("proc_read")) return make_null();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return make_null();
    Value *fd_v  = arg->data.list.items[0];
    Value *max_v = arg->data.list.items[1];
    if (!fd_v || fd_v->type != VAL_NUM || !max_v || max_v->type != VAL_NUM)
        return make_null();
    int fd = (int)fd_v->data.num;
    int max = (int)max_v->data.num;
    if (fd < 0 || max <= 0) return make_null();
    if (max > 10 * 1024 * 1024) max = 10 * 1024 * 1024;
    char *buf = xmalloc((size_t)max + 1);
    if (!buf) return make_null();
    ssize_t n;
    for (;;) {
        n = read(fd, buf, (size_t)max);
        if (n >= 0) break;
        if (errno == EINTR) continue;
        free(buf);
        return make_null();
    }
    if (n == 0) { free(buf); return make_null(); }
    buf[n] = '\0';
    return make_str_owned(buf);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* #159: binary-safe variant of proc_read. Returns a VAL_BUFFER (no
 * NUL-truncation), null on EOF. Same 10 MB cap as proc_read. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_read_buf(Value *arg) {
    if (replay_blocks("proc_read_buf")) return make_null();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return make_null();
    Value *fd_v  = arg->data.list.items[0];
    Value *max_v = arg->data.list.items[1];
    if (!fd_v || fd_v->type != VAL_NUM || !max_v || max_v->type != VAL_NUM)
        return make_null();
    int fd = (int)fd_v->data.num;
    int max = (int)max_v->data.num;
    if (fd < 0 || max <= 0) return make_null();
    if (max > 10 * 1024 * 1024) max = 10 * 1024 * 1024;
    unsigned char *buf = xmalloc((size_t)max);
    if (!buf) return make_null();
    ssize_t n;
    for (;;) {
        n = read(fd, buf, (size_t)max);
        if (n >= 0) break;
        if (errno == EINTR) continue;
        free(buf);
        return make_null();
    }
    if (n == 0) { free(buf); return make_null(); }
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = (int)n;
    v->data.buffer.data = xcalloc((size_t)n, sizeof(double));
    v->refcount = 1;
    for (ssize_t i = 0; i < n; i++)
        v->data.buffer.data[i] = (double)buf[i];
    free(buf);
    return v;
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_close(Value *arg) {
    if (replay_blocks("proc_close")) return make_null();
    if (!arg || arg->type != VAL_NUM) return make_null();
    int fd = (int)arg->data.num;
    if (fd >= 0) close(fd);
    return make_null();
}
#endif /* !EIGENSCRIPT_FREESTANDING */

#if !EIGENSCRIPT_FREESTANDING
Value* builtin_proc_wait(Value *arg) {
    if (replay_blocks("proc_wait")) return make_num(-1);
    if (!arg || arg->type != VAL_NUM) return make_num(-1);
    pid_t pid = (pid_t)arg->data.num;
    if (pid <= 0) return make_num(-1);
    int status = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, 0);
        if (r == pid) break;
        if (r < 0 && errno == EINTR) continue;
        return make_num(-1);
    }
    int code = WIFEXITED(status) ? WEXITSTATUS(status)
             : WIFSIGNALED(status) ? (128 + WTERMSIG(status))
             : -1;
    return make_num((double)code);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: arena_mark ==== */
/* arena_mark of null — saves current arena position. All Values allocated
 * after this point will be reclaimed on arena_reset. Call before a training step. */
Value* builtin_arena_mark(Value *arg) {
    (void)arg;
    arena_mark_pos();
    return make_null();
}

/* ==== BUILTIN: arena_reset ==== */
/* arena_reset of null — reclaims all Values allocated since the last arena_mark.
 * Call after a training step, when gradient tensors and intermediates are no longer needed. */
Value* builtin_arena_reset(Value *arg) {
    (void)arg;
    arena_reset_to_mark();
    return make_null();
}

/* ==== BUILTIN: arena_stats ==== */
/* arena_stats of null — returns total bytes allocated through the arena. */
Value* builtin_arena_stats(Value *arg) {
    (void)arg;
    return make_num((double)g_arena.total_allocated);
}

/* Free a TokenList's malloc'd storage (token array and str_vals) */
void free_tokenlist(TokenList *tl) {
    if (!tl->tokens) return;
    for (int i = 0; i < tl->count; i++) {
        if (tl->tokens[i].str_val) {
            free(tl->tokens[i].str_val);
            tl->tokens[i].str_val = NULL;
        }
    }
    free(tl->tokens);
    tl->tokens = NULL;
    tl->count = 0;
}

/* ==== BUILTIN: tokenize_ids ==== */
/* tokenize_ids of string → list of token type IDs (integers).
 * Exposes the runtime's own tokenizer to .eigs code.
 * The learner sees its world the way the runtime does. */
Value* builtin_tokenize_ids(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_list(0);

    TokenList tl = tokenize(src);
    Value *result = make_list(tl.count);
    for (int i = 0; i < tl.count; i++) {
        list_append_owned(result, make_num((double)tl.tokens[i].type));
    }
    free_tokenlist(&tl);
    return result;
}

/* ==== BUILTIN: tokenize_with_names ==== */
/* tokenize_with_names of string → list of [type_id, name_str] pairs.
 * Like tokenize_ids, but preserves the identifier name (for IDENT), the
 * string content (for STR), and the number as a string (for NUM). Other
 * token types get an empty string. Used by corpus builders that need
 * per-identifier information for vocabulary enrichment. */
Value* builtin_tokenize_with_names(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_list(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_list(0);

    TokenList tl = tokenize(src);
    Value *result = make_list(tl.count);
    char numbuf[64];
    for (int i = 0; i < tl.count; i++) {
        Value *pair = make_list(2);
        list_append_owned(pair, make_num((double)tl.tokens[i].type));
        const char *name = "";
        if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val) {
            name = tl.tokens[i].str_val;
        } else if (tl.tokens[i].type == TOK_STR && tl.tokens[i].str_val) {
            name = tl.tokens[i].str_val;
        } else if (tl.tokens[i].type == TOK_NUM) {
            double d = tl.tokens[i].num_val;
            if (d == (double)(long)d) {
                snprintf(numbuf, sizeof(numbuf), "%ld", (long)d);
            } else {
                snprintf(numbuf, sizeof(numbuf), "%g", d);
            }
            name = numbuf;
        }
        list_append_owned(pair, make_str(name)); /* make_str copies the string */
        list_append_owned(result, pair);  /* adopt the freshly-built pair */
    }
    free_tokenlist(&tl);
    return result;
}

/* ==== BUILTIN: token_name ==== */
/* token_name of id → string name of token type (for display) */
Value* builtin_token_name(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_str("?");
    int id = (int)arg->data.num;
    static const char *names[] = {
        "NUM", "STR", "IDENT",
        "IS", "OF", "DEFINE", "AS",
        "IF", "ELSE", "ELIF", "LOOP", "WHILE",
        "RETURN", "AND", "OR", "NOT",
        "FOR", "IN", "NULL",
        "WHAT", "WHO", "WHEN", "WHERE", "WHY", "HOW",
        "CONVERGED", "STABLE", "IMPROVING", "OSCILLATING", "DIVERGING", "EQUILIBRIUM",
        "TRY", "CATCH", "BREAK", "CONTINUE", "IMPORT",
        "MATCH", "CASE",
        "UNOBSERVED",
        "LOCAL",
        "+", "-", "*", "/", "%",
        "<", ">", "<=", ">=", "==", "!=", "=",
        "(", ")", "[", "]",
        ",", ":", ".",
        "{", "}",
        "|>", "=>",
        "&", "|", "^", "<<", ">>", "~",
        "+=", "-=", "*=", "/=", "%=",
        "&=", "|=", "^=", "<<=", ">>=",
        "NEWLINE", "INDENT", "DEDENT",
        "EOF"
    };
    if (id >= 0 && id < (int)(sizeof(names) / sizeof(names[0]))) return make_str(names[id]);
    return make_str("?");
}

/* ==== BUILTIN: random_hex ==== */
/* random_hex of n → string of n random hex characters from /dev/urandom.
 * Capability builtin: provides randomness so .eigs libraries can generate tokens. */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_random_hex(Value *arg) {
    int n = (arg && arg->type == VAL_NUM) ? (int)arg->data.num : 0;
    if (n <= 0 || n > 256) TRACE_NONDET_RET("random_hex", make_str(""));
    int bytes_needed = (n + 1) / 2;
    unsigned char raw[128];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (!urand) TRACE_NONDET_RET("random_hex", make_str(""));
    size_t got = fread(raw, 1, bytes_needed, urand);
    fclose(urand);
    if ((int)got < bytes_needed) TRACE_NONDET_RET("random_hex", make_str(""));
    char hex[257];
    for (int i = 0; i < bytes_needed && i * 2 < n; i++)
        snprintf(hex + i * 2, 3, "%02x", raw[i]);
    hex[n] = '\0';
    TRACE_NONDET_RET("random_hex", make_str(hex));
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ==== BUILTIN: state_at ==== */
/* state_at(line) → dict of every tracked binding's value at <line>, or
 * null if the line argument isn't a number. Phase 4 backward-state query;
 * the dict snapshot it returns is independent of subsequent program state. */
Value* builtin_state_at(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    Value *d = trace_state_at((int)arg->data.num);
    return d ? d : make_null();
}

/* ==== BUILTIN: secure_equals ==== */
/* secure_equals of [a, b] → 1 if the two strings are equal, else 0.
 * Constant-time in the *contents*: it always scans the full length and folds
 * every byte into the result, so it does not short-circuit on the first
 * differing byte the way `==`/strcmp do. Use it for comparing secrets
 * (tokens, password hashes) to avoid leaking how many leading bytes matched
 * via timing. (Length is not treated as secret — it is folded in but the
 * loop runs over the longer operand.) */
Value* builtin_secure_equals(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || !b || a->type != VAL_STR || b->type != VAL_STR) return make_num(0);
    const char *sa = a->data.str ? a->data.str : "";
    const char *sb = b->data.str ? b->data.str : "";
    size_t la = strlen(sa), lb = strlen(sb);
    size_t n = la > lb ? la : lb;
    /* volatile accumulator so the compiler cannot turn this into an early-out */
    volatile unsigned char diff = (unsigned char)(la ^ lb);
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = i < la ? (unsigned char)sa[i] : 0;
        unsigned char cb = i < lb ? (unsigned char)sb[i] : 0;
        diff |= (unsigned char)(ca ^ cb);
    }
    return make_num(diff == 0 ? 1.0 : 0.0);
}

/* ==== BUILTIN: http_request_headers ==== */
/* http_request_headers of null → raw request headers as string.
 * Only meaningful during HTTP request handling. */

/* ==== BUILTIN: chr ==== */
/* chr of n → single-character string from ASCII code */
/* chr of n → one-byte string, the byte-writing inverse of `ord` (which reads
 * bytes 0..255). Strings are bytes (#416): chr writes a BYTE, not a Unicode
 * codepoint — codepoint→UTF-8 encoding is lib/utf8.eigs `utf8_encode`.
 * n must be an integer in 1..255; 0 raises because strings are NUL-terminated
 * and cannot hold a NUL byte (keep NUL-bearing binary in a buffer). Anything
 * else raises too — the old silent empty-string return for >127 hid every
 * high-byte construction bug (#435). */
Value* builtin_chr(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "chr requires a number");
        return make_null();
    }
    double num = arg->data.num;
    if (num != (double)(long long)num || num < 1 || num > 255) {
        if (num == 0)
            rt_error(EK_VALUE, 0, "chr of 0: strings are NUL-terminated and cannot hold a NUL byte (use a buffer for binary with NULs)");
        else
            rt_error(EK_VALUE, 0, "chr requires an integer byte in 1..255 (got %g); for a codepoint use utf8_encode (lib/utf8.eigs)", num);
        return make_null();
    }
    char buf[2] = { (char)(int)num, '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: hex ==== */
/* hex of n → uppercase hex string, minimal digits ("0" for 0).
 * hex of [n, nibbles] → zero-padded to at least `nibbles` digits.
 * n must be a non-negative integer (exact up to 2^53); anything else
 * raises — hex of a fraction or a negative has no single right answer
 * and silently picking one is the #316/#368 tolerance class.
 * Demanded by the emulator repos (DMG GAP-DMG-010): addresses/opcodes/
 * registers all want hex diagnostics and every consumer hand-rolled it. */
Value* builtin_hex(Value *arg) {
    double num;
    long long width = 0;
    if (arg && arg->type == VAL_NUM) {
        num = arg->data.num;
    } else if (arg && arg->type == VAL_LIST && arg->data.list.count >= 2 &&
               arg->data.list.items[0] && arg->data.list.items[0]->type == VAL_NUM &&
               arg->data.list.items[1] && arg->data.list.items[1]->type == VAL_NUM) {
        num = arg->data.list.items[0]->data.num;
        width = (long long)arg->data.list.items[1]->data.num;
    } else {
        rt_error(EK_TYPE, 0, "hex requires a number or [number, nibbles]");
        return make_null();
    }
    if (num < 0 || num != (double)(long long)num || num > 9007199254740992.0) {
        rt_error(EK_VALUE, 0, "hex requires a non-negative integer (got %g)", num);
        return make_null();
    }
    if (width < 0) width = 0;
    if (width > 16) width = 16;
    char buf[24];
    snprintf(buf, sizeof(buf), "%0*llX", (int)width, (unsigned long long)num);
    return make_str(buf);
}

/* ==== BUILTIN: ord ==== */
/* ord of s → first byte of s as integer (0..255), or -1 on empty / non-string */
Value* builtin_ord(Value *arg) {
    if (!arg || arg->type != VAL_STR || !arg->data.str || arg->data.str[0] == '\0')
        return make_num(-1);
    return make_num((double)(unsigned char)arg->data.str[0]);
}

/* ==== BUILTIN: try_parse ==== */
/* try_parse of string → 1 if valid EigenScript syntax, 0 if not.
 * Tokenizes and parses without executing. Suppresses stderr. */
Value* builtin_try_parse(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_num(0);

    /* Suppress stderr during parse attempt (needs fd plumbing — parse
     * diagnostics print unsuppressed in the freestanding profile) */
#if !EIGENSCRIPT_FREESTANDING
    int saved_stderr = dup(STDERR_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) { dup2(devnull, STDERR_FILENO); close(devnull); }
#endif

    /* Reset parse error counter before parsing */
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);

    int errors = g_parse_errors;
    g_parse_errors = saved_errors; /* restore for caller */

    /* Restore stderr */
#if !EIGENSCRIPT_FREESTANDING
    if (saved_stderr >= 0) { dup2(saved_stderr, STDERR_FILENO); close(saved_stderr); }
#endif

    /* Valid only if: non-null AST, at least one statement, AND no parse errors */
    int valid = (ast != NULL && ast->type == AST_PROGRAM
                 && ast->data.program.count > 0 && errors == 0) ? 1 : 0;
    free_tokenlist(&tl);
    /* make_node zero-initializes children, so free_ast walks partial
     * parses safely (NULL children are no-ops). */
    free_ast(ast);
    return make_num(valid);
}

/* ==== BUILTIN: eval ==== */
/* eval of code_string — execute EigenScript code and return result */
Value* builtin_eval(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    const char *src = arg->data.str;
    if (!src || !src[0]) return make_null();

    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(src);
    ASTNode *ast = parse(&tl);

    if (g_parse_errors > 0 || !ast) {
        g_parse_errors = saved_errors;
        free_tokenlist(&tl);
        /* parse always returns an AST_PROGRAM node even on partial parses;
         * free it here so error paths don't leak (free_ast walks NULL
         * children safely — see parse_check for the same pattern). */
        free_ast(ast);
        rt_error(EK_PARSE, 0, "eval: parse error in code string");
        return make_null();
    }
    /* Keep the zeroed counter through COMPILE too — compile-stage
     * diagnostics ('break' outside a loop #337, un-encodable jumps) must
     * fail the eval instead of executing a placeholder chunk. */
    Env *target = g_builtin_call_env ? g_builtin_call_env : g_global_env;
    EigsChunk *ev_chunk = compile_ast(ast, target, src);
    if (g_parse_errors > 0) {
        g_parse_errors = saved_errors;
        chunk_free(ev_chunk);
        free_tokenlist(&tl);
        free_ast(ast);
        rt_error(EK_PARSE, 0, "eval: compile error in code string");
        return make_null();
    }
    g_parse_errors = saved_errors;
    Value *result = vm_execute(ev_chunk, target);
    /* Chunks are refcounted: drop the creator ref; fn values keep their
     * nested chunks alive. */
    chunk_free(ev_chunk);
    free_tokenlist(&tl);
    /* Fn bodies are cloned or compiled into chunks — AST is safe to free. */
    free_ast(ast);
    return result ? result : make_null();
}

/* ==== BUILTIN: vm_run_bytecode ==== */
/* Build an EigsChunk from a descriptor list, recursively for nested functions:
 *   [ code, constants, functions?, param_count?, name?, local_names? ]
 *   - code        : list of byte ints (opcodes + little-endian 16-bit operands)
 *   - constants   : constant pool (numbers/strings; strings double as
 *                   GET_NAME/SET_NAME names)
 *   - functions   : (optional) list of descriptors for nested function chunks,
 *                   referenced by OP_CLOSURE [fn_idx]
 *   - param_count : (optional) number of leading local slots that are params
 *   - name        : (optional) chunk/function name
 *   - local_names : (optional) names for local slots in slot order; the count
 *                   sizes the call frame, and the first param_count are the
 *                   parameter names OP_CLOSURE binds.
 * The 2-element form [code, constants] still works (a flat module chunk). */
static EigsChunk *vm_build_chunk_desc(Value *desc) {
    if (!desc || desc->type != VAL_LIST || desc->data.list.count < 2) return NULL;
    Value **d = desc->data.list.items;
    int n = desc->data.list.count;
    Value *code = d[0], *consts = d[1];
    if (!code || code->type != VAL_LIST || !consts || consts->type != VAL_LIST)
        return NULL;

    const char *name = (n >= 5 && d[4] && d[4]->type == VAL_STR) ? d[4]->data.str
                                                                 : "<bootstrap>";
    EigsChunk *chunk = chunk_new(name);

    for (int i = 0; i < code->data.list.count; i++) {
        Value *b = code->data.list.items[i];
        int byte = (b && b->type == VAL_NUM) ? ((int)b->data.num & 0xFF) : 0;
        chunk_emit(chunk, (uint8_t)byte, 1);
    }
    for (int i = 0; i < consts->data.list.count; i++)
        if (consts->data.list.items[i])
            chunk_add_constant(chunk, consts->data.list.items[i]);

    /* nested function chunks (creator ref transfers into functions[]). A
     * nested descriptor that fails to build/verify invalidates the whole
     * chunk — silently dropping it would shift the indices OP_CLOSURE refers
     * to (wrong function, or out of range). */
    if (n >= 3 && d[2] && d[2]->type == VAL_LIST) {
        for (int i = 0; i < d[2]->data.list.count; i++) {
            EigsChunk *fn = vm_build_chunk_desc(d[2]->data.list.items[i]);
            if (!fn) { chunk_free(chunk); return NULL; }
            chunk_add_function(chunk, fn);
        }
    }

    int param_count = (n >= 4 && d[3] && d[3]->type == VAL_NUM)
                      ? (int)d[3]->data.num : 0;
    chunk->param_count = param_count;
    chunk->first_default = param_count;        /* no defaults */

    /* local-slot names; local_count sizes the call frame (max with param_count) */
    if (n >= 6 && d[5] && d[5]->type == VAL_LIST && d[5]->data.list.count > 0) {
        int lc = d[5]->data.list.count;
        chunk->local_names = xcalloc(lc, sizeof(char *));
        for (int i = 0; i < lc; i++) {
            Value *nm = d[5]->data.list.items[i];
            chunk->local_names[i] = strdup((nm && nm->type == VAL_STR) ? nm->data.str : "");
        }
        chunk->local_count = lc;
    }
    /* The VM runs on its global value stack (VM_STACK_MAX), so max_stack is a
     * hint only. */
    chunk->max_stack = 64;

    /* Reject untrusted bytecode with out-of-range constant/function/jump
     * operands before it reaches the VM (which trusts operand indices). */
    if (!chunk_verify(chunk)) { chunk_free(chunk); return NULL; }
    return chunk;
}

/* vm_run_bytecode of <chunk-descriptor> — assemble a chunk (and its nested
 * function chunks) from EigenScript values and run it on the C VM. The
 * self-hosting bootstrap bridge: a compiler written in EigenScript emits
 * bytecode as data, and this hands it to the same vm_execute the C compiler's
 * output runs through — reusing the bytecode VM and its JIT. The caller is
 * responsible for a well-formed chunk ending in OP_RETURN. */
Value* builtin_vm_run_bytecode(Value *arg) {
    EigsChunk *chunk = vm_build_chunk_desc(arg);
    if (!chunk) return make_null();
    Env *target = g_builtin_call_env ? g_builtin_call_env : g_global_env;
    Value *result = vm_execute(chunk, target);
    chunk_free(chunk);
    return result ? result : make_null();
}

/* Stub bound (in the sandbox env) over every dangerous builtin name; calling it
 * raises a catchable error so untrusted generated code can't touch the outside. */
Value* builtin_sandbox_blocked(Value *arg) {
    (void)arg;
    rt_error(EK_SANDBOX, 0, "blocked in sandbox");
    return make_null();
}

/* Fail-CLOSED sandbox allowlist. Only these genuinely pure-compute builtins are
 * visible inside a sandbox_run; EVERY other name in the global env is shadowed
 * by the blocked stub. A blocklist (the previous design) was fail-OPEN — every
 * builtin was reachable unless someone remembered to deny it, so each new
 * builtin (and ones nobody flagged: set_observer_thresholds, which writes the
 * process-global observer thresholds; the screen_* terminal ops; the channel
 * ops; exit, which kills the host) silently widened the attack surface. With an
 * allowlist a new builtin is SAFE by default; a missing entry only costs a
 * sandboxed program some functionality, never host safety.
 *
 * Membership rule: the builtin reads/derives values, touches only the arguments
 * it is handed, mutates NO process-global state, cannot reach outside the VM
 * (no fs/proc/net/db/terminal/env), does not execute code, spawn, or block.
 * When unsure, leave it out (fail closed). tests/test_sandbox_allow.eigs guards
 * that every entry is a real builtin and that the known-dangerous stay out. */
static const char *SANDBOX_ALLOW[] = {
    /* scalar + tensor math (pure numeric) */
    "abs", "acos", "add", "asin", "atan", "ceil", "cos", "divide", "dot",
    "exp", "floor", "log", "max", "mean", "min", "multiply", "negative",
    "norm", "num", "pi", "pow", "round", "sign_extend", "sin", "sqrt",
    "subtract", "sum", "tan", "gather", "matmul", "reshape", "shape", "zeros",
    "zeros_like", "fill", "leaky_relu", "relu", "softmax", "log_softmax",
    "sgd_update", "sgd_update_cols", "sgd_update_rows", "numerical_grad",
    "numerical_grad_cols", "numerical_grad_rows",
    /* bit ops */
    "bit_and", "bit_not", "bit_or", "bit_shl", "bit_shr", "bit_xor",
    /* list / sequence (operate on the value handed in) */
    "append", "concat", "contains", "copy_into", "get_at", "index_of", "len",
    "list_remove_at", "list_truncate", "set_at", "sort", "sort_by", "range",
    /* dict */
    "dict_set", "dict_remove", "has_key", "keys", "values",
    /* string + regex (pure) */
    "char_at", "chr", "ends_with", "hex", "join", "ord", "split", "starts_with",
    "str", "str_lower", "str_replace", "str_upper", "substr", "trim",
    "regex_find", "regex_match", "regex_replace",
    /* buffers + text builders (in-memory only; allocators charge #292) */
    "buffer", "buf_copy", "buf_deinterleave", "buf_dot", "buf_fill",
    "buf_from_list", "buf_from_pcm16le", "buf_get", "buf_len", "buf_mix",
    "buf_peak", "buf_resample_linear", "buf_scale_range", "buf_set",
    "buf_to_pcm16le",
    "str_from_bytes", "text_builder_new", "text_builder_append",
    "text_builder_append_line", "text_builder_extend", "text_builder_clear",
    "text_builder_to_string", "text_builder_part_count",
    /* json (string <-> value, pure) */
    "json_build", "json_decode", "json_encode", "json_path", "json_raw",
    /* path string manipulation (no fs access) */
    "path_base", "path_dir", "path_ext", "path_join",
    /* type / value utilities */
    "type", "coalesce", "num_copy", "secure_equals",
    /* observer READS — touch only the sandbox's own values, never globals
     * (set_observer_thresholds / record_history are intentionally NOT here) */
    "observe", "report", "get_observer_thresholds", "state_at", "classify",
    /* tokenizer / parser introspection (pure over strings) */
    "tokenize_ids", "tokenize_with_names", "token_name", "scan_ints",
    "scan_int_tokens", "scan_tokens", "try_parse",
    /* spatial queries (pure over lists) */
    "nearest_in_range", "nearest_in_range_all",
    /* control / output */
    "print", "assert", "throw", "dispatch",
    NULL
};

static int sandbox_name_allowed(const char *name) {
    if (!name) return 0;
    for (int i = 0; SANDBOX_ALLOW[i]; i++)
        if (strcmp(name, SANDBOX_ALLOW[i]) == 0) return 1;
    return 0;
}

/* sandbox_run of [descriptor, max_iterations?] — run an EigenScript-assembled
 * chunk (same descriptor as vm_run_bytecode) under two safety bounds: dangerous
 * builtins are shadowed by a blocked stub, and loops are capped at
 * max_iterations (default 1,000,000) so runaway code can't hang. Runtime errors
 * are caught (not propagated). Returns {"ok": 1/0, "result": value} — the graded
 * "does it run?" rung for a self-hosted compiler validating generated code. */
Value* builtin_sandbox_run(Value *arg) {
    Value *desc = (arg && arg->type == VAL_LIST && arg->data.list.count >= 1)
                  ? arg->data.list.items[0] : arg;
    int max_iter = 1000000;
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 2 &&
        arg->data.list.items[1] && arg->data.list.items[1]->type == VAL_NUM)
        max_iter = (int)arg->data.list.items[1]->data.num;
    /* #292: optional max_bytes (3rd element) — the allocation budget for this
     * run. Default 256 MiB: ample for the short generated snippets grade()
     * runs, small enough that even a few of them can't thrash a 4 GB box. */
    size_t max_bytes = (size_t)256 * 1024 * 1024;
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 3 &&
        arg->data.list.items[2] && arg->data.list.items[2]->type == VAL_NUM &&
        arg->data.list.items[2]->data.num > 0)
        max_bytes = (size_t)arg->data.list.items[2]->data.num;

    EigsChunk *chunk = vm_build_chunk_desc(desc);
    Value *out = make_dict(2);
    if (!chunk) {
        Value *zero = make_num(0);
        dict_set(out, "ok", zero);   /* dict_set increfs; drop our ref */
        val_decref(zero);
        /* #406: surface the build failure structurally — a descriptor
         * that doesn't verify is a bad argument value, same shape as a
         * runtime failure's error field. */
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str(err_kind_name(EK_VALUE)));
        dict_set_owned(ev, "message", make_str("invalid chunk descriptor"));
        dict_set_owned(ev, "line", make_num(0));
        dict_set_owned(out, "error", ev);
        return out;
    }

    /* Restricted env: parent is the real global so the allowed builtins still
     * resolve, but every global name NOT on the allowlist — every other
     * builtin, the http_/db_/model_ extension surface, and any host module
     * global — is shadowed by the blocked stub. Fail-closed: a name we never
     * classified is denied by default, not exposed. */
    Env *sbox = env_new(g_global_env);
    Value *stub = make_builtin(builtin_sandbox_blocked);
    for (int i = 0; i < g_global_env->count; i++) {
        const char *nm = g_global_env->names[i];
        if (nm && !sandbox_name_allowed(nm))
            env_set_local(sbox, nm, stub);
    }
    val_decref(stub);

    int saved_max = g_sandbox_loop_max;
    int saved_iters = g_loop_iterations;
    g_sandbox_loop_max = max_iter > 0 ? max_iter : 1000000;
    g_loop_iterations = 0;
    /* #292: arm the allocation budget. Save/restore so nested sandbox_run (or a
     * sandbox_run invoked from already-budgeted code) composes correctly. */
    int    saved_sb_active = g_sandbox_active;
    size_t saved_sb_used   = g_sandbox_bytes_used;
    size_t saved_sb_max    = g_sandbox_byte_max;
    g_sandbox_active     = 1;
    g_sandbox_bytes_used = 0;
    g_sandbox_byte_max   = max_bytes;

    Value *result = vm_execute(chunk, sbox);

    int ok = g_has_error ? 0 : 1;
    if (g_has_error) {
        /* #406: surface the failure structurally on the result dict so the
         * graded ladder can discriminate (sandbox denial vs type error vs
         * parse) without re-running outside the sandbox. Same shape as a
         * catch binding: {kind, message, line}. */
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str(err_kind_name((ErrKind)g_error_kind)));
        dict_set_owned(ev, "message", make_str(g_error_raw));
        dict_set_owned(ev, "line", make_num((double)g_error_line));
        dict_set_owned(out, "error", ev);
        g_has_error = 0;
        eigs_clear_error_value();
    }

    g_sandbox_loop_max = saved_max;
    g_loop_iterations = saved_iters;
    g_sandbox_active     = saved_sb_active;
    g_sandbox_bytes_used = saved_sb_used;
    g_sandbox_byte_max   = saved_sb_max;

    chunk_free(chunk);
    env_decref(sbox);

    Value *okv = make_num((double)ok);
    dict_set(out, "ok", okv);   /* dict_set increfs; drop our ref */
    val_decref(okv);
    if (result) { dict_set(out, "result", result); val_decref(result); }
    return out;
}

/* record_history of flag — enable (nonzero) or disable (0) per-assignment
 * history recording, which the temporal queries read: `prev of x` and
 * `<kw> is x at <line>` (value history via g_trace_hist) plus the observer-state
 * forms `where/why/how is x at <line>` (entropy/dH history via g_trace_obs_hist).
 * Both are enabled together. The C compiler turns these on automatically when it
 * compiles a temporal query; a self-hosted compiler (whose output runs via
 * vm_run_bytecode) calls this to do the same. Returns the previous setting. */
Value* builtin_record_history(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "record_history requires a number flag (nonzero=on, 0=off), got %s",
                      arg ? val_type_name(arg->type) : "null");
        return make_null();
    }
    int prev = g_trace_hist;
    int on = (arg->data.num != 0.0) ? 1 : 0;
    g_trace_hist = on;
    g_trace_obs_hist = on;
    return make_num((double)prev);
}

/* ==== BUILTIN: tensor_save ==== */
/* tensor_save of [tensor, path] — save 1D or 2D list to binary file.
 * Format: [uint32 ndim][uint32 rows][uint32 cols][uint32 flags]
 *         [float64 × N: data]
 *         [float64 × N × 5: observer state (entropy, dH, last_entropy, obs_age, prev_dH)]
 * flags bit 0 = has observer state */
/* ==== BUILTIN: copy_into ==== */
/* copy_into of [dest, dest_offset, src]
 * Copies elements from src into dest starting at dest_offset.
 * Both must be 1D lists. Mutates dest in-place, returns dest. */
Value* builtin_copy_into(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *dest = arg->data.list.items[0];
    int offset = (arg->data.list.items[1]->type == VAL_NUM) ? (int)arg->data.list.items[1]->data.num : 0;
    Value *src = arg->data.list.items[2];
    if (!dest || dest->type != VAL_LIST || !src || src->type != VAL_LIST) return make_null();
    if (offset < 0) return make_null();
    for (int i = 0; i < src->data.list.count && offset + i < dest->data.list.count; i++) {
        val_incref(src->data.list.items[i]);
        val_decref(dest->data.list.items[offset + i]);
        dest->data.list.items[offset + i] = src->data.list.items[i];
    }
    return dest;
}

/* ==== BUILTIN: num_copy ==== */
/* num_copy of val → fresh heap-allocated copy of a numeric Value.
 * Use to extract a scalar from arena before arena_reset. */
Value* builtin_num_copy(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_null();
    return make_num_permanent(arg->data.num);
}

/* ==== BUILTIN: concat ==== */
/* concat of [list_a, list_b] → new 1D list with a's elements then b's */
Value* builtin_concat(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || a->type != VAL_LIST || !b || b->type != VAL_LIST) return make_null();
    int total = a->data.list.count + b->data.list.count;
    /* #292: charge the new slots — `result is concat of [result, more]` in a loop
     * grows quadratically and would otherwise aggregate past the budget. */
    if (!sandbox_charge((size_t)total * sizeof(Value *))) return make_null();
    Value *result = make_list(total);
    for (int i = 0; i < a->data.list.count; i++)
        list_append(result, a->data.list.items[i]);
    for (int i = 0; i < b->data.list.count; i++)
        list_append(result, b->data.list.items[i]);
    return result;
}

/* ==== BUILTIN: range ==== */
/* range of n → [0, 1, ..., n-1]
 * range of [start, end] → [start, start+1, ..., end-1]
 * range of [start, end, step] → [start, start+step, ...] while < end (or > end if step < 0) */
Value* builtin_range(Value *arg) {
    int start = 0, end = 0, step = 1;

    if (!arg) return make_list(0);

    if (arg->type == VAL_NUM) {
        /* range of n */
        end = (int)arg->data.num;
    } else if (arg->type == VAL_LIST) {
        int argc = arg->data.list.count;
        /* #497: every provided bound must be numeric. A non-number used to
         * be silently treated as 0 (or fold the whole call to []) — a
         * silent-wrong loop count. */
        for (int i = 0; i < argc && i < 3; i++) {
            if (arg->data.list.items[i]->type != VAL_NUM) {
                rt_error(EK_TYPE, 0,
                    "range: argument %d must be a number, got %s", i,
                    val_type_name(arg->data.list.items[i]->type));
                return make_list(0);
            }
        }
        if (argc >= 1)
            start = (int)arg->data.list.items[0]->data.num;
        if (argc >= 2)
            end = (int)arg->data.list.items[1]->data.num;
        else
            { end = start; start = 0; } /* single-element list: treat as range of n */
        if (argc >= 3) {
            step = (int)arg->data.list.items[2]->data.num;
            /* The Euler-like update that feeds step can never produce
             * exactly zero — it trades the zero singularity for infinity.
             * This bound catches the infinity side: a step that would
             * generate an unbounded sequence gets clamped to 1.
             * Division by step below is therefore always safe. */
            if (step == 0) step = 1; /* cppcheck-suppress zerodivcond */
        }
    } else {
        /* #497: a non-num, non-list argument (e.g. a string) is a type
         * error, not a silent empty range. */
        rt_error(EK_TYPE, 0,
            "range requires a number or a list of numbers, got %s",
            val_type_name(arg->type));
        return make_list(0);
    }

    /* Cap at 1M elements to prevent accidental OOM.
     * step is guaranteed non-zero by the Euler invariant bound above. */
    int count;
    if (step > 0) {
        count = (end - start + step - 1) / step;
    } else {
        count = (start - end - step - 1) / (-step); // cppcheck-suppress zerodivcond
    }
    if (count < 0) count = 0;
    /* #498: the 1M cap used to size only the prealloc — the loop below still
     * ran to the original `end`, growing the list past the cap (unbounded
     * memory, OOM). Raise loudly instead of silently building a giant list. */
    if (count > 1000000) {
        rt_error(EK_LIMIT, 0,
            "range: too many elements (%d, max 1000000)", count);
        return make_list(0);
    }
    /* #292: range builds `count` fresh number Values — charge the sandbox budget
     * so a range-in-a-loop can't aggregate past it. */
    if (!sandbox_charge((size_t)count * (sizeof(Value) + sizeof(Value *)))) return make_list(0);

    Value *result = make_list(count);
    if (step > 0) {
        for (int i = start; i < end; i += step) {
            Value *v = make_num((double)i);
            list_append(result, v);
            val_decref(v);
        }
    } else {
        for (int i = start; i > end; i += step) {
            Value *v = make_num((double)i);
            list_append(result, v);
            val_decref(v);
        }
    }
    return result;
}

/* fill of [count, value] — create a list of `count` elements all set to `value`.
   Much faster than a loop for large arrays (e.g., 64K memory). */
Value* builtin_fill(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "fill requires [count, value]");
        return make_list(0);
    }
    int count = (int)arg->data.list.items[0]->data.num;
    Value *val = arg->data.list.items[1];
    if (count < 0) count = 0;
    if (count > 10000000) count = 10000000; /* 10M cap */
    /* #292: charge the sandbox budget — fill stores `count` slots pointing at the
     * shared value (the per-iteration aggregate that defeats the loop cap). */
    if (!sandbox_charge((size_t)count * sizeof(Value *))) return make_null();
    Value *result = make_list(count);
    for (int i = 0; i < count; i++)
        list_append(result, val);
    return result;
}

/* ==== BUILTIN: set_at — mutate a list element in place ==== */
/* set_at of [list, index, value] — sets list[index] = value, returns list */
/* set_at of [list, row, col, value] — sets list[row][col] = value for 2D */
/* #499: out-of-range / non-list / non-integer index used to be a silent
 * no-op (set_at) or a fold-to-0 (get_at) — inconsistent with the `xs[i]`
 * operator, which raises index_range. These helpers raise the same kinds. */
static int at_index(Value *idx_val, int count, const char *what,
                    int *out) {
    if (!idx_val || idx_val->type != VAL_NUM) {
        rt_error(EK_VALUE, 0, "%s index must be an integer", what);
        return 0;
    }
    int idx = (int)idx_val->data.num;
    if (idx < 0) idx += count;          /* #312: negative counts from end */
    if (idx < 0 || idx >= count) {
        rt_error(EK_INDEX, 0, "index %d out of range (list length %d)",
                 (int)idx_val->data.num, count);
        return 0;
    }
    *out = idx;
    return 1;
}

Value* builtin_set_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST) {
        rt_error(EK_TYPE, 0, "set_at requires [list, index, value] or "
                 "[list, row, col, value]");
        return make_null();
    }
    int argc = arg->data.list.count;
    if (argc == 3) {
        /* 1D: set_at of [list, index, value] */
        Value *list = arg->data.list.items[0];
        Value *val = arg->data.list.items[2];
        if (!list || list->type != VAL_LIST) {
            rt_error(EK_TYPE, 0, "set_at: first argument must be a list");
            return make_null();
        }
        int idx;
        if (!at_index(arg->data.list.items[1], list->data.list.count, "set_at", &idx))
            return make_null();
        val_incref(val);
        val_decref(list->data.list.items[idx]);
        list->data.list.items[idx] = val;
        return list;
    }
    if (argc == 4) {
        /* 2D: set_at of [list, row, col, value] */
        Value *list = arg->data.list.items[0];
        Value *val = arg->data.list.items[3];
        if (!list || list->type != VAL_LIST) {
            rt_error(EK_TYPE, 0, "set_at: first argument must be a list");
            return make_null();
        }
        int row;
        if (!at_index(arg->data.list.items[1], list->data.list.count, "set_at row", &row))
            return make_null();
        Value *rowv = list->data.list.items[row];
        if (!rowv || rowv->type != VAL_LIST) {
            rt_error(EK_TYPE, 0, "set_at: row %d is not a list", row);
            return make_null();
        }
        int col;
        if (!at_index(arg->data.list.items[2], rowv->data.list.count, "set_at col", &col))
            return make_null();
        val_incref(val);
        val_decref(rowv->data.list.items[col]);
        rowv->data.list.items[col] = val;
        return list;
    }
    rt_error(EK_TYPE, 0, "set_at takes [list, index, value] or "
             "[list, row, col, value]");
    return make_null();
}

/* ==== BUILTIN: get_at — read a list element ==== */
/* get_at of [list, index] or get_at of [list, row, col] */
Value* builtin_get_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST) {
        rt_error(EK_TYPE, 0, "get_at requires [list, index] or [list, row, col]");
        return make_null();
    }
    int argc = arg->data.list.count;
    if (argc == 2) {
        Value *list = arg->data.list.items[0];
        if (!list || list->type != VAL_LIST) {
            rt_error(EK_TYPE, 0, "get_at: first argument must be a list");
            return make_null();
        }
        int idx;
        if (!at_index(arg->data.list.items[1], list->data.list.count, "get_at", &idx))
            return make_null();
        val_incref(list->data.list.items[idx]);
        return list->data.list.items[idx];
    }
    if (argc == 3) {
        Value *list = arg->data.list.items[0];
        if (!list || list->type != VAL_LIST) {
            rt_error(EK_TYPE, 0, "get_at: first argument must be a list");
            return make_null();
        }
        int row;
        if (!at_index(arg->data.list.items[1], list->data.list.count, "get_at row", &row))
            return make_null();
        Value *rowv = list->data.list.items[row];
        if (!rowv || rowv->type != VAL_LIST) {
            rt_error(EK_TYPE, 0, "get_at: row %d is not a list", row);
            return make_null();
        }
        int col;
        if (!at_index(arg->data.list.items[2], rowv->data.list.count, "get_at col", &col))
            return make_null();
        val_incref(rowv->data.list.items[col]);
        return rowv->data.list.items[col];
    }
    rt_error(EK_TYPE, 0, "get_at takes [list, index] or [list, row, col]");
    return make_null();
}

/* ================================================================
 * CONCURRENCY: spawn/join/channel builtins
 * ================================================================ */

typedef struct {
    Value *fn;
    Value **fn_args;       /* arg_count Value* — owned (incref'd by spawn) */
    int fn_arg_count;
    Env *parent_env;
    EigsState *parent_state;  /* state the spawning thread is attached to */
    Value *result;
    volatile int done;
    pthread_t tid;
} ThreadHandle;

static void *thread_entry(void *arg) {
    ThreadHandle *h = (ThreadHandle *)arg;
    /* Attach this OS thread to the parent's state. eigs_thread_attach
     * runs arena_init internally, so the legacy arena_init call site
     * has moved into the lifecycle. */
    eigs_thread_attach(h->parent_state);
    Value *fn = h->fn;
    if (fn->type == VAL_FN) {
        Env *call_env = env_new(fn->data.fn.closure);
        int bind_n = h->fn_arg_count;
        if (bind_n > fn->data.fn.param_count) bind_n = fn->data.fn.param_count;
        for (int i = 0; i < bind_n; i++) {
            env_set_local(call_env, fn->data.fn.params[i], h->fn_args[i]);
        }
        for (int i = bind_n; i < fn->data.fn.param_count; i++) {
            env_set_local_owned(call_env, fn->data.fn.params[i], make_null());
        }
        Value *result = make_null();
        g_returning = 0;
        g_return_val = NULL;
        if (fn->data.fn.body_count == -1) {
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            if (fn_chunk->local_count > fn->data.fn.param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);
            result = vm_execute(fn_chunk, call_env);
        } else {
            /* AST-based function — should not happen after bytecode migration */
            result = make_null();
        }
        /* vm_execute returns an OWNED ref (cf. main.c, which decrefs it); the
         * handle takes over that single ref via h->result. thread_join transfers
         * it to the caller; handle_table_drain decrefs it for an unjoined worker.
         * An extra incref here was a second ref with no owner — it leaked the
         * worker's heap-allocated return value (arena-allocated returns masked
         * it, since those aren't individually refcounted). */
        h->result = result;
        env_decref(call_env);
    } else if (fn->type == VAL_BUILTIN) {
        /* Builtins take a single Value*; pass args[0] for 1-arg form,
         * or a list of all args for N-arg form (consistent with how
         * EigenScript surfaces multi-arg calls to builtins). */
        Value *bin_arg;
        if (h->fn_arg_count == 0) {
            bin_arg = make_null();
        } else if (h->fn_arg_count == 1) {
            bin_arg = h->fn_args[0];
            val_incref(bin_arg);
        } else {
            Value *l = make_list(h->fn_arg_count);
            for (int i = 0; i < h->fn_arg_count; i++)
                list_append(l, h->fn_args[i]);
            bin_arg = l;
        }
        h->result = fn->data.builtin(bin_arg);
        val_decref(bin_arg);
        /* builtin returns an owned ref; the handle takes it over (see the
         * VAL_FN path above) — no extra incref, which would leak. */
    }
    /* #302: the return value may be arena-allocated (or a heap container with
     * arena children) if the worker left g_arena.active — eigs_thread_detach
     * below runs arena_destroy and frees the worker's arena. The joiner reads
     * h->result strictly after that (pthread_join), so deep-copy it to heap
     * now, re-homing interned dict keys into the process-global table, exactly
     * as channel sends do (#293's val_clone_for_send). Drop the original. */
    if (h->result) {
        Value *cloned = val_clone_for_send(h->result);
        val_decref(h->result);
        h->result = cloned;
    }
    /* An uncaught throw on this thread leaves its structured payload in
     * thread-local storage; release it before the thread exits. */
    eigs_clear_error_value();
    h->done = 1;
    /* Detach from the state — runs arena_destroy and clears TLS. The
     * cycle collector resumes once all workers are joined (handle_table_drain
     * clears multithreaded); see the threaded cycle-GC change. */
    eigs_thread_detach();
    return NULL;
}

Value* builtin_spawn(Value *arg) {
    Value *fn = arg;
    Value **fn_args = NULL;
    int fn_arg_count = 0;
    /* Accept bare function (0 args) or [fn, arg1, arg2, ...] (N args) */
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        fn = arg->data.list.items[0];
        fn_arg_count = arg->data.list.count - 1;
        if (fn_arg_count > 0) {
            fn_args = xmalloc(sizeof(Value*) * fn_arg_count);
            for (int i = 0; i < fn_arg_count; i++) {
                fn_args[i] = arg->data.list.items[i + 1];
                val_incref(fn_args[i]);
            }
        }
    }
    if (!fn || (fn->type != VAL_FN && fn->type != VAL_BUILTIN)) {
        if (fn_args) {
            for (int i = 0; i < fn_arg_count; i++) val_decref(fn_args[i]);
            free(fn_args);
        }
        rt_error(EK_TYPE, 0, "spawn requires a function or [function, arg1, ...]");
        return make_null();
    }
    ThreadHandle *h = xmalloc(sizeof(ThreadHandle));
    h->fn = fn;
    val_incref(fn);
    h->fn_args = fn_args;
    h->fn_arg_count = fn_arg_count;
    h->parent_env = g_global_env;
    h->parent_state = eigs_current_state();
    h->result = NULL;
    h->done = 0;
    int hid = handle_register(h, HANDLE_THREAD);
    if (hid < 0) {
        val_decref(fn);
        if (fn_args) {
            for (int i = 0; i < fn_arg_count; i++) val_decref(fn_args[i]);
            free(fn_args);
        }
        free(h);
        return make_null();
    }
    /* Flip refcounts to atomic mode before any new thread can observe a Value.
     * pthread_create supplies the full barrier. The cycle collector's registry
     * is per-state and lock-guarded, so registration safely continues across
     * threads; collection is gated to single-threaded and resumes once all
     * workers are joined (see handle_table_drain).
     *
     * #297: write the flag ONLY on the 0→1 transition. The first spawn flips it
     * while still single-threaded (no concurrent reader); re-writing `= 1` on
     * every later spawn raced with already-running workers reading the flag in
     * env_incref / chunk_incref (the refcount-mode gate). Later spawns now only
     * READ it (the value is already published to all workers via the first
     * write's happens-before through their pthread_create). */
    if (!g_vm_multithreaded) g_vm_multithreaded = 1;
    int pc_rc = pthread_create(&h->tid, NULL, thread_entry, h);
    if (pc_rc != 0) {
        /* The thread never started. Returning a live-looking handle here
         * silently strands any code that depends on the thread running —
         * e.g. a sibling that waits on a channel the thread was meant to
         * close, which then blocks until its (possibly enormous) timeout.
         * Raise instead, so the failure surfaces at the spawn point rather
         * than as a hang far away. Seen on a memory-constrained host where
         * the new thread's stack allocation failed with EAGAIN/ENOMEM.
         * thread_entry never ran, so unwind this thread's setup fully. */
        handle_release(hid);
        val_decref(h->fn);
        if (h->fn_args) {
            for (int i = 0; i < h->fn_arg_count; i++) val_decref(h->fn_args[i]);
            free(h->fn_args);
        }
        free(h);
        rt_error(EK_IO, 0, "spawn: could not create thread: %s", strerror(pc_rc));
        return make_null();
    }
    Value *d = make_dict(8);
    dict_set_owned(d, "_handle_id", make_num((double)hid));
    dict_set_owned(d, "done", make_num(0));
    return d;
}

Value* builtin_thread_join(Value *arg) {
    if (!arg || arg->type != VAL_DICT) {
        rt_error(EK_TYPE, 0, "thread_join requires a thread handle");
        return make_null();
    }
    Value *hv = dict_get(arg, "_handle_id");
    if (!hv || hv->type != VAL_NUM) return make_null();
    int hid = (int)hv->data.num;
    ThreadHandle *h = (ThreadHandle*)handle_lookup(hid, HANDLE_THREAD);
    if (!h) return make_null();
    pthread_join(h->tid, NULL);
    Value *result = h->result ? h->result : make_null();
    val_decref(h->fn);
    if (h->fn_args) {
        for (int i = 0; i < h->fn_arg_count; i++) val_decref(h->fn_args[i]);
        free(h->fn_args);
    }
    handle_release(hid);
    free(h);
    return result;
}

/* ---- Channels ---- */

#define CHANNEL_BUF_SIZE 64

typedef struct {
    Value *buffer[CHANNEL_BUF_SIZE];
    int head, tail, count;
    volatile int closed;
    pthread_mutex_t mutex;
    pthread_cond_t not_empty;
    pthread_cond_t not_full;
} Channel;

static Channel* get_channel(Value *v) {
    if (!v || v->type != VAL_DICT) return NULL;
    Value *cv = dict_get(v, "_channel_id");
    if (!cv || cv->type != VAL_NUM) return NULL;
    return (Channel*)handle_lookup((int)cv->data.num, HANDLE_CHANNEL);
}

/* On Linux (and most other POSIX targets) use CLOCK_MONOTONIC for the
 * channel condvars so recv_timeout's deadline is immune to wall-clock
 * steps (NTP, settimeofday). macOS does not expose
 * pthread_condattr_setclock — its pthread_cond_timedwait is hard-wired
 * to CLOCK_REALTIME — so on Apple we keep the platform default and
 * read the deadline base from the matching clock in recv_timeout. The
 * NTP-immunity hardening from #151 is Linux-only; macOS preserves
 * pre-#151 behavior with no functional regression. */
#if defined(__APPLE__)
#  define EIGS_CHANNEL_CLOCK CLOCK_REALTIME
#else
#  define EIGS_CHANNEL_CLOCK CLOCK_MONOTONIC
#endif

Value* builtin_channel(Value *arg) {
    (void)arg;
    Channel *ch = xcalloc(1, sizeof(Channel));
    pthread_mutex_init(&ch->mutex, NULL);
    pthread_condattr_t cattr;
    pthread_condattr_init(&cattr);
#if !defined(__APPLE__)
    pthread_condattr_setclock(&cattr, CLOCK_MONOTONIC);
#endif
    pthread_cond_init(&ch->not_empty, &cattr);
    pthread_cond_init(&ch->not_full,  &cattr);
    pthread_condattr_destroy(&cattr);
    ch->closed = 0;
    int hid = handle_register(ch, HANDLE_CHANNEL);
    if (hid < 0) { free(ch); return make_null(); }
    Value *d = make_dict(8);
    dict_set_owned(d, "_channel_id", make_num((double)hid));
    return d;
}

/* Thread safety: values sent through channels are deep-copied (#293) so the
 * received value is self-contained — independent of the sender thread's
 * lifetime (its dict keys are interned per-thread and freed at detach) and of
 * its arena. Data types (num/str/list/dict, nested) are copied; fn/builtin/
 * buffer/text_builder are still shared by refcount. The copy also removes the
 * old shared-mutable-container hazard for the copied types. */
Value* builtin_send(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "send requires [channel, value]");
        return make_null();
    }
    Channel *ch = get_channel(arg->data.list.items[0]);
    if (!ch) {
        rt_error(EK_VALUE, 0, "send: invalid channel");
        return make_null();
    }
    /* Deep-copy into a self-contained heap value (refcount 1) owned by the
     * channel buffer; receiver adopts that ref. */
    Value *val = val_clone_for_send(arg->data.list.items[1]);
    pthread_mutex_lock(&ch->mutex);
    while (ch->count >= CHANNEL_BUF_SIZE && !ch->closed)
        pthread_cond_wait(&ch->not_full, &ch->mutex);
    if (!ch->closed) {
        ch->buffer[ch->tail] = val;
        ch->tail = (ch->tail + 1) % CHANNEL_BUF_SIZE;
        ch->count++;
        pthread_cond_signal(&ch->not_empty);
        pthread_mutex_unlock(&ch->mutex);
    } else {
        /* #505: sending to a closed channel drops the value. Failing open
         * loses messages with rc=0 (producer races a consumer's close). Raise
         * instead — recv on a closed empty channel still returns null (EOF). */
        pthread_mutex_unlock(&ch->mutex);
        val_decref(val);
        rt_error(EK_VALUE, 0, "send: channel is closed");
        return make_null();
    }
    return make_null();
}

Value* builtin_recv(Value *arg) {
    if (replay_blocks("recv")) return make_null();
    Channel *ch = get_channel(arg);
    if (!ch) {
        rt_error(EK_VALUE, 0, "recv: invalid channel");
        return make_null();
    }
    pthread_mutex_lock(&ch->mutex);
    while (ch->count == 0 && !ch->closed)
        pthread_cond_wait(&ch->not_empty, &ch->mutex);
    Value *val = NULL;
    if (ch->count > 0) {
        val = ch->buffer[ch->head];
        ch->head = (ch->head + 1) % CHANNEL_BUF_SIZE;
        ch->count--;
        pthread_cond_signal(&ch->not_full);
    }
    pthread_mutex_unlock(&ch->mutex);
    return val ? val : make_null();
}

/* try_recv of channel — non-blocking receive, returns null if empty */
Value* builtin_try_recv(Value *arg) {
    if (replay_blocks("try_recv")) return make_null();
    Channel *ch = get_channel(arg);
    if (!ch) {
        rt_error(EK_VALUE, 0, "try_recv: invalid channel");
        return make_null();
    }
    pthread_mutex_lock(&ch->mutex);
    Value *val = NULL;
    if (ch->count > 0) {
        val = ch->buffer[ch->head];
        ch->head = (ch->head + 1) % CHANNEL_BUF_SIZE;
        ch->count--;
        pthread_cond_signal(&ch->not_full);
    }
    pthread_mutex_unlock(&ch->mutex);
    return val ? val : make_null();
}

/* recv_timeout of [channel, ms] — bounded wait. Returns the value if one
 * arrives (or is already buffered) before the deadline, else null. ms is
 * interpreted as milliseconds; fractional values are honored (ns precision
 * on Linux). Negative ms degenerates to a try_recv. */
Value* builtin_recv_timeout(Value *arg) {
    if (replay_blocks("recv_timeout")) return make_null();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "recv_timeout requires [channel, ms]");
        return make_null();
    }
    Channel *ch = get_channel(arg->data.list.items[0]);
    if (!ch) {
        rt_error(EK_VALUE, 0, "recv_timeout: invalid channel");
        return make_null();
    }
    Value *ms_v = arg->data.list.items[1];
    if (ms_v->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "recv_timeout: ms must be a number");
        return make_null();
    }
    double ms = ms_v->data.num;
    /* Sanitize ms before the (long) cast (#151). NaN, +inf, or any value
     * above ~LONG_MAX is undefined behavior when cast to long, and in
     * practice produced a garbage deadline that fired immediately or
     * waited essentially forever. Cap at one year of ms (3.15e10) — well
     * below LONG_MAX on 32-bit time_t hosts and far beyond any plausible
     * channel timeout. NaN degenerates to try_recv (ms=0). */
    if (isnan(ms))      ms = 0.0;
    else if (ms < 0.0)  ms = 0.0;
    else if (ms > 3.15e10) ms = 3.15e10;

    struct timespec deadline;
    clock_gettime(EIGS_CHANNEL_CLOCK, &deadline);
    long whole_ms = (long)ms;
    long extra_ns = (long)((ms - (double)whole_ms) * 1e6);
    deadline.tv_sec  += whole_ms / 1000;
    deadline.tv_nsec += (whole_ms % 1000) * 1000000L + extra_ns;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec  += deadline.tv_nsec / 1000000000L;
        deadline.tv_nsec %= 1000000000L;
    }

    pthread_mutex_lock(&ch->mutex);
    int rc = 0;
    while (ch->count == 0 && !ch->closed && rc == 0) {
        rc = pthread_cond_timedwait(&ch->not_empty, &ch->mutex, &deadline);
    }
    Value *val = NULL;
    if (ch->count > 0) {
        val = ch->buffer[ch->head];
        ch->head = (ch->head + 1) % CHANNEL_BUF_SIZE;
        ch->count--;
        pthread_cond_signal(&ch->not_full);
    }
    pthread_mutex_unlock(&ch->mutex);
    return val ? val : make_null();
}

Value* builtin_close_channel(Value *arg) {
    Channel *ch = get_channel(arg);
    if (!ch) {
        rt_error(EK_VALUE, 0, "close_channel: invalid channel");
        return make_null();
    }
    pthread_mutex_lock(&ch->mutex);
    ch->closed = 1;
    pthread_cond_broadcast(&ch->not_empty);
    pthread_cond_broadcast(&ch->not_full);
    pthread_mutex_unlock(&ch->mutex);
    return make_null();
}

Value* builtin_channel_closed(Value *arg) {
    Channel *ch = get_channel(arg);
    if (!ch) return make_num(1);
    /* Read ch->closed under the mutex: close_channel writes it while holding
     * the lock, so a bare read here is a data race (caught by the #401 TSan
     * gate — it fired in CI where two workers polled channel_closed against a
     * concurrent close, though single-core timing hid it locally). */
    pthread_mutex_lock(&ch->mutex);
    int closed = ch->closed;
    pthread_mutex_unlock(&ch->mutex);
    return make_num(closed ? 1 : 0);
}

/* ==== #408 cooperative task layer (increment 1a: spawn + alive) ====
 *
 * A Task rides the single OS thread; it never flips g_vm_multithreaded, so
 * the JIT stays live and the refcount fast paths stay non-atomic. Increment
 * 1a records tasks and reports liveness; the copying-stack scheduler that
 * actually runs and interleaves them lands in 1b (task_yield/task_join and
 * the suspend/resume surgery). Held refs (entry_fn/args) are kept live by
 * the trial-deletion cycle collector automatically — a counted ref exceeds
 * the collector's internal-edge count within its candidate set U, exactly
 * as ThreadHandle->fn does — so no root registration is needed. These
 * builtins take NO trace records: the scheduling order is a pure function of
 * program order, not host nondeterminism (the #408 deterministic-by-
 * construction ruling), so wrapping them in TRACE_NONDET_RET would be wrong. */
void task_free(Task *t) {
    if (!t) return;
    if (t->entry_fn) val_decref(t->entry_fn);
    if (t->args) {
        for (int i = 0; i < t->argc; i++)
            if (t->args[i]) val_decref(t->args[i]);
        free(t->args);
    }
    if (t->run_env) env_decref(t->run_env);
    if (t->result) val_decref(t->result);
    if (t->error_value) val_decref(t->error_value);
    /* inc 2: drain any undelivered mailbox messages. */
    if (t->mbox) {
        for (int i = 0; i < t->mbox_count; i++)
            val_decref(t->mbox[(t->mbox_head + i) % t->mbox_cap]);
        free(t->mbox);
    }
    /* A task torn down while still SUSPENDED (kill-outstanding at main's end,
     * or an unjoined task at exit) still owns the counted refs sitting in its
     * saved slice — decref them so the leak tally stays 0. */
    if (t->saved_stack) {
        for (int i = 0; i < t->saved_stack_len; i++)
            slot_decref(t->saved_stack[i]);
        free(t->saved_stack);
    }
    if (t->saved_frames) {
        for (int i = 0; i < t->saved_frame_count; i++) {
            CallFrame *f = &t->saved_frames[i];
            if (f->owns_env && f->env) env_decref(f->env);
            if (f->chunk) chunk_decref(f->chunk);
        }
        free(t->saved_frames);
    }
    free(t);
}

/* task_spawn of fn  /  task_spawn of [fn, arg1, ...] → task id (a number).
 * Args are deep-copied to the heap (share-nothing at the boundary, exactly
 * like channel sends / thread_join results — #293's val_clone_for_send), so
 * a task never shares a mutable arena/heap value with its spawner by
 * reference. The task does not run yet (1a); the scheduler starts it in 1b. */
Value* builtin_task_spawn(Value *arg) {
    Value *fn = arg;
    Value **args = NULL;
    int argc = 0;
    if (arg && arg->type == VAL_LIST && arg->data.list.count >= 1) {
        fn = arg->data.list.items[0];
        argc = arg->data.list.count - 1;
        if (argc > 0) {
            args = xmalloc(sizeof(Value*) * argc);
            for (int i = 0; i < argc; i++)
                args[i] = val_clone_for_send(arg->data.list.items[i + 1]);
        }
    }
    if (!fn || (fn->type != VAL_FN && fn->type != VAL_BUILTIN)) {
        if (args) {
            for (int i = 0; i < argc; i++) val_decref(args[i]);
            free(args);
        }
        rt_error(EK_TYPE, 0, "task_spawn requires a function or [function, arg1, ...]");
        return make_null();
    }
    Task *t = xcalloc(1, sizeof(Task));
    t->state = TASK_READY;
    t->entry_fn = fn;
    val_incref(fn);
    t->args = args;
    t->argc = argc;
    int id = handle_register(t, HANDLE_TASK);
    if (id < 0) {
        task_free(t);
        rt_error(EK_LIMIT, 0, "task_spawn: too many live tasks (max %d)",
                 HANDLE_TABLE_SIZE - 1);
        return make_null();
    }
    t->id = id;
    task_sched_on_spawn(id);   /* enqueue + arm the scheduler */
    return make_num((double)id);
}

/* #488: a `must_not_yield` region asserts atomicity. A critical section under
 * cooperative scheduling is atomic *only* while it issues no yield — the
 * implicit mutual exclusion a non-yielding region gets for free. Nothing marked
 * such a region, so a yield introduced later (directly, or via a builtin that
 * yields internally) broke atomicity silently. While this depth is nonzero,
 * any task builtin that would actually SUSPEND raises instead, so the mistake
 * fails loudly. Only nonzero for the running task — a yield cannot happen
 * inside, so no task switch occurs while it is set, and a plain counter is
 * safe. */
static int g_no_yield_depth = 0;

static int no_yield_forbidden(const char *what) {
    if (g_no_yield_depth > 0) {
        rt_error(EK_VALUE, 0,
                 "%s inside a must_not_yield region — the critical section "
                 "would suspend, breaking its atomicity", what);
        return 1;
    }
    return 0;
}

/* task_yield of null — cooperatively hand control to the next ready task.
 * Returns null (the value of the yield expression); the scheduler saves and
 * re-enqueues this task at the tail. Forbidden inside an active arena scope
 * (arena_mark…arena_reset): a suspended task's arena values would be reclaimed
 * by another task's arena_reset — the task layer and the training arena are
 * separate tools (Lua-style "can't yield across a C boundary"). */
Value* builtin_task_yield(Value *arg) {
    (void)arg;
    /* #510: the arena guard is independent of whether a scheduler exists yet.
     * Yielding inside arena_mark…arena_reset is forbidden even before any
     * task_spawn — check it BEFORE the no-scheduler short-circuit so the
     * "no-op with no tasks" rule cannot hide the "raise inside an arena" rule. */
    if (g_arena.active) {
        rt_error(EK_VALUE, 0, "cannot task_yield inside an arena scope "
                 "(arena_mark…arena_reset)");
        return make_null();
    }
    if (!g_task_sched) return make_null();   /* no scheduler: yield is a no-op */
    if (no_yield_forbidden("task_yield")) return make_null();   /* #488 */
    task_request_yield();
    return make_null();   /* placeholder: execution resumes right after this */
}

/* task_join of id — block until task `id` finishes; return its (deep-copied)
 * result, or re-raise its uncaught error. Joining an already-finished task
 * returns immediately. Joining an unknown id, self, or with no scheduler
 * returns null. Same arena/nesting restriction as task_yield. */
Value* builtin_task_join(Value *arg) {
    if (!arg || arg->type != VAL_NUM || !g_task_sched) return make_null();
    int target = (int)arg->data.num;
    Task *t = (Task*)handle_lookup(target, HANDLE_TASK);
    if (!t) return make_null();
    if (t->state == TASK_DONE || t->state == TASK_DEAD) {
        /* Already finished: deliver its result / error now, no suspend. */
        if (t->has_error) {
            t->err_unobserved = 0;   /* #493: observed by this join (caught or not) */
            if (t->error_value) {
                val_incref(t->error_value);
                eigs_clear_error_value();
                g_error_value = t->error_value;
                g_error_kind = (int)EK_USER;
            }
            snprintf(g_error_msg, sizeof(g_error_msg), "joined task %d failed", target);
            g_has_error = 1;
            return make_null();
        }
        Value *r = t->result ? t->result : make_null();
        val_incref(r);
        return r;
    }
    if (g_arena.active) {
        rt_error(EK_VALUE, 0, "cannot task_join inside an arena scope "
                 "(arena_mark…arena_reset)");
        return make_null();
    }
    if (no_yield_forbidden("blocking task_join")) return make_null();   /* #488 */
    if (!task_request_join(target)) return make_null();
    return make_null();   /* placeholder: the scheduler fills it with the result on resume */
}

/* task_send of [id, value] — append a deep-copied message to task `id`'s
 * unbounded FIFO mailbox and wake it if it is waiting in task_recv. Sending to
 * a finished or unknown task is a silent drop (counted as a dead letter), not
 * an error — Akka dead-letters / Erlang cast. Returns 1 if delivered, 0 if
 * dropped. Never blocks (the mailbox is unbounded in v1). */
Value* builtin_task_send(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2 || !g_task_sched)
        return make_num(0);
    Value *idv = arg->data.list.items[0];
    if (!idv || idv->type != VAL_NUM) return make_num(0);
    Value *copy = val_clone_for_send(arg->data.list.items[1]);   /* share-nothing */
    int sent = task_deliver((int)idv->data.num, copy);
    if (!sent) val_decref(copy);   /* dropped to a dead task — release the copy */
    return make_num(sent ? 1 : 0);
}

/* task_recv of null — return the next message from this task's mailbox, or
 * block cooperatively until one arrives (woken by task_send). Same arena /
 * nested-evaluation restriction as the other suspending builtins. */
Value* builtin_task_recv(Value *arg) {
    (void)arg;
    /* A buffered message is delivered without suspending — arena-safe (and
     * mbox helpers are null-safe with no scheduler). Only the BLOCKING path
     * suspends, so only that path is arena-forbidden, and (#510) that guard
     * fires regardless of whether a scheduler exists yet. */
    if (task_mbox_has()) return task_mbox_pop();
    if (g_arena.active) {
        rt_error(EK_VALUE, 0, "cannot task_recv inside an arena scope "
                 "(arena_mark…arena_reset)");
        return make_null();
    }
    if (!g_task_sched) return make_null();   /* no tasks: nothing can arrive */
    if (no_yield_forbidden("blocking task_recv")) return make_null();   /* #488 */
    task_request_recv();
    return make_null();   /* placeholder: the scheduler delivers the message on resume */
}

/* task_try_recv of null — non-blocking receive: the next message, or null if
 * the mailbox is empty. Never suspends. */
Value* builtin_task_try_recv(Value *arg) {
    (void)arg;
    if (!g_task_sched || !task_mbox_has()) return make_null();
    return task_mbox_pop();
}

/* task_kill of id — deterministically tear down task `id`: drop its mailbox
 * and suspended slice, wake any joiner with an `interrupt` error, mark it
 * dead. Returns 1 if killed, 0 for a bad/self/finished target. */
Value* builtin_task_kill(Value *arg) {
    if (!arg || arg->type != VAL_NUM || !g_task_sched) return make_num(0);
    return make_num(task_do_kill((int)arg->data.num) ? 1 : 0);
}

/* task_alive of id → 1 while the task is READY/RUNNING/SUSPENDED, else 0
 * (DONE, DEAD, or an unknown id). */
Value* builtin_task_alive(Value *arg) {
    if (!arg || arg->type != VAL_NUM) return make_num(0);
    Task *t = (Task*)handle_lookup((int)arg->data.num, HANDLE_TASK);
    if (!t) return make_num(0);
    int alive = (t->state == TASK_READY || t->state == TASK_RUNNING ||
                 t->state == TASK_SUSPENDED);
    return make_num(alive ? 1 : 0);
}

/* task_sleep of ticks — suspend the current task until the virtual clock
 * advances by `ticks`. The clock is logical (discrete-event): it only jumps
 * forward, to the earliest sleeper, when nothing else is runnable — so this is
 * deterministic-by-construction like the rest of the task layer, NOT wall time.
 * A negative sleep is treated as 0 (a same-tick yield to everything ready). No
 * scheduler (no task ever spawned) → no time to pass, so it is a no-op, like
 * task_yield. Same arena/nesting restriction as the other suspending builtins. */
Value* builtin_task_sleep(Value *arg) {
    /* #510: arena guard before the no-scheduler short-circuit (see task_yield). */
    if (g_arena.active) {
        rt_error(EK_VALUE, 0, "cannot task_sleep inside an arena scope "
                 "(arena_mark…arena_reset)");
        return make_null();
    }
    if (!g_task_sched) return make_null();   /* no scheduler: nothing to wait for */
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "task_sleep requires a number of ticks");
        return make_null();
    }
    if (no_yield_forbidden("task_sleep")) return make_null();   /* #488 */
    task_request_sleep(arg->data.num);
    return make_null();   /* placeholder: execution resumes when the clock wakes it */
}

/* must_not_yield of fn — run `fn of null` as an ATOMIC critical section and
 * assert it issues no scheduler yield (#488). Any suspending task builtin
 * inside — task_yield, a blocking task_recv/task_join, task_sleep — raises
 * instead of suspending, so a yield introduced into a region that relies on
 * cooperative atomicity (e.g. eddy's snapshot-isolation commit loop) fails
 * loudly rather than corrupting silently under a rare interleaving. Returns
 * fn's result, or propagates its error; the region depth is balanced even when
 * the body raises (call_eigs_fn returns control either way). Nestable. */
Value* builtin_must_not_yield(Value *arg) {
    if (!arg || (arg->type != VAL_FN && arg->type != VAL_BUILTIN)) {
        rt_error(EK_TYPE, 0, "must_not_yield requires a function");
        return make_null();
    }
    g_no_yield_depth++;
    Value *nul = make_null();
    Value *r = call_eigs_fn(arg, nul);
    val_decref(nul);
    g_no_yield_depth--;
    return r ? r : make_null();
}

/* task_now of null → the current virtual-clock value (a number, 0 before any
 * task_sleep and 0 when no scheduler is active). Deterministic; reads a logical
 * counter, so it records no tape nondet. */
Value* builtin_task_now(Value *arg) {
    (void)arg;
    return make_num(task_virtual_now());
}

/* task_self of null → the running task's id (a number, in the same integer
 * space task_spawn returns; the main task is 0, including before any task has
 * been spawned). Lets a worker hand out its own id as a reply address — the
 * message-link supervision pattern (#526). Deterministic; reads scheduler
 * state, so it records no tape nondet. */
Value* builtin_task_self(Value *arg) {
    (void)arg;
    return make_num((double)task_current_id());
}

/* task_detach of id -> 1 (0 for main/unknown). Marks the task fire-and-forget
 * (#530, the pthread_detach precedent): it is reaped the moment it finishes —
 * or immediately if already finished — releasing its handle slot for reuse,
 * so task-per-message workloads are bounded by CONCURRENT tasks, not lifetime
 * spawns. A detached task's uncaught death still prints its trace and still
 * fails the process at exit (#493 — a scheduler counter survives the reap).
 * Joining a reaped id returns null, like any unknown id. Deterministic; no
 * tape participation. */
Value* builtin_task_detach(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "task_detach requires a task id (a number)");
        return make_null();
    }
    return make_num((double)task_do_detach((int)arg->data.num));
}

/* task_sched_seed of n — install a scheduling seed. By default tasks run FIFO
 * round-robin; with a seed the scheduler picks the next ready task
 * pseudo-randomly from a deterministic PRNG. The interleaving stays
 * reproducible (same seed → byte-identical run + replay, zero tape nondet); a
 * DIFFERENT seed explores a different ordering — the lever a deterministic
 * simulation tester uses to search interleavings. Typically called once at
 * program start. Returns null. */
Value* builtin_task_sched_seed(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "task_sched_seed requires a number (the seed)");
        return make_null();
    }
    task_sched_set_seed(arg->data.num);
    return make_null();
}

/* Deterministic teardown of OS-resource handles, run once the program has
 * finished executing (the full value world is still alive, so buffered-message
 * decrefs are safe). Channels and thread handles live in the process handle
 * table keyed by id, not on a refcounted Value, so they are never reclaimed by
 * the GC — `close_channel` only flips a flag, and an unjoined worker leaves its
 * ThreadHandle behind. Reclaim them here so a program that spawns/uses channels
 * is leak-clean at exit:
 *   pass 1 — join every still-registered (i.e. not explicitly thread_join'd)
 *            worker (spawn uses a joinable pthread); afterwards no thread is
 *            live to touch a channel;
 *   pass 2 — free each remaining channel: drain + decref buffered messages,
 *            destroy the mutex/conds, free the struct.
 * builtin_thread_join already releases+frees joined threads, so the table holds
 * only the un-joined remainder — no double-join. Idempotent (slots are nulled),
 * so a later eigs_state_destroy sees an empty table. */
void handle_table_drain(EigsState *st) {
    if (!st) return;
    /* #303: close + wake every channel BEFORE joining workers. A worker blocked
     * in recv (empty buffer) or send (full buffer) on a channel that was never
     * explicitly closed only wakes on a close broadcast — so without this pass
     * the pthread_join below would hang forever at exit. recv returns null on a
     * closed-empty channel and send skips the enqueue when closed, so a woken
     * worker runs to completion and becomes joinable. */
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        if (st->handle_table[i].type != HANDLE_CHANNEL) continue;
        Channel *ch = (Channel*)st->handle_table[i].ptr;
        if (!ch) continue;
        pthread_mutex_lock(&ch->mutex);
        ch->closed = 1;
        pthread_cond_broadcast(&ch->not_empty);
        pthread_cond_broadcast(&ch->not_full);
        pthread_mutex_unlock(&ch->mutex);
    }
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        if (st->handle_table[i].type != HANDLE_THREAD) continue;
        ThreadHandle *h = (ThreadHandle*)st->handle_table[i].ptr;
        if (!h) continue;
        pthread_join(h->tid, NULL);
        if (h->result) val_decref(h->result);
        val_decref(h->fn);
        if (h->fn_args) {
            for (int j = 0; j < h->fn_arg_count; j++) val_decref(h->fn_args[j]);
            free(h->fn_args);
        }
        free(h);
        st->handle_table[i].ptr = NULL;
    }
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        if (st->handle_table[i].type != HANDLE_CHANNEL) continue;
        Channel *ch = (Channel*)st->handle_table[i].ptr;
        if (!ch) continue;
        while (ch->count > 0) {
            Value *m = ch->buffer[ch->head];
            ch->buffer[ch->head] = NULL;
            ch->head = (ch->head + 1) % CHANNEL_BUF_SIZE;
            ch->count--;
            if (m) val_decref(m);
        }
        pthread_mutex_destroy(&ch->mutex);
        pthread_cond_destroy(&ch->not_empty);
        pthread_cond_destroy(&ch->not_full);
        free(ch);
        st->handle_table[i].ptr = NULL;
    }
    /* #408 tasks: cooperative, single-thread, no OS resource — just held
     * refs. An outstanding task at exit (never joined, or the program ended
     * with it still live) is reclaimed here. Its held entry_fn/args/result
     * decref through task_free; the value world is still alive so this is
     * safe, and it composes with the same leak-tally-0 gate as channels. */
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        if (st->handle_table[i].type != HANDLE_TASK) continue;
        Task *t = (Task*)st->handle_table[i].ptr;
        if (!t) continue;
        task_free(t);
        st->handle_table[i].ptr = NULL;
    }
    /* Every spawned worker is now joined → the process is single-threaded
     * again. Clear the multithreaded flag so the cycle collector resumes:
     * collection was gated off during the MT window (it races mutators), but
     * the per-state registry kept accumulating candidates the whole time, so
     * the exit-time gc_collect_at_exit now reclaims env↔closure cycles created
     * after the first spawn — on the main thread or in a (since-joined) worker.
     * Safe because no live thread remains to mutate the graph. */
    st->multithreaded = 0;
}

/* nearest_in_range of [entities, x, y, range, world_w, world_h, px_key, py_key, active_key]
   Returns {"index": idx, "dist": d, "dx": dx, "dy": dy} or null if none found.
   Iterates entities (list of dicts), finds nearest active entity within range
   using torus distance. Keys default to "px", "py", "active" if not provided. */
Value* builtin_nearest_in_range(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 6) {
        rt_error(EK_TYPE, 0, "nearest_in_range requires [entities, x, y, range, world_w, world_h]");
        return make_null();
    }
    Value *entities = arg->data.list.items[0];
    if (!entities || entities->type != VAL_LIST) return make_null();
    double px = arg->data.list.items[1]->data.num;
    double py = arg->data.list.items[2]->data.num;
    double range = arg->data.list.items[3]->data.num;
    double ww = arg->data.list.items[4]->data.num;
    double wh = arg->data.list.items[5]->data.num;
    const char *px_key = "px", *py_key = "py", *active_key = "active";
    if (arg->data.list.count >= 7 && arg->data.list.items[6]->type == VAL_STR)
        px_key = arg->data.list.items[6]->data.str;
    if (arg->data.list.count >= 8 && arg->data.list.items[7]->type == VAL_STR)
        py_key = arg->data.list.items[7]->data.str;
    if (arg->data.list.count >= 9 && arg->data.list.items[8]->type == VAL_STR)
        active_key = arg->data.list.items[8]->data.str;

    double range_sq = range * range;
    double best_sq = range_sq;
    int best_idx = -1;
    double best_dx = 0, best_dy = 0;
    int n = entities->data.list.count;

    /* Intern the keys once so we can use pointer equality against dict.keys[]
     * (which env_intern_name'd them on insertion). Hash them once too — the
     * hash probe is the fallback when the index hint misses. */
    char *iactive = env_intern_name(active_key);
    char *ipx = env_intern_name(px_key);
    char *ipy = env_intern_name(py_key);
    uint32_t h_active = env_hash_name(iactive);
    uint32_t h_px = env_hash_name(ipx);
    uint32_t h_py = env_hash_name(ipy);

    /* Index hints learned from the first dict that contains each key.
     * For structurally-identical entity dicts (the common case) this lets
     * us skip the hash probe entirely on every subsequent entity. */
    int hint_active = -1, hint_px = -1, hint_py = -1;

    /* Each entity dict is a separate heap allocation — touching n of them
     * pulls in ~12-15 cache lines per iteration. Prefetch the dict header
     * a few iterations ahead so its first cache line is in L1 by the time
     * we reach it. PFDIST=8 lines up with typical L1 miss latency. */
    enum { PFDIST = 8 };

    for (int i = 0; i < n; i++) {
        if (i + PFDIST < n)
            __builtin_prefetch(entities->data.list.items[i + PFDIST], 0, 1);
        Value *e = entities->data.list.items[i];
        if (!e || e->type != VAL_DICT) continue;
        char **keys = e->data.dict.keys;
        Value **vals = e->data.dict.vals;
        int kcount = e->data.dict.count;

        Value *av;
        if (hint_active >= 0 && hint_active < kcount && keys[hint_active] == iactive) {
            av = vals[hint_active];
        } else {
            int idx = env_hash_find_dict(e, iactive, h_active);
            if (idx >= 0 && hint_active < 0) hint_active = idx;
            av = (idx >= 0) ? vals[idx] : NULL;
        }
        if (av && av->type == VAL_NUM && av->data.num != 1.0) continue;

        Value *ex;
        if (hint_px >= 0 && hint_px < kcount && keys[hint_px] == ipx) {
            ex = vals[hint_px];
        } else {
            int idx = env_hash_find_dict(e, ipx, h_px);
            if (idx >= 0 && hint_px < 0) hint_px = idx;
            ex = (idx >= 0) ? vals[idx] : NULL;
        }

        Value *ey;
        if (hint_py >= 0 && hint_py < kcount && keys[hint_py] == ipy) {
            ey = vals[hint_py];
        } else {
            int idx = env_hash_find_dict(e, ipy, h_py);
            if (idx >= 0 && hint_py < 0) hint_py = idx;
            ey = (idx >= 0) ? vals[idx] : NULL;
        }

        if (!ex || !ey || ex->type != VAL_NUM || ey->type != VAL_NUM) continue;

        double dx = ex->data.num - px;
        double dy = ey->data.num - py;
        double hw = ww * 0.5, hh = wh * 0.5;
        if (dx > hw) dx -= ww; else if (dx < -hw) dx += ww;
        if (dy > hh) dy -= wh; else if (dy < -hh) dy += wh;
        double dsq = dx * dx + dy * dy;
        if (dsq < best_sq) {
            best_sq = dsq;
            best_idx = i;
            best_dx = dx;
            best_dy = dy;
        }
    }
    if (best_idx < 0) return make_null();
    Value *result = make_dict(8);
    dict_set_owned(result, "index", make_num(best_idx));
    dict_set_owned(result, "dist", make_num(sqrt(best_sq)));
    dict_set_owned(result, "dx", make_num(best_dx));
    dict_set_owned(result, "dy", make_num(best_dy));
    return result;
}

/* nearest_in_range_all of [entities, range, world_w, world_h, px_key?, py_key?, active_key?]
   Batched form: for every entity i in entities, return the nearest active
   entity (including i itself, mirroring single-call semantics) within range.
   Returns a list of len(entities) results; each is {index,dist,dx,dy} or null.

   Why this exists: the per-entity nearest_in_range pattern walks the list of
   entity dicts O(n) times per simulation step, paying the dict pointer-chase
   per scalar field on every visit. Batching extracts (px,py,active) into
   parallel double arrays once, then runs the O(n^2) scan over a flat SoA
   layout that fits L1 (24 bytes/entity ≈ 18KB at n=768). The expensive part
   becomes pure arithmetic on contiguous doubles instead of cache-missing
   pointer chases through 6-key dicts. */
Value* builtin_nearest_in_range_all(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) {
        rt_error(EK_TYPE, 0, "nearest_in_range_all requires [entities, range, world_w, world_h]");
        return make_null();
    }
    Value *entities = arg->data.list.items[0];
    if (!entities || entities->type != VAL_LIST) return make_null();
    double range = arg->data.list.items[1]->data.num;
    double ww = arg->data.list.items[2]->data.num;
    double wh = arg->data.list.items[3]->data.num;
    const char *px_key = "px", *py_key = "py", *active_key = "active";
    if (arg->data.list.count >= 5 && arg->data.list.items[4]->type == VAL_STR)
        px_key = arg->data.list.items[4]->data.str;
    if (arg->data.list.count >= 6 && arg->data.list.items[5]->type == VAL_STR)
        py_key = arg->data.list.items[5]->data.str;
    if (arg->data.list.count >= 7 && arg->data.list.items[6]->type == VAL_STR)
        active_key = arg->data.list.items[6]->data.str;

    int n = entities->data.list.count;
    double range_sq = range * range;
    double hw = ww * 0.5, hh = wh * 0.5;

    if (n <= 0) return make_list(0);

    /* SoA arrays — one entry per original position, valid[] indicates
     * whether the dict at that index produced usable numeric coords. */
    double *px_arr = xmalloc_array(n, sizeof(double));
    double *py_arr = xmalloc_array(n, sizeof(double));
    char *active_arr = xmalloc_array(n, sizeof(char));
    char *valid_arr = xmalloc_array(n, sizeof(char));

    char *iactive = env_intern_name(active_key);
    char *ipx = env_intern_name(px_key);
    char *ipy = env_intern_name(py_key);
    uint32_t h_active = env_hash_name(iactive);
    uint32_t h_px = env_hash_name(ipx);
    uint32_t h_py = env_hash_name(ipy);
    int hint_active = -1, hint_px = -1, hint_py = -1;

    enum { PFDIST = 8 };
    for (int i = 0; i < n; i++) {
        if (i + PFDIST < n)
            __builtin_prefetch(entities->data.list.items[i + PFDIST], 0, 1);
        Value *e = entities->data.list.items[i];
        if (!e || e->type != VAL_DICT) {
            valid_arr[i] = 0;
            active_arr[i] = 0;
            continue;
        }
        char **keys = e->data.dict.keys;
        Value **vals = e->data.dict.vals;
        int kcount = e->data.dict.count;

        Value *av;
        if (hint_active >= 0 && hint_active < kcount && keys[hint_active] == iactive) {
            av = vals[hint_active];
        } else {
            int idx = env_hash_find_dict(e, iactive, h_active);
            if (idx >= 0 && hint_active < 0) hint_active = idx;
            av = (idx >= 0) ? vals[idx] : NULL;
        }
        /* active default: 1 (matches single-call behavior where missing/non-num
         * is treated as active). Explicit 0/non-1 value flips to inactive. */
        active_arr[i] = (av && av->type == VAL_NUM && av->data.num != 1.0) ? 0 : 1;

        Value *ex;
        if (hint_px >= 0 && hint_px < kcount && keys[hint_px] == ipx) {
            ex = vals[hint_px];
        } else {
            int idx = env_hash_find_dict(e, ipx, h_px);
            if (idx >= 0 && hint_px < 0) hint_px = idx;
            ex = (idx >= 0) ? vals[idx] : NULL;
        }
        Value *ey;
        if (hint_py >= 0 && hint_py < kcount && keys[hint_py] == ipy) {
            ey = vals[hint_py];
        } else {
            int idx = env_hash_find_dict(e, ipy, h_py);
            if (idx >= 0 && hint_py < 0) hint_py = idx;
            ey = (idx >= 0) ? vals[idx] : NULL;
        }
        if (!ex || !ey || ex->type != VAL_NUM || ey->type != VAL_NUM) {
            valid_arr[i] = 0;
            continue;
        }
        px_arr[i] = ex->data.num;
        py_arr[i] = ey->data.num;
        valid_arr[i] = 1;
    }

    Value *result = make_list(n);

    for (int i = 0; i < n; i++) {
        if (!valid_arr[i]) {
            list_append_owned(result, make_null());
            continue;
        }
        double pi_x = px_arr[i];
        double pi_y = py_arr[i];
        double best_sq = range_sq;
        int best_idx = -1;
        double best_dx = 0, best_dy = 0;

        /* Tight SoA inner loop — pure double arithmetic, no pointer chasing.
         * At n=768 the three input arrays total ~14KB, comfortably in L1. */
        for (int j = 0; j < n; j++) {
            if (!valid_arr[j] || !active_arr[j]) continue;
            double dx = px_arr[j] - pi_x;
            double dy = py_arr[j] - pi_y;
            if (dx > hw) dx -= ww; else if (dx < -hw) dx += ww;
            if (dy > hh) dy -= wh; else if (dy < -hh) dy += wh;
            double dsq = dx * dx + dy * dy;
            if (dsq < best_sq) {
                best_sq = dsq;
                best_idx = j;
                best_dx = dx;
                best_dy = dy;
            }
        }
        if (best_idx < 0) {
            list_append_owned(result, make_null());
        } else {
            Value *r = make_dict(8);
            dict_set_owned(r, "index", make_num(best_idx));
            dict_set_owned(r, "dist", make_num(sqrt(best_sq)));
            dict_set_owned(r, "dx", make_num(best_dx));
            dict_set_owned(r, "dy", make_num(best_dy));
            list_append_owned(result, r);  /* adopt the freshly-built dict */
        }
    }

    free(px_arr);
    free(py_arr);
    free(active_arr);
    free(valid_arr);
    return result;
}

/* dispatch of [table, key, arg] — O(1) function dispatch.
   table: list of functions (or null for unused slots).
   key: integer index into the table.
   arg: value passed to the selected function.
   Returns the function's return value, or null if slot is empty. */
/* ---- Typed numeric buffers (flat double arrays) ---- */

/* buffer of count — create a zero-filled numeric buffer */
Value* builtin_buffer(Value *arg) {
    /* buffer of [rows, cols] -> shaped 2-D buffer (flat double[rows*cols]) */
    if (arg && arg->type == VAL_LIST && arg->data.list.count == 2 &&
        arg->data.list.items[0]->type == VAL_NUM &&
        arg->data.list.items[1]->type == VAL_NUM) {
        int r = (int)arg->data.list.items[0]->data.num;
        int c = (int)arg->data.list.items[1]->data.num;
        if (r < 0) r = 0;
        if (c < 0) c = 0;
        long total = (long)r * (long)c;
        if (total > 10000000) { r = 0; c = 0; total = 0; }
        if (!sandbox_charge((size_t)total * sizeof(double))) return make_null();  /* #292 */
        Value *v = xcalloc(1, sizeof(Value));
        v->type = VAL_BUFFER;
        v->data.buffer.count = (int)total;
        v->data.buffer.rows = r;
        v->data.buffer.cols = c;
        v->data.buffer.data = xcalloc(total > 0 ? (size_t)total : 1, sizeof(double));
        v->refcount = 1;
        return v;
    }
    int count = 0;
    if (arg && arg->type == VAL_NUM) count = (int)arg->data.num;
    if (count < 0) count = 0;
    if (count > 10000000) count = 10000000;
    if (!sandbox_charge((size_t)count * sizeof(double))) return make_null();  /* #292 */
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = count;
    v->data.buffer.data = xcalloc(count, sizeof(double));
    v->refcount = 1;
    return v;
}

/* reshape of [buf, rows, cols] -> a shaped copy of the flat buffer (rows*cols
 * must equal the element count). */
Value* builtin_reshape(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *b = arg->data.list.items[0];
    if (b->type != VAL_BUFFER) return make_null();
    if (arg->data.list.items[1]->type != VAL_NUM ||
        arg->data.list.items[2]->type != VAL_NUM) return make_null();
    int r = (int)arg->data.list.items[1]->data.num;
    int c = (int)arg->data.list.items[2]->data.num;
    if (r < 0 || c < 0 || (long)r * (long)c != (long)b->data.buffer.count) return make_null();
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = b->data.buffer.count;
    v->data.buffer.rows = r;
    v->data.buffer.cols = c;
    v->data.buffer.data = xcalloc(b->data.buffer.count > 0 ? (size_t)b->data.buffer.count : 1, sizeof(double));
    memcpy(v->data.buffer.data, b->data.buffer.data, (size_t)b->data.buffer.count * sizeof(double));
    v->refcount = 1;
    return v;
}

/* buf_get of [buf, index] — O(1) indexed read */
Value* builtin_buf_get(Value *arg) {
    /* #502: out-of-range used to fold to 0 — indistinguishable from a real
     * stored 0. Raise index_range, matching the buffer `[i]` operator. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "buf_get requires [buffer, index]");
        return make_num(0);
    }
    Value *buf = arg->data.list.items[0];
    if (!buf || buf->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_get: first argument must be a buffer");
        return make_num(0);
    }
    int idx = (int)arg->data.list.items[1]->data.num;
    if (idx < 0 || idx >= buf->data.buffer.count) {
        rt_error(EK_INDEX, 0, "buffer index %d out of range (length %d)",
                 idx, buf->data.buffer.count);
        return make_num(0);
    }
    return make_num(buf->data.buffer.data[idx]);
}

/* buf_set of [buf, index, value] — O(1) indexed write */
Value* builtin_buf_set(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {  /* #502 */
        rt_error(EK_TYPE, 0, "buf_set requires [buffer, index, value]");
        return make_null();
    }
    Value *buf = arg->data.list.items[0];
    if (!buf || buf->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_set: first argument must be a buffer");
        return make_null();
    }
    int idx = (int)arg->data.list.items[1]->data.num;
    double val = arg->data.list.items[2]->data.num;
    if (idx < 0 || idx >= buf->data.buffer.count) {
        rt_error(EK_INDEX, 0, "buffer index %d out of range (length %d)",
                 idx, buf->data.buffer.count);
        return make_null();
    }
    buf->data.buffer.data[idx] = val;
    return make_null();
}

/* buf_len of buf — return buffer length */
Value* builtin_buf_len(Value *arg) {
    if (!arg || arg->type != VAL_BUFFER) return make_num(0);
    return make_num(arg->data.buffer.count);
}

/* buf_from_list of list — convert list of numbers to buffer */
Value* builtin_buf_from_list(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int n = arg->data.list.count;
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = n;
    v->data.buffer.data = xcalloc(n > 0 ? n : 1, sizeof(double));
    v->refcount = 1;
    for (int i = 0; i < n; i++) {
        if (arg->data.list.items[i]->type == VAL_NUM)
            v->data.buffer.data[i] = arg->data.list.items[i]->data.num;
    }
    return v;
}

/* str_from_bytes of <list|buffer of byte ints> → string of those raw bytes.
 * Reconstructs a native string from its bytes (the inverse of an `ord` loop);
 * the list form of scalar `chr` (chr of n == str_from_bytes of [n] for
 * 1..255). EigenScript strings are NUL-terminated, so a 0 byte ends the
 * string; binary data that may contain NUL must stay in a buffer.
 * Surfaced by tidelog's CBOR text-string decoder. */
Value* builtin_str_from_bytes(Value *arg) {
    int n = 0;
    Value **items = NULL;
    double *bufd = NULL;
    if (arg && arg->type == VAL_LIST) {
        n = arg->data.list.count;
        items = arg->data.list.items;
    } else if (arg && arg->type == VAL_BUFFER) {
        n = arg->data.buffer.count;
        bufd = arg->data.buffer.data;
    } else {
        return make_str("");
    }
    char *s = xcalloc((size_t)(n > 0 ? n : 0) + 1, 1);
    int len = 0;
    for (int i = 0; i < n; i++) {
        double dv = items ? (items[i] && items[i]->type == VAL_NUM ? items[i]->data.num : 0.0)
                          : bufd[i];
        int b = (int)dv & 0xFF;
        if (b == 0) break;            /* C-string terminates at NUL */
        s[len++] = (char)b;
    }
    s[len] = '\0';
    return make_str_owned(s);
}

/* f64_to_bytes of x → list of 8 ints: the big-endian IEEE-754 double encoding
 * of x (CBOR major-type 7 / network byte order). Portable across endianness —
 * the host bit pattern is captured via memcpy, then bytes are extracted with
 * explicit shifts, yielding the standard IEEE-754 layout on any platform. */
Value* builtin_f64_to_bytes(Value *arg) {
    double d = (arg && arg->type == VAL_NUM) ? arg->data.num : 0.0;
    uint64_t bits;
    memcpy(&bits, &d, sizeof(bits));
    Value *list = make_list(8);
    for (int i = 0; i < 8; i++) {
        int shift = 8 * (7 - i);
        list_append_owned(list, make_num((double)((bits >> shift) & 0xFFu)));
    }
    return list;
}

/* f64_from_bytes of <list|buffer of 8 big-endian bytes> → the decoded double.
 * Inverse of f64_to_bytes; reads exactly the first 8 bytes. */
Value* builtin_f64_from_bytes(Value *arg) {
    double bytes_in[8] = {0,0,0,0,0,0,0,0};
    if (arg && arg->type == VAL_LIST) {
        int n = arg->data.list.count;
        for (int i = 0; i < 8 && i < n; i++)
            if (arg->data.list.items[i] && arg->data.list.items[i]->type == VAL_NUM)
                bytes_in[i] = arg->data.list.items[i]->data.num;
    } else if (arg && arg->type == VAL_BUFFER) {
        int n = arg->data.buffer.count;
        for (int i = 0; i < 8 && i < n; i++)
            bytes_in[i] = arg->data.buffer.data[i];
    } else {
        return make_num(0);
    }
    uint64_t bits = 0;
    for (int i = 0; i < 8; i++)
        bits = (bits << 8) | (uint64_t)((int)bytes_in[i] & 0xFF);
    double d;
    memcpy(&d, &bits, sizeof(d));
    return make_num(d);
}

/* write_bytes of [path, data, append?] — write raw bytes to a file.
 * `data` is a list of byte ints or a buffer (values taken mod 256). `append`
 * (optional, default 0): 0 truncates the file, nonzero appends. Returns the
 * number of bytes written, or 0 on failure. Unlike write_text this is
 * binary-clean — NUL bytes are written verbatim, not treated as terminators —
 * so it can carry CBOR / arbitrary binary. Surfaced by tidelog's append-only
 * log (write_text is truncate-mode and NUL-truncating). */
#if !EIGENSCRIPT_FREESTANDING
Value* builtin_write_bytes(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *data = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR) return make_num(0);
    int append = 0;
    if (arg->data.list.count >= 3 && arg->data.list.items[2] &&
        arg->data.list.items[2]->type == VAL_NUM)
        append = (arg->data.list.items[2]->data.num != 0.0);

    int n = 0;
    Value **items = NULL;
    double *bufd = NULL;
    if (data && data->type == VAL_LIST) {
        n = data->data.list.count;
        items = data->data.list.items;
    } else if (data && data->type == VAL_BUFFER) {
        n = data->data.buffer.count;
        bufd = data->data.buffer.data;
    } else {
        return make_num(0);
    }

    unsigned char *out = xmalloc((size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) {
        double dv = items ? (items[i] && items[i]->type == VAL_NUM ? items[i]->data.num : 0.0)
                          : bufd[i];
        out[i] = (unsigned char)((int)dv & 0xFF);
    }
    FILE *f = xfopen_write(path_val->data.str, append ? "ab" : "wb");
    if (!f) { free(out); return make_num(0); }
    size_t written = fwrite(out, 1, (size_t)n, f);
    int close_ok = (fclose(f) == 0);
    free(out);
    return make_num((close_ok && written == (size_t)n) ? (double)written : 0);
}
#endif /* !EIGENSCRIPT_FREESTANDING */

/* ---- Vectorized buffer kernels (#597) ----
 * Shared window validation for the bulk buf_* family. All of these read
 * offsets/counts as 64-bit and bound with subtraction (off > n - count),
 * never addition (off + count > n): the int-add form let two large
 * offsets overflow negative, pass both checks, and drive memmove out of
 * bounds. Bounds failures RAISE (index_range / value), matching the
 * #490-#512 direction (buf_get/buf_set/set_at) — no silent truncation:
 * a clamped audio mix is a silently wrong render. */
static int buf_count_arg(const char *who, Value *cnt_val, long long *out) {
    if (!cnt_val || cnt_val->type != VAL_NUM) {
        rt_error(EK_VALUE, 0, "%s: count must be a number", who);
        return 0;
    }
    long long c = (long long)cnt_val->data.num;
    if (c < 0) {
        rt_error(EK_VALUE, 0, "%s: count must be non-negative (got %lld)",
                 who, c);
        return 0;
    }
    *out = c;
    return 1;
}

static int buf_num_arg(const char *who, const char *what, Value *v,
                       double *out) {
    if (!v || v->type != VAL_NUM) {
        rt_error(EK_VALUE, 0, "%s: %s must be a number", who, what);
        return 0;
    }
    *out = v->data.num;
    return 1;
}

/* Validate one (buffer, offset, count) window. On success writes the
 * offset and returns 1; on failure raises and returns 0. count must
 * already be validated non-negative (buf_count_arg). */
static int buf_window_arg(const char *who, Value *buf, Value *off_val,
                          long long count, long long *out_off) {
    if (!buf || buf->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "%s: expected a buffer", who);
        return 0;
    }
    if (!off_val || off_val->type != VAL_NUM) {
        rt_error(EK_VALUE, 0, "%s: offset must be a number", who);
        return 0;
    }
    long long off = (long long)off_val->data.num;
    long long n = buf->data.buffer.count;
    if (off < 0 || off > n - count) {
        rt_error(EK_INDEX, 0,
                 "%s: window [%lld, %lld) out of range (length %lld)",
                 who, off, off + count, n);
        return 0;
    }
    *out_off = off;
    return 1;
}

/* buf_copy of [src, src_off, dst, dst_off, count] — bulk copy between buffers.
 * #597: bad bounds used to return null silently; they now raise like the
 * rest of the family (the crash-safety guarantee — no OOB memmove — holds
 * either way). count 0 is a valid no-op. */
Value* builtin_buf_copy(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 5) {
        rt_error(EK_TYPE, 0, "buf_copy requires [src, src_off, dst, dst_off, count]");
        return make_null();
    }
    Value *src = arg->data.list.items[0];
    Value *dst = arg->data.list.items[2];
    long long count, src_off, dst_off;
    if (!buf_count_arg("buf_copy", arg->data.list.items[4], &count) ||
        !buf_window_arg("buf_copy", src, arg->data.list.items[1], count, &src_off) ||
        !buf_window_arg("buf_copy", dst, arg->data.list.items[3], count, &dst_off))
        return make_null();
    if (count == 0) return make_null();
    memmove(&dst->data.buffer.data[dst_off], &src->data.buffer.data[src_off],
            (size_t)count * sizeof(double));
    return make_null();
}

/* buf_mix of [dst, src, dst_off, src_off, count, gain] —
 * dst[dst_off+i] += src[src_off+i] * gain, in place. The audio mix-down
 * kernel (DeslanStudio's ab_mix_into): one C loop instead of ~441k
 * dispatched VM iterations per stem pass. Arithmetic mirrors the VM
 * (num_guard per step) so the result is byte-identical to the
 * equivalent interpreted loop. dst and src may be the same buffer with
 * overlapping windows; the loop runs forward in index order (documented,
 * deterministic). Returns null. */
Value* builtin_buf_mix(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 6) {
        rt_error(EK_TYPE, 0, "buf_mix requires [dst, src, dst_off, src_off, count, gain]");
        return make_null();
    }
    Value *dst = arg->data.list.items[0];
    Value *src = arg->data.list.items[1];
    long long count, dst_off, src_off;
    double gain;
    if (!buf_count_arg("buf_mix", arg->data.list.items[4], &count) ||
        !buf_window_arg("buf_mix", dst, arg->data.list.items[2], count, &dst_off) ||
        !buf_window_arg("buf_mix", src, arg->data.list.items[3], count, &src_off) ||
        !buf_num_arg("buf_mix", "gain", arg->data.list.items[5], &gain))
        return make_null();
    double *dd = &dst->data.buffer.data[dst_off];
    double *sd = &src->data.buffer.data[src_off];
    for (long long i = 0; i < count; i++)
        dd[i] = num_guard(dd[i] + num_guard(sd[i] * gain));
    return make_null();
}

/* buf_scale_range of [b, off, count, gain] — in-place multiply over a
 * window: b[off+i] *= gain (num_guard per element, VM-identical).
 * Fades/normalize. Returns null. */
Value* builtin_buf_scale_range(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) {
        rt_error(EK_TYPE, 0, "buf_scale_range requires [buffer, off, count, gain]");
        return make_null();
    }
    Value *buf = arg->data.list.items[0];
    long long count, off;
    double gain;
    if (!buf_count_arg("buf_scale_range", arg->data.list.items[2], &count) ||
        !buf_window_arg("buf_scale_range", buf, arg->data.list.items[1], count, &off) ||
        !buf_num_arg("buf_scale_range", "gain", arg->data.list.items[3], &gain))
        return make_null();
    double *d = &buf->data.buffer.data[off];
    for (long long i = 0; i < count; i++)
        d[i] = num_guard(d[i] * gain);
    return make_null();
}

/* buf_fill of [b, off, count, value] — bulk store over a window:
 * b[off+i] = value (stored verbatim, like buf_set). Silence gaps,
 * click-free zeroing. Returns null. */
Value* builtin_buf_fill(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) {
        rt_error(EK_TYPE, 0, "buf_fill requires [buffer, off, count, value]");
        return make_null();
    }
    Value *buf = arg->data.list.items[0];
    long long count, off;
    double val;
    if (!buf_count_arg("buf_fill", arg->data.list.items[2], &count) ||
        !buf_window_arg("buf_fill", buf, arg->data.list.items[1], count, &off) ||
        !buf_num_arg("buf_fill", "value", arg->data.list.items[3], &val))
        return make_null();
    double *d = &buf->data.buffer.data[off];
    for (long long i = 0; i < count; i++)
        d[i] = val;
    return make_null();
}

/* buf_peak of [b, off, count] — max |x| over a window (normalize and
 * meter scans). An empty window peaks at 0. */
Value* builtin_buf_peak(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_peak requires [buffer, off, count]");
        return make_num(0);
    }
    Value *buf = arg->data.list.items[0];
    long long count, off;
    if (!buf_count_arg("buf_peak", arg->data.list.items[2], &count) ||
        !buf_window_arg("buf_peak", buf, arg->data.list.items[1], count, &off))
        return make_num(0);
    double *d = &buf->data.buffer.data[off];
    double m = 0.0;
    for (long long i = 0; i < count; i++) {
        double a = d[i] < 0 ? -d[i] : d[i];
        if (a > m) m = a;
    }
    return make_num(m);
}

/* buf_dot of [a, b, a_off, b_off, count] — windowed dot product:
 * sum over i of a[a_off+i] * b[b_off+i]. The YIN-autocorrelation
 * kernel. Same contract as `dot`: the summation ORDER / ASSOCIATION is
 * UNSPECIFIED (a backend may reassociate across SIMD lanes) — programs
 * needing a strict left-to-right reduction write the explicit loop.
 * no-NaN/Inf is preserved (num_guard at each step). */
Value* builtin_buf_dot(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 5) {
        rt_error(EK_TYPE, 0, "buf_dot requires [a, b, a_off, b_off, count]");
        return make_num(0);
    }
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    long long count, a_off, b_off;
    if (!buf_count_arg("buf_dot", arg->data.list.items[4], &count) ||
        !buf_window_arg("buf_dot", a, arg->data.list.items[2], count, &a_off) ||
        !buf_window_arg("buf_dot", b, arg->data.list.items[3], count, &b_off))
        return make_num(0);
    double *ad = &a->data.buffer.data[a_off];
    double *bd = &b->data.buffer.data[b_off];
    double s = 0.0;
    for (long long i = 0; i < count; i++)
        s = num_guard(s + num_guard(ad[i] * bd[i]));
    return make_num(s);
}

/* ---- Bulk PCM16LE codec kernels (#602) ----
 * The byte-decode siblings of the #597 window kernels: DeslanStudio's
 * WAV import spent 10.8 s decoding a 50 s stereo file sample-by-sample
 * in the interpreter (src/tools/wavio.eigs). Each kernel mirrors the
 * consumer's interpreted arithmetic step-for-step (num_guard per VM
 * operation, same evaluation order), so the result is bit-identical to
 * the loop it replaces — pinned by the differential leg in
 * tests/test_pcm_codec.eigs. Pure compute over arguments: sandbox
 * pure-compute allowlist (allocation charged per #292),
 * freestanding-safe, tape-neutral. */

/* Allocate a fresh flat VAL_BUFFER of `count` doubles, or NULL if the
 * sandbox allocation budget (#292) rejects it (sandbox_charge raises). */
static Value* buf_alloc_flat(long long count) {
    if (!sandbox_charge((size_t)count * sizeof(double))) return NULL;
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = (int)count;
    v->data.buffer.data = xcalloc(count > 0 ? (size_t)count : 1, sizeof(double));
    v->refcount = 1;
    return v;
}

/* buf_from_pcm16le of [bytes, byte_off, count] — decode `count`
 * little-endian signed 16-bit PCM samples starting at byte_off into a
 * NEW float buffer. Exactly wavio's wav_read arithmetic:
 *   v = b0 + 256*b1;  if v >= 32768: v -= 65536;  sample = v / 32767 */
Value* builtin_buf_from_pcm16le(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_from_pcm16le requires [bytes, byte_off, count]");
        return make_null();
    }
    Value *src = arg->data.list.items[0];
    long long count, off;
    if (!buf_count_arg("buf_from_pcm16le", arg->data.list.items[2], &count))
        return make_null();
    if (count > (long long)INT_MAX / 2) { /* 2*count below cannot overflow */
        rt_error(EK_LIMIT, 0, "buf_from_pcm16le: count %lld over the buffer size limit", count);
        return make_null();
    }
    if (!buf_window_arg("buf_from_pcm16le", src, arg->data.list.items[1],
                        count * 2, &off))
        return make_null();
    Value *out = buf_alloc_flat(count);
    if (!out) return make_null();
    const double *sd = &src->data.buffer.data[off];
    double *od = out->data.buffer.data;
    for (long long i = 0; i < count; i++) {
        double v = num_guard(sd[2*i] + num_guard(256.0 * sd[2*i + 1]));
        if (v >= 32768.0) v = num_guard(v - 65536.0);
        od[i] = num_guard(v / 32767.0);
    }
    return out;
}

/* buf_to_pcm16le of [floats, off, count] — encode `count` samples from
 * `off` into a NEW byte buffer (2 doubles per sample, LE order).
 * Exactly wavio's wav_write arithmetic: clamp to [-1, 1] (ds_clamp's
 * two independent comparisons), v = round(x * 32767), two's complement
 * via +65536, low byte = v - floor(v/256)*256 (the ds_fmod expansion),
 * high byte = floor(v/256). */
Value* builtin_buf_to_pcm16le(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_to_pcm16le requires [floats, off, count]");
        return make_null();
    }
    Value *src = arg->data.list.items[0];
    long long count, off;
    if (!buf_count_arg("buf_to_pcm16le", arg->data.list.items[2], &count))
        return make_null();
    if (count > (long long)INT_MAX / 2) { /* output is 2*count elements */
        rt_error(EK_LIMIT, 0, "buf_to_pcm16le: count %lld over the buffer size limit", count);
        return make_null();
    }
    if (!buf_window_arg("buf_to_pcm16le", src, arg->data.list.items[1],
                        count, &off))
        return make_null();
    Value *out = buf_alloc_flat(count * 2);
    if (!out) return make_null();
    const double *sd = &src->data.buffer.data[off];
    double *od = out->data.buffer.data;
    for (long long i = 0; i < count; i++) {
        double x = sd[i];
        if (x < -1.0) x = -1.0;
        if (x > 1.0) x = 1.0;
        double v = round(num_guard(x * 32767.0));
        if (v < 0.0) v = num_guard(v + 65536.0);
        double q = floor(num_guard(v / 256.0));
        od[2*i]     = num_guard(v - num_guard(q * 256.0));
        od[2*i + 1] = q;
    }
    return out;
}

/* buf_deinterleave of [src, channel, nch, count?] — every nch-th sample
 * starting at index `channel` into a NEW buffer (frame-interleaved
 * channel split; wavio addresses sample (i, c) at i*nch + c). count
 * defaults to the full available tail. Pure copy — no arithmetic. */
Value* builtin_buf_deinterleave(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_deinterleave requires [src, channel, nch, count?]");
        return make_null();
    }
    Value *src = arg->data.list.items[0];
    if (!src || src->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_deinterleave: expected a buffer");
        return make_null();
    }
    Value *ch_v = arg->data.list.items[1];
    Value *nch_v = arg->data.list.items[2];
    if (!ch_v || ch_v->type != VAL_NUM || !nch_v || nch_v->type != VAL_NUM) {
        rt_error(EK_VALUE, 0, "buf_deinterleave: channel and nch must be numbers");
        return make_null();
    }
    long long nch = (long long)nch_v->data.num;
    long long channel = (long long)ch_v->data.num;
    if (nch < 1) {
        rt_error(EK_VALUE, 0, "buf_deinterleave: nch must be >= 1 (got %lld)", nch);
        return make_null();
    }
    if (channel < 0 || channel >= nch) {
        rt_error(EK_VALUE, 0, "buf_deinterleave: channel %lld out of range for %lld channels",
                 channel, nch);
        return make_null();
    }
    long long n = src->data.buffer.count;
    long long avail = channel < n ? (n - channel + nch - 1) / nch : 0;
    long long count = avail;
    if (arg->data.list.count >= 4 && arg->data.list.items[3] &&
        arg->data.list.items[3]->type != VAL_NULL) {
        if (!buf_count_arg("buf_deinterleave", arg->data.list.items[3], &count))
            return make_null();
        if (count > avail) {
            rt_error(EK_INDEX, 0,
                     "buf_deinterleave: count %lld over the %lld samples available "
                     "(length %lld, channel %lld of %lld)",
                     count, avail, n, channel, nch);
            return make_null();
        }
    }
    Value *out = buf_alloc_flat(count);
    if (!out) return make_null();
    const double *sd = src->data.buffer.data;
    double *od = out->data.buffer.data;
    for (long long i = 0; i < count; i++)
        od[i] = sd[channel + i * nch];
    return out;
}

/* ---- buf_resample_linear (#603) ----
 * buf_resample_linear of [src, dst_len] — endpoint-inclusive linear
 * resample into a NEW buffer. Exactly DeslanStudio's ab_resample_linear
 * mapping (src/daw/audio_buf.eigs):
 *   pos  = i * (n - 1) / (dst_len - 1)      (0 when dst_len == 1)
 *   lo   = floor(pos); hi = min(lo + 1, n - 1); frac = pos - lo
 *   out[i] = src[lo] * (1 - frac) + src[hi] * frac
 * num_guard per step in VM evaluation order — bit-identical to the
 * interpreted loop (differential-pinned in tests/test_buf_resample.eigs).
 * The kernel is LINEAR interpolation, not Fourier/sinc resampling (the
 * consumer-documented divergence from scipy.signal.resample — see
 * BUILTINS.md). dst_len 0 -> empty buffer; empty src with dst_len > 0
 * raises `value` (the consumer's wrapper guards n == 0 itself). */
Value* builtin_buf_resample_linear(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "buf_resample_linear requires [src, dst_len]");
        return make_null();
    }
    Value *src = arg->data.list.items[0];
    if (!src || src->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_resample_linear: expected a buffer");
        return make_null();
    }
    long long dst_len;
    if (!buf_count_arg("buf_resample_linear", arg->data.list.items[1], &dst_len))
        return make_null();
    if (dst_len > (long long)INT_MAX) {
        rt_error(EK_LIMIT, 0, "buf_resample_linear: dst_len %lld over the buffer size limit", dst_len);
        return make_null();
    }
    long long n = src->data.buffer.count;
    if (n == 0 && dst_len > 0) {
        rt_error(EK_VALUE, 0, "buf_resample_linear: cannot resample an empty buffer to length %lld", dst_len);
        return make_null();
    }
    Value *out = buf_alloc_flat(dst_len);
    if (!out) return make_null();
    const double *sd = src->data.buffer.data;
    double *od = out->data.buffer.data;
    for (long long i = 0; i < dst_len; i++) {
        double pos = 0.0;
        if (dst_len > 1)
            pos = num_guard(num_guard((double)i * (double)(n - 1)) /
                            (double)(dst_len - 1));
        double lo_f = floor(pos);
        long long lo = (long long)lo_f;
        long long hi = lo + 1;
        if (hi > n - 1) hi = n - 1;
        /* pos is in [0, n-1] by construction (the i = dst_len-1 quotient
         * is exactly n-1, and an exact-integer product / exact divisor
         * cannot round past it); the clamps below are pure memory-safety
         * belts, unreachable for real inputs — the interpreted oracle
         * would raise index_range where these would fire. */
        if (lo < 0) lo = 0;
        if (lo > n - 1) lo = n - 1;
        if (hi < 0) hi = 0;
        double frac = num_guard(pos - lo_f);
        od[i] = num_guard(num_guard(sd[lo] * num_guard(1.0 - frac)) +
                          num_guard(sd[hi] * frac));
    }
    return out;
}

/* sign_extend of [val, bits] — sign-extend val from given bit width.
 * E.g. sign_extend of [0xFF, 8] → -1 */
Value* builtin_sign_extend(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    double val = arg->data.list.items[0]->data.num;
    int bits = (int)arg->data.list.items[1]->data.num;
    if (bits <= 0 || bits > 32) return make_num(val);
    int64_t mask = 1LL << (bits - 1);
    if ((int64_t)val & mask)
        return make_num((double)((int64_t)val - (1LL << bits)));
    return make_num(val);
}

/* list_truncate of [list, new_len] — shrink list in-place to new_len items.
 * If new_len >= current length, no-op. Returns the list. */
Value* builtin_list_truncate(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "list_truncate requires [list, new_len]");
        return make_null();
    }
    Value *list = arg->data.list.items[0];
    Value *len_val = arg->data.list.items[1];
    if (!list || list->type != VAL_LIST) {
        rt_error(EK_TYPE, 0, "list_truncate: first argument must be a list");
        return make_null();
    }
    if (!len_val || len_val->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "list_truncate: new_len must be a number");
        return make_null();
    }
    int new_len = (int)len_val->data.num;
    /* #503: a negative new_len used to silently empty the list (an
     * undocumented soft clamp to 0). Raise instead. */
    if (new_len < 0) {
        rt_error(EK_VALUE, 0, "list_truncate: new_len must be >= 0 (got %d)", new_len);
        return make_null();
    }
    if (new_len >= list->data.list.count) return list;
    for (int i = new_len; i < list->data.list.count; i++) {
        val_decref(list->data.list.items[i]);
        list->data.list.items[i] = NULL;
    }
    list->data.list.count = new_len;
    return list;
}

/* list_remove_at of [list, index] — remove element at index, shift tail down.
 * Out-of-bounds index is a no-op. Returns the list. */
Value* builtin_list_remove_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *list = arg->data.list.items[0];
    Value *idx_val = arg->data.list.items[1];
    if (!list || list->type != VAL_LIST) return make_null();
    if (!idx_val || idx_val->type != VAL_NUM) return list;
    int idx = (int)idx_val->data.num;
    if (idx < 0 || idx >= list->data.list.count) return list;
    val_decref(list->data.list.items[idx]);
    int tail = list->data.list.count - idx - 1;
    if (tail > 0)
        memmove(&list->data.list.items[idx], &list->data.list.items[idx + 1],
                tail * sizeof(Value *));
    list->data.list.count--;
    return list;
}

/* sort_by of [list, key_fn] — sort list by numeric keys from key_fn.
 * Evaluates key_fn once per element, then qsorts by key (ascending).
 * Stable tiebreak by original index. Returns a NEW sorted list. */
typedef struct { double key; int index; } SortByPair;

static int sort_by_pair_cmp(const void *a, const void *b) {
    double da = ((const SortByPair *)a)->key;
    double db = ((const SortByPair *)b)->key;
    if (da < db) return -1;
    if (da > db) return  1;
    return ((const SortByPair *)a)->index - ((const SortByPair *)b)->index;
}

Value* builtin_sort_by(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_null();
    Value *list = arg->data.list.items[0];
    Value *key_fn = arg->data.list.items[1];
    if (!list || list->type != VAL_LIST) return make_null();
    if (!key_fn || (key_fn->type != VAL_FN && key_fn->type != VAL_BUILTIN))
        return make_null();
    int n = list->data.list.count;
    if (n == 0) return make_list(0);
    SortByPair *pairs = calloc(n, sizeof(SortByPair));
    if (!pairs) return make_null();
    for (int i = 0; i < n; i++) {
        Value *kv = call_eigs_fn(key_fn, list->data.list.items[i]);
        /* #501: a non-numeric key used to coerce to 0.0 — a silent wrong
         * order. Raise instead (mirrors `sort` #368). */
        if (!kv || kv->type != VAL_NUM) {
            const char *kt = kv ? val_type_name(kv->type) : "null";
            if (kv) val_decref(kv);
            free(pairs);
            rt_error(EK_TYPE, 0,
                "sort_by: key function must return a number (element %d "
                "gave %s)", i, kt);
            return make_null();
        }
        pairs[i].key = kv->data.num;
        pairs[i].index = i;
        val_decref(kv);
    }
    qsort(pairs, n, sizeof(SortByPair), sort_by_pair_cmp);
    Value *result = make_list(n);
    for (int i = 0; i < n; i++) {
        list_append(result, list->data.list.items[pairs[i].index]);
    }
    free(pairs);
    return result;
}

/* sort of list — in-place qsort of an all-number or all-string list.
 * Anything else raises (#368): the old comparator returned 0 for any
 * non-numeric pair, so sorting a list of records silently no-oped —
 * with libc-dependent element order on top (qsort gives no stability
 * guarantee for all-equal elements). Record sorting is sort_by's job. */
static int sort_cmp_num(const void *a, const void *b) {
    double da = (*(Value**)a)->data.num, db = (*(Value**)b)->data.num;
    return (da > db) - (da < db);
}

static int sort_cmp_str(const void *a, const void *b) {
    return strcmp((*(Value**)a)->data.str, (*(Value**)b)->data.str);
}

Value* builtin_sort(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return arg ? arg : make_null();
    ValType t = arg->data.list.items[0] ? arg->data.list.items[0]->type
                                        : VAL_NULL;
    for (int i = 0; i < arg->data.list.count; i++) {
        Value *v = arg->data.list.items[i];
        if (!v || v->type != t || (t != VAL_NUM && t != VAL_STR)) {
            rt_error(EK_TYPE, 0, "sort requires all numbers or all strings "
                          "(element %d is %s); use sort_by for records",
                          i, v ? val_type_name(v->type) : "null");
            return make_null();
        }
    }
    qsort(arg->data.list.items, arg->data.list.count, sizeof(Value*),
          t == VAL_NUM ? sort_cmp_num : sort_cmp_str);
    return arg;
}

Value* builtin_dispatch(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "dispatch requires [table, key, arg]");
        return make_null();
    }
    Value *table = arg->data.list.items[0];
    Value *key_v = arg->data.list.items[1];
    Value *fn_arg = arg->data.list.items[2];

    /* Key validation mirrors OP_DISPATCH (#353): a non-number key used to
     * reinterpret whatever union member the value carried as a double. */
    if (!key_v || key_v->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "dispatch: key must be a number");
        return make_null();
    }
    int key = (int)key_v->data.num;
    if ((double)key != key_v->data.num) {
        rt_error(EK_VALUE, 0, "dispatch key must be an integer, got %g",
                      key_v->data.num);
        return make_null();
    }

    if (!table || table->type != VAL_LIST) {
        rt_error(EK_TYPE, 0, "dispatch: table must be a list");
        return make_null();
    }
    if (key < 0 || key >= table->data.list.count) {
        return make_null();
    }
    Value *fn = table->data.list.items[key];
    if (!fn || fn->type == VAL_NULL) {
        return make_null();
    }

    if (fn->type == VAL_BUILTIN) {
        return fn->data.builtin(fn_arg);
    }

    if (fn->type == VAL_FN) {
        Env *call_env = env_new(fn->data.fn.closure);
        if (fn->data.fn.param_count > 0) {
            env_set_local(call_env, fn->data.fn.params[0], fn_arg);
        }
        if (fn->data.fn.body_count == -1) {
            /* Bytecode function */
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            if (fn_chunk->local_count > fn->data.fn.param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);
            Value *result = vm_execute(fn_chunk, call_env);
            env_decref(call_env);
            return result ? result : make_null();
        }
        /* AST-based function — should not happen after bytecode migration */
        env_decref(call_env);
        return make_null();
    }

    rt_error(EK_TYPE, 0, "dispatch: slot %d is not a function", key);
    return make_null();
}

/* ==== association-unspecified reduction: dot ====
 * `dot of [a, b]` = sum over i of a[i]*b[i] for two numeric buffers (length =
 * the shorter of the two). SPEC: the summation ORDER / ASSOCIATION is
 * UNSPECIFIED — callers must not depend on the exact low-bit rounding of the
 * result. This is the deliberate opt-in that licenses a backend (e.g. the AOT
 * native compiler) to REASSOCIATE the sum across SIMD lanes; programs that
 * need a strict left-to-right reduction write the explicit `loop while`
 * accumulation instead. no-NaN/Inf is preserved (num_guard at each step), so
 * the result still respects EigenScript's no-NaN/Inf invariant. */
static Value* builtin_dot(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    if (!a || !b || a->type != VAL_BUFFER || b->type != VAL_BUFFER)
        return make_num(0);
    int n = a->data.buffer.count;
    if (b->data.buffer.count < n) n = b->data.buffer.count;
    double *ad = a->data.buffer.data, *bd = b->data.buffer.data;
    double s = 0.0;
    for (int i = 0; i < n; i++)
        s = num_guard(s + num_guard(ad[i] * bd[i]));
    return make_num(s);
}

#if EIGS_BORROW_GUARD
/* #548 planted fault: deliberately violates the borrow-scan invariant by
 * returning a borrowed direct child PAST VM_BORROW_SCAN_CAP. Exists only
 * to prove the guard converts a missed borrow into a loud abort — a
 * checker nobody has watched fail is not a checker. Registered only in
 * sanitizer builds AND under EIGS_BORROW_GUARD_SELFTEST, so fuzzers
 * (whose harnesses are ASan builds) can never reach a deliberate abort. */
static Value* builtin_borrow_guard_selftest(Value *arg) {
    if (arg && arg->type == VAL_LIST &&
        arg->data.list.count > VM_BORROW_SCAN_CAP)
        return arg->data.list.items[arg->data.list.count - 1];
    return NULL;   /* VM substitutes null: not enough args to violate */
}
#endif

void register_builtins(Env *env) {
    /* ---- Core language builtins (always available) ---- */
    env_set_local_owned(env, "print", make_builtin(builtin_print));
    env_set_local_owned(env, "write", make_builtin(builtin_write));
    env_set_local_owned(env, "flush", make_builtin(builtin_flush));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "raw_key", make_builtin(builtin_raw_key));
#endif /* !EIGENSCRIPT_FREESTANDING */
    env_set_local_owned(env, "usleep", make_builtin(builtin_usleep));
    env_set_local_owned(env, "monotonic_ns", make_builtin(builtin_monotonic_ns));
    env_set_local_owned(env, "monotonic_ms", make_builtin(builtin_monotonic_ms));
    env_set_local_owned(env, "join", make_builtin(builtin_join));
    env_set_local_owned(env, "text_builder_new", make_builtin(builtin_text_builder_new));
    env_set_local_owned(env, "text_builder_append", make_builtin(builtin_text_builder_append));
    env_set_local_owned(env, "text_builder_append_line", make_builtin(builtin_text_builder_append_line));
    env_set_local_owned(env, "text_builder_extend", make_builtin(builtin_text_builder_extend));
    env_set_local_owned(env, "text_builder_part_count", make_builtin(builtin_text_builder_part_count));
    env_set_local_owned(env, "text_builder_clear", make_builtin(builtin_text_builder_clear));
    env_set_local_owned(env, "text_builder_to_string", make_builtin(builtin_text_builder_to_string));
    env_set_local_owned(env, "bit_and", make_builtin(builtin_bit_and));
    env_set_local_owned(env, "bit_or", make_builtin(builtin_bit_or));
    env_set_local_owned(env, "bit_xor", make_builtin(builtin_bit_xor));
    env_set_local_owned(env, "bit_not", make_builtin(builtin_bit_not));
    env_set_local_owned(env, "bit_shl", make_builtin(builtin_bit_shift_left));
    env_set_local_owned(env, "bit_shr", make_builtin(builtin_bit_shift_right));
    env_set_local_owned(env, "screen_put", make_builtin(builtin_screen_put));
    env_set_local_owned(env, "screen_clear", make_builtin(builtin_screen_clear));
    env_set_local_owned(env, "screen_end", make_builtin(builtin_screen_end));
    env_set_local_owned(env, "screen_render", make_builtin(builtin_screen_render));
    env_set_local_owned(env, "len", make_builtin(builtin_len));
    env_set_local_owned(env, "str", make_builtin(builtin_str));
    env_set_local_owned(env, "num", make_builtin(builtin_num));
    env_set_local_owned(env, "append", make_builtin(builtin_append));
    env_set_local_owned(env, "report", make_builtin(builtin_report));
    env_set_local_owned(env, "set_observer_thresholds", make_builtin(builtin_set_observer_thresholds));
    env_set_local_owned(env, "get_observer_thresholds", make_builtin(builtin_get_observer_thresholds));
    env_set_local_owned(env, "assert", make_builtin(builtin_assert));
    env_set_local_owned(env, "exit", make_builtin(builtin_exit));
    env_set_local_owned(env, "throw", make_builtin(builtin_throw));
    env_set_local_owned(env, "keys", make_builtin(builtin_keys));
    env_set_local_owned(env, "values", make_builtin(builtin_values));
    env_set_local_owned(env, "has_key", make_builtin(builtin_has_key));
    env_set_local_owned(env, "dict_set", make_builtin(builtin_dict_set));
    env_set_local_owned(env, "dict_remove", make_builtin(builtin_dict_remove));
    env_set_local_owned(env, "observe", make_builtin(builtin_observe));
    env_set_local_owned(env, "classify", make_builtin(builtin_classify));
    env_set_local_owned(env, "type", make_builtin(builtin_type));
    env_set_local_owned(env, "json_encode", make_builtin(builtin_json_encode));
    env_set_local_owned(env, "json_decode", make_builtin(builtin_json_decode));
    env_set_local_owned(env, "coalesce", make_builtin(builtin_coalesce));
    env_set_local_owned(env, "json_build", make_builtin(builtin_json_build));
    env_set_local_owned(env, "json_raw", make_builtin(builtin_json_raw));
    env_set_local_owned(env, "json_path", make_builtin(builtin_json_path));
    env_set_local_owned(env, "str_lower", make_builtin(builtin_str_lower));
    env_set_local_owned(env, "str_upper", make_builtin(builtin_str_upper));
    env_set_local_owned(env, "char_at", make_builtin(builtin_char_at));
    env_set_local_owned(env, "ends_with", make_builtin(builtin_ends_with));
    env_set_local_owned(env, "substr", make_builtin(builtin_substr));
    env_set_local_owned(env, "index_of", make_builtin(builtin_index_of));
    env_set_local_owned(env, "sin", make_builtin(builtin_sin));
    env_set_local_owned(env, "cos", make_builtin(builtin_cos));
    env_set_local_owned(env, "tan", make_builtin(builtin_tan));
    env_set_local_owned(env, "asin", make_builtin(builtin_asin));
    env_set_local_owned(env, "acos", make_builtin(builtin_acos));
    env_set_local_owned(env, "atan", make_builtin(builtin_atan));
    env_set_local_owned(env, "atan2", make_builtin(builtin_atan2));
    env_set_local_owned(env, "floor", make_builtin(builtin_floor));
    env_set_local_owned(env, "ceil", make_builtin(builtin_ceil));
    env_set_local_owned(env, "round", make_builtin(builtin_round));
    env_set_local_owned(env, "abs", make_builtin(builtin_abs));
    env_set_local_owned(env, "min", make_builtin(builtin_min));
    env_set_local_owned(env, "max", make_builtin(builtin_max));
    env_set_local_owned(env, "pi", make_builtin(builtin_pi));
    env_set_local_owned(env, "random", make_builtin(builtin_random));
    env_set_local_owned(env, "random_int", make_builtin(builtin_random_int));
    env_set_local_owned(env, "seed_random", make_builtin(builtin_seed_random));
    env_set_local_owned(env, "args", make_builtin(builtin_args));
    env_set_local_owned(env, "path_join", make_builtin(builtin_path_join));
    env_set_local_owned(env, "path_dir", make_builtin(builtin_path_dir));
    env_set_local_owned(env, "path_base", make_builtin(builtin_path_base));
    env_set_local_owned(env, "path_ext", make_builtin(builtin_path_ext));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "mkdir", make_builtin(builtin_mkdir));
    env_set_local_owned(env, "ls", make_builtin(builtin_ls));
    env_set_local_owned(env, "getcwd", make_builtin(builtin_getcwd));
    env_set_local_owned(env, "exe_path", make_builtin(builtin_exe_path));
    env_set_local_owned(env, "chdir", make_builtin(builtin_chdir));
    env_set_local_owned(env, "mktemp", make_builtin(builtin_mktemp));
    env_set_local_owned(env, "rm", make_builtin(builtin_rm));
#endif /* !EIGENSCRIPT_FREESTANDING */
    env_set_local_owned(env, "free_val", make_builtin(builtin_free_val));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "stream_open", make_builtin(builtin_stream_open));
    env_set_local_owned(env, "stream_write", make_builtin(builtin_stream_write));
    env_set_local_owned(env, "stream_close", make_builtin(builtin_stream_close));
    env_set_local_owned(env, "build_corpus", make_builtin(builtin_build_corpus));
#endif /* !EIGENSCRIPT_FREESTANDING */
    env_set_local_owned(env, "contains", make_builtin(builtin_contains));
    env_set_local_owned(env, "starts_with", make_builtin(builtin_starts_with));
    env_set_local_owned(env, "split", make_builtin(builtin_split));
    env_set_local_owned(env, "scan_ints", make_builtin(builtin_scan_ints));
    env_set_local_owned(env, "scan_tokens", make_builtin(builtin_scan_tokens));
    env_set_local_owned(env, "scan_int_tokens", make_builtin(builtin_scan_int_tokens));
    env_set_local_owned(env, "trim", make_builtin(builtin_trim));
    env_set_local_owned(env, "str_replace", make_builtin(builtin_str_replace));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "regex_match", make_builtin(builtin_match));
    env_set_local_owned(env, "regex_find", make_builtin(builtin_match_all));
    env_set_local_owned(env, "regex_replace", make_builtin(builtin_regex_replace));
    env_set_local_owned(env, "load_file", make_builtin(builtin_load_file));
    env_set_local_owned(env, "file_exists", make_builtin(builtin_file_exists));
    env_set_local_owned(env, "is_dir", make_builtin(builtin_is_dir));
    env_set_local_owned(env, "rename", make_builtin(builtin_rename));
    env_set_local_owned(env, "remove_file", make_builtin(builtin_remove_file));
#endif /* !EIGENSCRIPT_FREESTANDING */
    env_set_local_owned(env, "env_get", make_builtin(builtin_env_get));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "read_bytes", make_builtin(builtin_read_bytes));
    env_set_local_owned(env, "read_bytes_buf", make_builtin(builtin_read_bytes_buf));
    env_set_local_owned(env, "read_text", make_builtin(builtin_read_text));
    env_set_local_owned(env, "read_line", make_builtin(builtin_read_line));
    env_set_local_owned(env, "write_text", make_builtin(builtin_write_text));
    env_set_local_owned(env, "write_bytes", make_builtin(builtin_write_bytes));
    env_set_local_owned(env, "exec_capture", make_builtin(builtin_exec_capture));
    env_set_local_owned(env, "proc_spawn", make_builtin(builtin_proc_spawn));
    env_set_local_owned(env, "proc_write", make_builtin(builtin_proc_write));
    env_set_local_owned(env, "proc_read_line", make_builtin(builtin_proc_read_line));
    env_set_local_owned(env, "proc_read", make_builtin(builtin_proc_read));
    env_set_local_owned(env, "proc_read_buf", make_builtin(builtin_proc_read_buf));
    env_set_local_owned(env, "proc_close", make_builtin(builtin_proc_close));
    env_set_local_owned(env, "proc_wait", make_builtin(builtin_proc_wait));
#endif /* !EIGENSCRIPT_FREESTANDING */

    /* ---- Tensor / math stdlib (always available) ---- */
    env_set_local_owned(env, "dot", make_builtin(builtin_dot));
    env_set_local_owned(env, "matmul", make_builtin(builtin_tensor_matmul));
    env_set_local_owned(env, "add", make_builtin(builtin_tensor_add));
    env_set_local_owned(env, "subtract", make_builtin(builtin_tensor_subtract));
    env_set_local_owned(env, "multiply", make_builtin(builtin_tensor_multiply));
    env_set_local_owned(env, "divide", make_builtin(builtin_tensor_divide));
    env_set_local_owned(env, "pow", make_builtin(builtin_tensor_pow));
    env_set_local_owned(env, "sqrt", make_builtin(builtin_tensor_sqrt));
    env_set_local_owned(env, "exp", make_builtin(builtin_tensor_exp));
    env_set_local_owned(env, "log", make_builtin(builtin_tensor_log));
    env_set_local_owned(env, "negative", make_builtin(builtin_tensor_negative));
    env_set_local_owned(env, "softmax", make_builtin(builtin_tensor_softmax));
    env_set_local_owned(env, "log_softmax", make_builtin(builtin_tensor_log_softmax));
    env_set_local_owned(env, "relu", make_builtin(builtin_tensor_relu));
    env_set_local_owned(env, "leaky_relu", make_builtin(builtin_tensor_leaky_relu));
    env_set_local_owned(env, "mean", make_builtin(builtin_tensor_mean));
    env_set_local_owned(env, "sum", make_builtin(builtin_tensor_sum));
    env_set_local_owned(env, "norm", make_builtin(builtin_tensor_norm));
    env_set_local_owned(env, "zeros", make_builtin(builtin_tensor_zeros));
    env_set_local_owned(env, "zeros_like", make_builtin(builtin_tensor_zeros_like));
    env_set_local_owned(env, "gather", make_builtin(builtin_tensor_gather));
    env_set_local_owned(env, "set_at", make_builtin(builtin_set_at));
    env_set_local_owned(env, "get_at", make_builtin(builtin_get_at));
    env_set_local_owned(env, "random_normal", make_builtin(builtin_random_normal));
    env_set_local_owned(env, "shape", make_builtin(builtin_tensor_shape));
    env_set_local_owned(env, "numerical_grad", make_builtin(builtin_numerical_grad));
    env_set_local_owned(env, "numerical_grad_rows", make_builtin(builtin_numerical_grad_rows));
    env_set_local_owned(env, "sgd_update", make_builtin(builtin_sgd_update));
    env_set_local_owned(env, "sgd_update_rows", make_builtin(builtin_sgd_update_rows));
    env_set_local_owned(env, "numerical_grad_cols", make_builtin(builtin_numerical_grad_cols));
    env_set_local_owned(env, "sgd_update_cols", make_builtin(builtin_sgd_update_cols));
    env_set_local_owned(env, "tokenize_ids", make_builtin(builtin_tokenize_ids));
    env_set_local_owned(env, "tokenize_with_names", make_builtin(builtin_tokenize_with_names));
    env_set_local_owned(env, "token_name", make_builtin(builtin_token_name));
    env_set_local_owned(env, "chr", make_builtin(builtin_chr));
    env_set_local_owned(env, "hex", make_builtin(builtin_hex));
    env_set_local_owned(env, "ord", make_builtin(builtin_ord));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "random_hex", make_builtin(builtin_random_hex));
#endif /* !EIGENSCRIPT_FREESTANDING */
    env_set_local_owned(env, "state_at", make_builtin(builtin_state_at));
    env_set_local_owned(env, "secure_equals", make_builtin(builtin_secure_equals));
    env_set_local_owned(env, "try_parse", make_builtin(builtin_try_parse));
    env_set_local_owned(env, "eval", make_builtin(builtin_eval));
    env_set_local_owned(env, "vm_run_bytecode", make_builtin(builtin_vm_run_bytecode));
    env_set_local_owned(env, "record_history", make_builtin(builtin_record_history));
    env_set_local_owned(env, "sandbox_run", make_builtin(builtin_sandbox_run));
#if !EIGENSCRIPT_FREESTANDING
    env_set_local_owned(env, "tensor_save", make_builtin(builtin_tensor_save));
    env_set_local_owned(env, "tensor_load", make_builtin(builtin_tensor_load));
#endif /* !EIGENSCRIPT_FREESTANDING */
    env_set_local_owned(env, "copy_into", make_builtin(builtin_copy_into));
    env_set_local_owned(env, "num_copy", make_builtin(builtin_num_copy));
    env_set_local_owned(env, "concat", make_builtin(builtin_concat));
    env_set_local_owned(env, "range", make_builtin(builtin_range));
    env_set_local_owned(env, "arena_mark", make_builtin(builtin_arena_mark));
    env_set_local_owned(env, "arena_reset", make_builtin(builtin_arena_reset));
    env_set_local_owned(env, "arena_stats", make_builtin(builtin_arena_stats));

    /* ---- Concurrency builtins ---- */
    env_set_local_owned(env, "spawn", make_builtin(builtin_spawn));
    env_set_local_owned(env, "task_spawn", make_builtin(builtin_task_spawn));
    env_set_local_owned(env, "task_alive", make_builtin(builtin_task_alive));
    env_set_local_owned(env, "task_self", make_builtin(builtin_task_self));
    env_set_local_owned(env, "task_detach", make_builtin(builtin_task_detach));
    env_set_local_owned(env, "task_yield", make_builtin(builtin_task_yield));
    env_set_local_owned(env, "must_not_yield", make_builtin(builtin_must_not_yield));
    env_set_local_owned(env, "task_join", make_builtin(builtin_task_join));
    env_set_local_owned(env, "task_send", make_builtin(builtin_task_send));
    env_set_local_owned(env, "task_recv", make_builtin(builtin_task_recv));
    env_set_local_owned(env, "task_try_recv", make_builtin(builtin_task_try_recv));
    env_set_local_owned(env, "task_kill", make_builtin(builtin_task_kill));
    env_set_local_owned(env, "task_sleep", make_builtin(builtin_task_sleep));
    env_set_local_owned(env, "task_now", make_builtin(builtin_task_now));
    env_set_local_owned(env, "task_sched_seed", make_builtin(builtin_task_sched_seed));
    env_set_local_owned(env, "thread_join", make_builtin(builtin_thread_join));
    env_set_local_owned(env, "channel", make_builtin(builtin_channel));
    env_set_local_owned(env, "send", make_builtin(builtin_send));
    env_set_local_owned(env, "recv", make_builtin(builtin_recv));
    env_set_local_owned(env, "try_recv", make_builtin(builtin_try_recv));
    env_set_local_owned(env, "recv_timeout", make_builtin(builtin_recv_timeout));
    env_set_local_owned(env, "nearest_in_range", make_builtin(builtin_nearest_in_range));
    env_set_local_owned(env, "nearest_in_range_all", make_builtin(builtin_nearest_in_range_all));
    env_set_local_owned(env, "dispatch", make_builtin(builtin_dispatch));
    env_set_local_owned(env, "fill", make_builtin(builtin_fill));
    env_set_local_owned(env, "buffer", make_builtin(builtin_buffer));
    env_set_local_owned(env, "reshape", make_builtin(builtin_reshape));
    env_set_local_owned(env, "buf_get", make_builtin(builtin_buf_get));
    env_set_local_owned(env, "buf_set", make_builtin(builtin_buf_set));
    env_set_local_owned(env, "buf_len", make_builtin(builtin_buf_len));
    env_set_local_owned(env, "buf_from_list", make_builtin(builtin_buf_from_list));
    env_set_local_owned(env, "str_from_bytes", make_builtin(builtin_str_from_bytes));
    env_set_local_owned(env, "f64_to_bytes", make_builtin(builtin_f64_to_bytes));
    env_set_local_owned(env, "f64_from_bytes", make_builtin(builtin_f64_from_bytes));
    env_set_local_owned(env, "buf_copy", make_builtin(builtin_buf_copy));
    env_set_local_owned(env, "buf_mix", make_builtin(builtin_buf_mix));
    env_set_local_owned(env, "buf_scale_range", make_builtin(builtin_buf_scale_range));
    env_set_local_owned(env, "buf_fill", make_builtin(builtin_buf_fill));
    env_set_local_owned(env, "buf_peak", make_builtin(builtin_buf_peak));
    env_set_local_owned(env, "buf_dot", make_builtin(builtin_buf_dot));
    env_set_local_owned(env, "buf_from_pcm16le", make_builtin(builtin_buf_from_pcm16le));
    env_set_local_owned(env, "buf_to_pcm16le", make_builtin(builtin_buf_to_pcm16le));
    env_set_local_owned(env, "buf_deinterleave", make_builtin(builtin_buf_deinterleave));
    env_set_local_owned(env, "buf_resample_linear", make_builtin(builtin_buf_resample_linear));
    env_set_local_owned(env, "sign_extend", make_builtin(builtin_sign_extend));
    env_set_local_owned(env, "sort", make_builtin(builtin_sort));
    env_set_local_owned(env, "list_truncate", make_builtin(builtin_list_truncate));
    env_set_local_owned(env, "list_remove_at", make_builtin(builtin_list_remove_at));
    env_set_local_owned(env, "sort_by", make_builtin(builtin_sort_by));
    env_set_local_owned(env, "close_channel", make_builtin(builtin_close_channel));
    env_set_local_owned(env, "channel_closed", make_builtin(builtin_channel_closed));

    /* ---- Hash builtins (sha256, md5, hmac) ---- */
    register_hash_builtins(env);

#if EIGENSCRIPT_EXT_HTTP
    register_http_builtins(env);
#endif

#if EIGENSCRIPT_EXT_DB
    register_db_builtins(env);
#endif

#if EIGENSCRIPT_EXT_MODEL
    register_model_builtins(env);
#endif

#if EIGS_BORROW_GUARD
    /* #548 guard self-test hook — see builtin_borrow_guard_selftest. */
    if (getenv("EIGS_BORROW_GUARD_SELFTEST"))
        env_set_local_owned(env, "__borrow_guard_selftest", make_builtin(builtin_borrow_guard_selftest));
#endif
}
