/*
 * EigenScript built-in functions.
 * Core language builtins plus the registration table.
 * Extension builtins (HTTP, DB, model) live in ext_*.c and model_*.c.
 * Host-only builtins — everything needing a filesystem, subprocesses, a
 * terminal, POSIX regex, or /dev/urandom — live in builtins_host.c (#741),
 * whole-TU gated for the freestanding profile. A new builtin that touches
 * the OS goes THERE, not behind an #ifdef here.
 */

#include "eigenscript.h"
#include "env_flag.h"
#include "state.h"
#include "vm.h"
#include "builtins_internal.h"
#include "trace.h"
#include <limits.h>

#if defined(__GLIBC__) && !EIGENSCRIPT_FREESTANDING
#include <malloc.h>   /* mallinfo2, for builtin_heap_inuse (#770) */
#endif

/* TRACE_NONDET_RET lives in trace.h — centralized in Phase 3 so the
 * replay short-circuit applies to every nondet builtin uniformly. */

#include <pthread.h>

#if EIGENSCRIPT_EXT_HTTP
#include "ext_http_internal.h"
#endif

#if EIGENSCRIPT_EXT_DB
#include "ext_db_internal.h"
#endif

#if EIGENSCRIPT_EXT_NET
#include "ext_net_internal.h"
#include <unistd.h>   /* close() in handle_table_drain's HANDLE_NET pass */
#endif

#if EIGENSCRIPT_EXT_MODEL
#include "model_internal.h"
#endif

#if EIGENSCRIPT_EXT_ZLIB
#include <zlib.h>
#endif

/* How many bindings the runtime itself installs.
 *
 * register_builtins fills the global env from slot 0 upward and nothing in the
 * language ever unbinds a name, so slots [0, g_builtin_binding_count) are
 * exactly the runtime's own registry and everything a user script defines lands
 * after it. Set at the end of register_builtins; 0 until then.
 *
 * This exists because "is this name part of the language?" cannot be answered
 * by looking up the LIVE global env: by the time a script calls a builtin, its
 * own top-level functions are in that env too, and they are indistinguishable
 * from stdlib entries by Value type alone. */
static int g_builtin_binding_count = 0;

/* True iff `name` is a name the runtime registered, as opposed to one the
 * running script defined. Deliberately allocation-free — the suite gates on a
 * zero leak tally, and a process-lifetime name snapshot would show up there. */
int eigs_is_registered_builtin(const char *name) {
    if (!name || !g_global_env) return 0;
    int n = g_builtin_binding_count;
    if (n > g_global_env->count) n = g_global_env->count;
    for (int i = 0; i < n; i++) {
        if (g_global_env->names[i] && strcmp(g_global_env->names[i], name) == 0)
            return 1;
    }
    return 0;
}

/* Internal helpers defined in eigenscript.c. */
Value* make_num_permanent(double n);
const char* val_type_name(ValType t);
int dict_has(Value *dict, const char *key);
void dict_remove(Value *dict, const char *key);

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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "join", "[list, separator]", make_str(""));
    Value *list = arg->data.list.items[0];
    Value *sep_val = arg->data.list.items[1];
    ARG_GUARD(!list || list->type != VAL_LIST, "join", "a list as its first argument", make_str(""));
    /* Coercion, not a guard — a non-string separator silently became "" and
     * the elements ran together (`join of [["a","b"], 42]` was "ab"). Same
     * class as str_replace, and it has no stand-in return, so it is invisible
     * to tools/failsoft_classify_check.sh and needs STRICT_REQUIRE. Found by
     * a blind review, not by either harness. */
    STRICT_REQUIRE(sep_val && sep_val->type != VAL_STR, "join", "a string separator");
    const char *sep = (sep_val && sep_val->type == VAL_STR) ? sep_val->data.str : "";
    size_t sep_len = strlen(sep);

    /* First pass: compute total length */
    int count = list->data.list.count;
    /* fs:EMPTY joining no elements produces no characters; "" is the identity
     * of concatenation, not a rejected argument. */
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

    /* #292/#followup: join is output-proportional (total = sum(parts) +
     * sep_len * (count-1)) and was the one allowlisted string allocator left
     * uncharged after the concat fix — `join of [[s, s], ""]` was the same
     * doubling primitive through a side door, and a large-const-input join
     * drove the uncatchable x_oom abort through an armed 1000-byte budget
     * (blind round, 2026-08-17). Charge the output before allocating. */
    if (!sandbox_charge(total + 1)) {
        for (int i = 0; i < count; i++) free(parts[i]);
        free(parts);
        free(lengths);
        return make_null();
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

    /* #965: total+1 was charged above — take ownership, no second charge. */
    return make_str_owned(result);
}

/* Growth chokepoint for every text_builder op (append/append_line/extend):
 * the sandbox byte budget is charged on the cap DELTA here, so a sandboxed
 * program cannot grow a builder past max_bytes — uncharged, a 50000-append
 * loop over a charged-but-large string reached the uncatchable x_oom abort
 * from inside grade()'s own generation vocabulary (blind round, 2026-08-17).
 * Returns 0 on refusal (charge already raised catchable EK_SANDBOX); the
 * caller must not write. */
static int text_builder_reserve(Value *builder, size_t extra) {
    size_t need = builder->data.text_builder.len + extra + 1;
    if (need <= builder->data.text_builder.cap) return 1;
    size_t cap = builder->data.text_builder.cap ? builder->data.text_builder.cap : 256;
    while (cap < need) {
        if (cap > ((size_t)-1) / 2) {
            cap = need;
            break;
        }
        cap *= 2;
    }
    if (!sandbox_charge(cap - builder->data.text_builder.cap)) return 0;
    builder->data.text_builder.data = xrealloc(builder->data.text_builder.data, cap);
    builder->data.text_builder.cap = cap;
    return 1;
}

static void text_builder_append_raw(Value *builder, const char *s, int count_part) {
    if (!builder || builder->type != VAL_TEXT_BUILDER || !s) return;
    size_t n = strlen(s);
    if (!text_builder_reserve(builder, n)) return;
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
    ARG_GUARD(!arg || arg->type != VAL_TEXT_BUILDER, "text_builder_part_count", "a text builder", make_num(0));
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
    ARG_GUARD(!arg || arg->type != VAL_TEXT_BUILDER, "text_builder_to_string", "a text builder", make_str(""));
    /* The final copy duplicates the (charge-bounded) buffer — charge it too. */
    if (!sandbox_charge(arg->data.text_builder.len + 1)) return make_null();
    /* #965: charged just above — take ownership of the duplicate. */
    return make_str_owned(xstrdup(arg->data.text_builder.data ? arg->data.text_builder.data : ""));
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

/* clock_unix of null — seconds since the Unix epoch from CLOCK_REALTIME
 * (wall clock, sub-second precision). A clock read is nondeterministic, so
 * the value goes through the tape seam like every other nondet input:
 * recorded under EIGS_TRACE, served back under EIGS_REPLAY (#683). */
Value* builtin_clock_unix(Value *arg) {
    (void)arg;
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    TRACE_NONDET_RET("clock_unix", make_num((double)ts.tv_sec + (double)ts.tv_nsec / 1e9));
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
    /* fs:CHANNEL the rt_error above has already raised UNCONDITIONALLY — this
     * is only the C return value the compiler requires. `len` is the reform's
     * finished state, not a candidate for it. */
    return make_num(0);
}

Value* builtin_str(Value *arg) {
    char *s = value_to_string(arg);
    /* #965: value_to_string builds list/dict text in a strbuf whose payload
     * is already charged (reserve growth + finish shortfall) — take ownership
     * of that buffer (make_str_owned, no second charge, no copy). Every
     * other type returns an uncharged xstrdup, so the copying constructor
     * charges it there. */
    if (arg && (arg->type == VAL_LIST || arg->type == VAL_DICT))
        return make_str_owned(s);
    Value *v = make_str(s);
    free(s);
    return v;
}

/* Every `return make_num(0)` in this function is fs:ANSWER, and the reason is
 * one reason: BUILTINS.md documents `num` as "Convert to number (parse string
 * or COERCE)". A coercion's whole contract is that it accepts anything and
 * answers, so 0 here is the documented result rather than a stand-in for a
 * rejected argument — the opposite of `cos of "hello"`.
 *
 * This is the sharpest ANSWER case in the file and worth stating plainly: it
 * IS reachable as a laundering path (`num of [1,2,3]` is 0, and a typo that
 * hands `num` a list scores as a real zero). Making it loud is a change to
 * `num`'s documented contract, not a completion of this reform, so it is out
 * of scope here and belongs in its own issue if wanted. */
Value* builtin_num(Value *arg) {
    if (!arg) return make_num(0);       /* fs:ANSWER coercion contract, see above */
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
            /* fs:ANSWER "0x" with no hex digit converts to 0 like any other
             * non-numeric string — the partial-parse contract this comment
             * block documents. */
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
    if (arg->type == VAL_NULL) return make_num(0);   /* fs:ANSWER coercion contract */
    return make_num(0);                              /* fs:ANSWER coercion contract */
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
     * trajectory → the no-observation band, "equilibrium".
     * #708: a function/builtin operand answers "opaque" here too, matching
     * the slot-keyed forms — a fn has no content the observer can sample. */
    if (arg && (arg->type == VAL_FN || arg->type == VAL_BUILTIN))
        return make_str("opaque");
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

/* exit of N — request a clean process exit with code N (default 0). Sets the
 * unwind flag (g_has_error) so vm_run returns to main, plus g_exit_requested so
 * the unwind is UNCATCHABLE (a `try` must not swallow `exit`) and main exits
 * with the code after its normal teardown — leak-clean, unlike a raw exit().
 * #739: the request lives on EigsThread, beside the g_has_error / g_try_depth
 * it is consulted with — as a process global nothing ever reset it, so one
 * script's `exit` disabled try/catch for every later eval in the PROCESS, in
 * any state. The exit CODE is additionally latched at the EigsState, so `exit`
 * inside a spawned worker still decides the process's status. */
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
    g_exit_requested = 1;      /* this thread's unwind: uncatchable */
    g_exit_latch_code = code;  /* the state's: what main reports as the */
    g_exit_latched = 1;        /* process exit code, incl. from a worker */
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
    /* The sandbox error latch belongs to the whole run, not to one producer.
     * Do not let this direct error writer replace a prior allocation refusal. */
    if (g_sandbox_active && g_sandbox_error_latched) {
        g_has_error = 1;
        return make_null();
    }
    char *msg = value_to_string(arg);
    snprintf(g_error_msg, sizeof(g_error_msg), "%s", msg);
    snprintf(g_error_raw, sizeof(g_error_raw), "%s", msg);
    g_error_kind = (int)EK_USER;
    g_error_line = vm_current_line();
    if (g_sandbox_active) g_sandbox_error_latched = 1;
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
    ARG_GUARD(arg->type != VAL_LIST || arg->data.list.count < 2, "has_key", "[dict, key]", make_num(0));
    Value *d = arg->data.list.items[0];
    Value *key = arg->data.list.items[1];
    ARG_GUARD(d->type != VAL_DICT || key->type != VAL_STR, "has_key", "[dict, string]", make_num(0));
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
    /* #861: the explicit channels must not route — "entropy" answers from the
     * entropy classifier even for a numeric trajectory (that is the point of
     * asking for it by name); "value" was always the numeric classifier. */
    const char *label = (strcmp(channel, "entropy") == 0)
                        ? observer_slot_report_entropy(&s)
                        : observer_slot_report_value(&s);
    Value *out = make_str(label ? label : "equilibrium");
    free(s.dh_window);
    free(s.v_window);
    free(s.vr_window);
    return out;
}

/* ---- #865: sticky numeric status ----
 *
 * The finite-number invariant (NaN -> 0, overflow -> +/-1e308) keeps a
 * program running, which is the point, but it kept it running with a
 * plausible number and no way to tell. Two consequences the contract did not
 * mention: reassociation silently changes a result by 292 orders of magnitude
 * ((1e300*1e300)/1e300 is 1e8, not 1e300), and an overflowed value compares
 * equal to itself under further growth, so no in-language predicate could
 * distinguish "this is 1e308" from "this overflowed".
 *
 * These are IEEE-754's sticky exception flags. The results are unchanged —
 * the finite invariant is load-bearing for the JIT's bail comparison, the
 * observer's entropy, `str of`, and the JSON encoders — but the clamp is no
 * longer undetectable. Bracket a computation the way you would an FPU:
 *
 *     clear_math_flags of null
 *     result is risky_computation of xs
 *     if (math_flags of null).overflow:
 *         ...
 */
Value* builtin_math_flags(Value *arg) {
    (void)arg;
    Value *d = make_dict(3);
    Value *ov = make_num((g_math_flags & EIGS_MATH_OVERFLOW) ? 1 : 0);
    Value *iv = make_num((g_math_flags & EIGS_MATH_INVALID) ? 1 : 0);
    Value *uv = make_num((g_math_flags & EIGS_MATH_UNDERFLOW) ? 1 : 0);
    dict_set_owned(d, "overflow", ov);
    dict_set_owned(d, "invalid", iv);
    dict_set_owned(d, "underflow", uv);
    return d;
}

Value* builtin_clear_math_flags(Value *arg) {
    (void)arg;
    g_math_flags = 0;
    return make_null();
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

/* Bound JSON nesting depth: each array/object descent is a C recursion, so
 * untrusted input like "[[[[...]]]]" would otherwise exhaust the C stack and
 * crash (SIGSEGV). 200 is far beyond any legitimate document. Shared by the
 * decoder (which has enforced it since #495) and the encoder (#730). */
#define JSON_MAX_DEPTH 200

/* The encoder walks a Value graph, and a Value graph can contain cycles — the
 * cycle collector exists precisely because it can. `d is {}` then
 * `dict_set of [d, "self", d]` is two lines, and `append of [a, a]` builds one
 * by accident. Without a bound the walk recurses until the C stack is gone: a
 * SIGSEGV, which `try`/`catch` cannot catch because it is not a runtime error.
 *
 * The decoder has been bounded at JSON_MAX_DEPTH since #495; the encoder is the
 * asymmetry. Same limit here so the two directions agree: a document that
 * decodes must re-encode.
 *
 * Depth rides the C stack rather than a thread-local counter — it cannot leak
 * across a bail-out and it is reentrant for free. Returns 0, or -1 once the
 * limit is hit; every caller propagates so the walk unwinds instead of
 * finishing a truncated document. The entry points turn the -1 into a catchable
 * rt_error rather than emitting `null`: a silently truncated document here
 * would be the exact silent-wrong-answer class the 0.33.0 audit was closing. */
#define JSON_ENCODE_MAX_DEPTH JSON_MAX_DEPTH

static int eigs_json_encode_value(Value *v, strbuf *out, int depth) {
    if (!v || v->type == VAL_NULL || v->type == VAL_FN || v->type == VAL_BUILTIN) {
        strbuf_append(out, "null");
        return 0;
    }
    if ((v->type == VAL_LIST || v->type == VAL_DICT) && depth >= JSON_ENCODE_MAX_DEPTH)
        return -1;
    switch (v->type) {
        case VAL_NUM: {
            /* #875: one shared rule with `str of` — exact integers to 2^53
             * bare, otherwise the shortest round-tripping form. The local
             * %d fast path stopped at 2^31 and handed everything above it
             * to %.15g, so integer IDs between 2^31 and 2^53 came back as a
             * different number. */
            char nb[32];
            eigs_num_text(nb, sizeof(nb), v->data.num);
            strbuf_append(out, nb);
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
                if (eigs_json_encode_value(v->data.list.items[i], out, depth + 1) != 0)
                    return -1;
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
                if (eigs_json_encode_value(v->data.dict.vals[i], out, depth + 1) != 0)
                    return -1;
            }
            strbuf_append_char(out, '}');
            break;
        }
        default:
            strbuf_append(out, "null");
            break;
    }
    return 0;
}

/* Shared by every entry point so the message is written once. */
static void json_encode_depth_error(const char *who) {
    rt_error(EK_VALUE, 0,
             "%s: value nests deeper than %d levels "
             "(a self-referential value will always exceed this)",
             who, JSON_ENCODE_MAX_DEPTH);
}

Value* builtin_json_encode(Value *arg) {
    strbuf out;
    strbuf_init(&out);
    if (eigs_json_encode_value(arg, &out, 0) != 0) {
        strbuf_free(&out);
        json_encode_depth_error("json_encode");
        return make_null();
    }
    /* #965: the strbuf payload is already charged (reserve growth + finish
     * shortfall); take ownership instead of copying (a copy would charge it twice). */
    Value *result = make_str_owned(strbuf_finish(&out));
    return result;
}

/* Returns NULL when the value is too deep to encode, having already raised.
 * Callers must check — the C-string entry point has no other way to say no. */
char* eigs_json_encode(Value *v) {
    strbuf out;
    strbuf_init(&out);
    if (eigs_json_encode_value(v, &out, 0) != 0) {
        strbuf_free(&out);
        json_encode_depth_error("json_encode");
        return NULL;
    }
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
 * raises on it. It is also checked mid-parse by the array/object propagation
 * guards, so it must be CLEAR at the start of every fresh parse — that reset
 * is owned by eigs_json_parse_root (#777), never by individual callers.
 * Callers other than json_decode don't read it after parsing and keep the
 * historical lenient behavior. Thread-local like g_json_depth because JSON
 * parsing is per-thread and non-reentrant across threads. */
static __thread int g_json_parse_err = 0;

/* #724: recoverable-parse flag — a SECOND channel, parallel to
 * g_json_parse_err, for conditions the parser can repair in place: an
 * unpaired surrogate, an escaped NUL, or a malformed \u escape inside a
 * string. Those denote one bad scalar, not a broken document, so the parser
 * substitutes U+FFFD and keeps going. The split matters: the #495
 * propagation checks in eigs_json_parse_array/object abort the container
 * parse on g_json_parse_err, which is right for structural damage (there is
 * nothing sensible past a truncation) but would silently DROP every sibling
 * after the offending string for lenient callers (json_path, ext_http) —
 * trading the old CESU-8-in-one-field bug for a lost-fields bug. Recoverable
 * conditions therefore never touch g_json_parse_err: lenient callers receive
 * the complete document with U+FFFD in the one bad string, and only
 * builtin_json_decode reads this flag to raise under strict decode. A side
 * benefit: a strict decode that raises on a recoverable condition leaves
 * g_json_parse_err CLEAR, so it does not poison the next lenient parse in
 * the same thread. Like g_json_parse_err it is reset by
 * eigs_json_parse_root (#777), never by individual callers. */
static __thread int g_json_parse_recoverable = 0;

/* #777: the one non-recursive entry point for a top-level JSON parse, and
 * the single owner of the parse flags' lifetime. eigs_json_parse_value is
 * recursive, so it cannot clear the flags itself — but the parser CHECKS
 * g_json_parse_err mid-parse (the array element and object first-key
 * propagation guards), so a flag left set by one malformed parse silently
 * truncated arrays and emptied objects for the NEXT caller in the same
 * thread (json_path, ext_http). Per-caller resets are how that bug happened
 * — json_decode remembered, every other caller forgot — so both channels are
 * cleared here instead: this wrapper is the one place that defines "fresh
 * parse". Callers must not touch the flags directly; builtin_json_decode
 * still reads them after the call to decide whether to raise, exactly as
 * before. */
Value* eigs_json_parse_root(const char *s, int *pos) {
    g_json_parse_err = 0;
    g_json_parse_recoverable = 0;
    return eigs_json_parse_value(s, pos);
}

static void eigs_json_skip_ws(const char *s, int *pos) {
    while (s[*pos] && (s[*pos] == ' ' || s[*pos] == '\t' || s[*pos] == '\n' || s[*pos] == '\r'))
        (*pos)++;
}

/* #724: encode one Unicode scalar as UTF-8 (1–4 bytes). Never called with
 * cp == 0 (strings are C-terminated and cannot carry NUL — EMBEDDING.md)
 * or with a surrogate-range cp (those are rejected by the caller). */
static void eigs_json_append_cp(strbuf *buf, unsigned int cp) {
    if (cp < 0x80) {
        strbuf_append_char(buf, (char)cp);
    } else if (cp < 0x800) {
        strbuf_append_char(buf, (char)(0xC0 | (cp >> 6)));
        strbuf_append_char(buf, (char)(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        strbuf_append_char(buf, (char)(0xE0 | (cp >> 12)));
        strbuf_append_char(buf, (char)(0x80 | ((cp >> 6) & 0x3F)));
        strbuf_append_char(buf, (char)(0x80 | (cp & 0x3F)));
    } else {
        strbuf_append_char(buf, (char)(0xF0 | (cp >> 18)));
        strbuf_append_char(buf, (char)(0x80 | ((cp >> 12) & 0x3F)));
        strbuf_append_char(buf, (char)(0x80 | ((cp >> 6) & 0x3F)));
        strbuf_append_char(buf, (char)(0x80 | (cp & 0x3F)));
    }
}

/* #724: read exactly four hex digits at s[*pos+1 .. *pos+4] (RFC 8259 §7).
 * On success *pos advances to the fourth digit, the scalar is returned via
 * *out, and the return is 1. On any non-hex digit — including the closing
 * quote or EOF arriving early — *pos is left unchanged and the return is 0.
 * Validating before converting matters: strtoul turns "zzzz" into 0,
 * indistinguishable from a real \u0000 escape, and the old read loop even
 * consumed the closing quote into the hex buffer on a short escape. */
static int eigs_json_read_hex4(const char *s, int *pos, unsigned int *out) {
    unsigned int cp = 0;
    for (int i = 1; i <= 4; i++) {
        char c = s[*pos + i];
        if (c >= '0' && c <= '9') cp = (cp << 4) | (unsigned int)(c - '0');
        else if (c >= 'a' && c <= 'f') cp = (cp << 4) | (unsigned int)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') cp = (cp << 4) | (unsigned int)(c - 'A' + 10);
        else return 0;
    }
    *pos += 4;
    *out = cp;
    return 1;
}

/* #880: THE JSON string-body decoder. `s[*pos]` is the first byte after the
 * opening quote; decodes into `out` and leaves *pos past the closing quote.
 *
 * Extracted so the LSP and DAP JSON-RPC readers share it instead of each
 * hand-rolling a five-escape subset. Both of those dropped \r, \b, \f and
 * \uXXXX and re-emitted the backslash verbatim, which made every CRLF
 * document unusable — JSON requires a CR to be escaped, so a Windows client's
 * text arrived with literal backslash-r in it and produced a bogus syntax
 * error and zero real diagnostics. */
void eigs_json_decode_string_body(const char *s, int *pos, strbuf *out) {
    while (s[*pos] && s[*pos] != '"') {
        if (s[*pos] == '\\') {
            (*pos)++;
            /* #776: a backslash as the final byte leaves s[*pos] on the NUL
             * terminator. Stop here — the default arm would append it and the
             * loop-bottom (*pos)++ would step past the NUL, so the loop guard
             * reads one byte off the end of the buffer (heap overflow). An
             * escape with nothing after it is truncation: the unterminated
             * string check below then raises, exactly as in the #304 lexer
             * fix one layer down. */
            if (s[*pos] == '\0') break;
            switch (s[*pos]) {
                case '"': strbuf_append_char(out, '"'); break;
                case '\\': strbuf_append_char(out, '\\'); break;
                case 'n': strbuf_append_char(out, '\n'); break;
                case 'r': strbuf_append_char(out, '\r'); break;
                case 't': strbuf_append_char(out, '\t'); break;
                /* #880: \b and \f are RFC 8259 escapes and were missing
                 * here as well — the default arm dropped the backslash, so
                 * json_decode silently turned "a\bc" into "abc". */
                case 'b': strbuf_append_char(out, '\b'); break;
                case 'f': strbuf_append_char(out, '\f'); break;
                case '/': strbuf_append_char(out, '/'); break;
                case 'u': {
                    unsigned int cp;
                    if (!eigs_json_read_hex4(s, pos, &cp)) {
                        /* #724: malformed escape (non-hex digit, or the
                         * closing quote / EOF before four digits). Strict
                         * decode raises; lenient callers get U+FFFD and the
                         * offending text is parsed normally from here. */
                        g_json_parse_recoverable = 1;
                        eigs_json_append_cp(out, 0xFFFD);
                        break;
                    }
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        /* #724: high surrogate — combine with an immediately
                         * following \uDC00-\uDFFF low-surrogate escape into one
                         * astral scalar (RFC 8259 / Unicode). Otherwise the
                         * surrogate is unpaired: strict raise + lenient
                         * U+FFFD, and the next escape/char parses normally. */
                        unsigned int lo = 0;
                        int paired = 0;
                        if (s[*pos + 1] == '\\' && s[*pos + 2] == 'u') {
                            int p2 = *pos + 2;
                            if (eigs_json_read_hex4(s, &p2, &lo) &&
                                lo >= 0xDC00 && lo <= 0xDFFF) {
                                *pos = p2;
                                paired = 1;
                            }
                        }
                        if (paired) {
                            cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                            eigs_json_append_cp(out, cp);
                        } else {
                            g_json_parse_recoverable = 1;
                            eigs_json_append_cp(out, 0xFFFD);
                        }
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        /* #724: lone low surrogate — strict raise + U+FFFD */
                        g_json_parse_recoverable = 1;
                        eigs_json_append_cp(out, 0xFFFD);
                    } else if (cp == 0) {
                        /* #724: NUL cannot live in a C-terminated string
                         * (EMBEDDING.md) — strict raise + lenient U+FFFD. */
                        g_json_parse_recoverable = 1;
                        eigs_json_append_cp(out, 0xFFFD);
                    } else {
                        eigs_json_append_cp(out, cp);
                    }
                    break;
                }
                default: strbuf_append_char(out, s[*pos]); break;
            }
        } else {
            strbuf_append_char(out, s[*pos]);
        }
        (*pos)++;
    }
    if (s[*pos] == '"') (*pos)++;
    else g_json_parse_err = 1;   /* #495: unterminated string (hit EOF) */
}

static Value* eigs_json_parse_string(const char *s, int *pos) {
    if (s[*pos] != '"') { g_json_parse_err = 1; return NULL; }   /* #495 */
    (*pos)++;
    strbuf buf;
    strbuf_init(&buf);
    eigs_json_decode_string_body(s, pos, &buf);
    /* #965: decode payload charged (reserve growth + finish shortfall) —
     * take ownership. */
    Value *v = make_str_owned(strbuf_finish(&buf));
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
        /* fs:CHANNEL failure is signalled out-of-band via g_json_parse_err; the 0 is a placeholder the caller never reads */
        g_json_parse_err = 1; *pos = p; return make_num(0);
    }
    while (isdigit((unsigned char)s[p])) p++;
    if (s[p] == '.') {
        p++;
        if (!isdigit((unsigned char)s[p])) {   /* "1." — frac needs digits */
            /* fs:CHANNEL failure is signalled out-of-band via g_json_parse_err; the 0 is a placeholder the caller never reads */
        g_json_parse_err = 1; *pos = p; return make_num(0);
        }
        while (isdigit((unsigned char)s[p])) p++;
    }
    if (s[p] == 'e' || s[p] == 'E') {
        p++;
        if (s[p] == '+' || s[p] == '-') p++;
        if (!isdigit((unsigned char)s[p])) {   /* "1e", "1e+" — exp needs digits */
            /* fs:CHANNEL failure is signalled out-of-band via g_json_parse_err; the 0 is a placeholder the caller never reads */
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

/* JSON_MAX_DEPTH is defined above the encoder, which shares it (#730).
 * g_json_depth lives on EigsThread (Phase 8); bridge macro from eigenscript.h. */

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
    /* fs:LITERAL this IS how JSON `false` is returned — 0 is the parsed VALUE,
     * not a stand-in for a rejected argument. A sweep over `return
     * make_num(0)` would have made every `false` in parsed JSON raise. */
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
    /* #495: strict decode. Parse one value via eigs_json_parse_root (#777:
     * the wrapper resets both parse flags), then require that only
     * whitespace remains. A partial container, a truncated
     * document, an unterminated string, over-deep nesting, or trailing
     * garbage after a complete value now raises instead of silently
     * succeeding (which also made a genuine JSON `null` indistinguishable
     * from a parse failure). */
    int pos = 0;
    Value *v = eigs_json_parse_root(arg->data.str, &pos);
    eigs_json_skip_ws(arg->data.str, &pos);
    if (g_json_parse_err || g_json_parse_recoverable ||
        arg->data.str[pos] != '\0') {
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
            char nb[32];                              /* #875: the shared rule */
            eigs_num_text(nb, sizeof(nb), val->data.num);
            strbuf_append(&out, nb);
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
    /* #965: the strbuf payload is already charged (reserve growth + finish
     * shortfall) — take ownership. */
    Value *result = make_str_owned(strbuf_finish(&out));
    return result;
}

Value* builtin_json_raw(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_null();
    /* #965: route the copy through the charging constructor (the xmalloc +
     * xstrdup pair here was an uncharged payload of the same class). */
    Value *v = make_str(arg->data.str);
    v->type = VAL_JSON_RAW;
    return v;
}

/* ================================================================
 * GENERIC STRING PRIMITIVES — language-level, no product logic
 * ================================================================ */

Value* builtin_str_lower(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "str_lower", "a string", make_str(""));
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "contains", "[haystack, needle]", make_num(0));
    Value *h = arg->data.list.items[0], *n = arg->data.list.items[1];
    ARG_GUARD(!h || h->type != VAL_STR || !n || n->type != VAL_STR, "contains", "two strings", make_num(0));
    return make_num(strstr(h->data.str, n->data.str) != NULL ? 1 : 0);
}

Value* builtin_starts_with(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "starts_with", "[string, prefix]", make_num(0));
    Value *s = arg->data.list.items[0], *p = arg->data.list.items[1];
    ARG_GUARD(!s || s->type != VAL_STR || !p || p->type != VAL_STR, "starts_with", "two strings", make_num(0));
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
    /* Output-proportional and allowlisted: total output ~ input bytes plus a
     * Value + pointer per part. Uncharged, splitting a large string aborted
     * mid-build before the post-run result-scan could refuse it (blind
     * round, 2026-08-17). Count parts first (cheap strstr scan), charge
     * once, then build. */
    size_t dlen0 = strlen(delim);
    size_t in_len = strlen(str);
    size_t n_parts = 1;
    if (dlen0 > 0) {
        const char *pc = str;
        const char *fc;
        while ((fc = strstr(pc, delim)) != NULL) { n_parts++; pc = fc + dlen0; }
    }
    if (!sandbox_charge(in_len + n_parts * (sizeof(Value) + sizeof(Value *))))
        return make_null();
    Value *list = make_list(0);
    size_t dlen = strlen(delim);
    /* #965: in_len + per-part overhead was charged above, so every piece
     * wraps with make_str_owned (a make_str copy would charge it twice). */
    if (dlen == 0) {
        list_append_owned(list, make_str_owned(xstrdup(str)));
        return list;
    }
    const char *p = str;
    const char *found;
    while ((found = strstr(p, delim)) != NULL) {
        size_t seg_len = (size_t)(found - p);
        char *seg = xmalloc(seg_len + 1);
        memcpy(seg, p, seg_len);
        seg[seg_len] = '\0';
        list_append_owned(list, make_str_owned(seg));
        p = found + dlen;
    }
    list_append_owned(list, make_str_owned(xstrdup(p)));
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
    ARG_GUARD(!arg || arg->type != VAL_STR, "trim", "a string", make_str(""));
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 3, "str_replace", "[string, old, new]", make_str(""));
    const char *str = "", *old_s = "", *new_s = "";
    /* Coercion, not a guard: a non-string element silently stays "" and the
     * search runs over an empty string. STRICT_REQUIRE rather than ARG_GUARD
     * because there is no single stand-in — a non-string `old` makes
     * old_len 0, which returns the ORIGINAL string, while a non-string
     * `string` returns "". The non-strict path is untouched. */
    STRICT_REQUIRE(arg->data.list.items[0]->type != VAL_STR, "str_replace", "a string as its first argument");
    STRICT_REQUIRE(arg->data.list.items[1]->type != VAL_STR, "str_replace", "a string as its second argument");
    STRICT_REQUIRE(arg->data.list.items[2]->type != VAL_STR, "str_replace", "a string as its third argument");
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
    /* Same class as join: output-proportional, allowlisted, was uncharged —
     * 100MB allocated inside a 1000-byte budget (blind round, 2026-08-17).
     * The 256MB hard cap above stays as the catchable upper bound. */
    if (!sandbox_charge(result_len + 1)) return make_null();
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
    /* #965: result_len+1 was charged above — take ownership, no second charge. */
    return make_str_owned(result);
}


/* ==== BUILTIN: str_upper ==== */
Value* builtin_str_upper(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "str_upper", "a string", make_str(""));
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "char_at", "[string, index]", make_str(""));
    Value *str_val = arg->data.list.items[0];
    Value *idx_val = arg->data.list.items[1];
    ARG_GUARD(!str_val || str_val->type != VAL_STR || !idx_val || idx_val->type != VAL_NUM,
              "char_at", "[string, number]", make_str(""));
    int idx = (int)idx_val->data.num;
    int len = strlen(str_val->data.str);
    if (idx < 0) idx += len;
    /* fs:ANSWER an index outside the string has no character; "" is the
     * documented result for an in-range TYPE with an out-of-range VALUE,
     * the same shape `substr` uses below. Not a type mistake. */
    if (idx < 0 || idx >= len) return make_str("");
    char buf[2] = { str_val->data.str[idx], '\0' };
    return make_str(buf);
}

/* ==== BUILTIN: ends_with ==== */
Value* builtin_ends_with(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "ends_with", "[string, suffix]", make_num(0));
    Value *sv = arg->data.list.items[0], *xv = arg->data.list.items[1];
    ARG_GUARD(!sv || sv->type != VAL_STR || !xv || xv->type != VAL_STR, "ends_with", "two strings", make_num(0));
    const char *str = sv->data.str, *suffix = xv->data.str;
    int slen = strlen(str), xlen = strlen(suffix);
    /* fs:ANSWER a suffix longer than the string is not a suffix of it; 0 is
     * the predicate's answer, not a stand-in for a rejected argument. */
    if (xlen > slen) return make_num(0);
    return make_num(strcmp(str + slen - xlen, suffix) == 0 ? 1 : 0);
}

/* ==== BUILTIN: substr ==== */
/* substr of [string, start, length] → substring */
Value* builtin_substr(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 3, "substr", "[string, start, length]", make_str(""));
    Value *str_val = arg->data.list.items[0];
    Value *start_val = arg->data.list.items[1];
    Value *len_val = arg->data.list.items[2];
    ARG_GUARD(!str_val || str_val->type != VAL_STR, "substr", "a string as its first argument", make_str(""));
    ARG_GUARD(!start_val || start_val->type != VAL_NUM, "substr", "a number as its start", make_str(""));
    ARG_GUARD(!len_val || len_val->type != VAL_NUM, "substr", "a number as its length", make_str(""));
    int slen = strlen(str_val->data.str);
    int start = (int)start_val->data.num;
    int rlen = (int)len_val->data.num;
    /* #504: a negative start counts from the end, matching char_at and the
     * [] operator (was a flat clamp-to-0 — inconsistent). A start still
     * negative after the adjustment (before the string) clamps to 0. */
    if (start < 0) start += slen;
    if (start < 0) start = 0;
    /* fs:ANSWER a start at or past the end selects no characters; "" is the
     * documented result of the #504 clamp, an in-range type with an
     * out-of-range value. */
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "index_of", "[haystack, needle]", make_num(-1));
    Value *h = arg->data.list.items[0], *n = arg->data.list.items[1];
    /* #1008: the -1 for non-string operands is a deliberate choice (#316 —
     * folding to "" gave a false positive at index 0), so ARG_GUARD is
     * exactly the right shape: the answer is preserved with the flag off and
     * the mistake becomes loud with it on. */
    ARG_GUARD(!h || h->type != VAL_STR || !n || n->type != VAL_STR,
              "index_of", "two strings", make_num(-1));
    const char *p = strstr(h->data.str, n->data.str);
    /* fs:ANSWER the needle is genuinely not in the haystack — -1 is
     * index_of's documented miss, and the one -1 here that is a RESULT
     * rather than a rejected argument. */
    if (!p) return make_num(-1);
    return make_num((double)(p - h->data.str));
}

/* ================================================================
 * MATH BUILTINS — trig, rounding, abs
 * ================================================================ */

Value* builtin_sin(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "sin", "a number", make_num(0));
    return make_num(sin(arg->data.num));
}

Value* builtin_cos(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "cos", "a number", make_num(0));
    return make_num(cos(arg->data.num));
}

Value* builtin_tan(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "tan", "a number", make_num(0));
    return make_num(tan(arg->data.num));
}

Value* builtin_asin(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "asin", "a number", make_num(0));
    double x = arg->data.num;
    /* #865/#971: an out-of-domain argument is clamped (invalid bit records it),
     * unless strict math is on, in which case it raises. */
    if (x < -1.0 || x > 1.0) {
        /* fs:STRICT already loud under strict (#977); the soft 0 is the flag-off path */
        if (g_strict) { rt_error(EK_VALUE, 0, "asin: argument out of domain [-1, 1]"); return make_num(0); }
        g_math_flags |= EIGS_MATH_INVALID;
        x = (x < -1.0) ? -1.0 : 1.0;
    }
    return make_num(asin(x));
}

Value* builtin_acos(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "acos", "a number", make_num(0));
    double x = arg->data.num;
    /* #865/#971: an out-of-domain argument is clamped (invalid bit records it),
     * unless strict math is on, in which case it raises. */
    if (x < -1.0 || x > 1.0) {
        /* fs:STRICT already loud under strict (#977); the soft 0 is the flag-off path */
        if (g_strict) { rt_error(EK_VALUE, 0, "acos: argument out of domain [-1, 1]"); return make_num(0); }
        g_math_flags |= EIGS_MATH_INVALID;
        x = (x < -1.0) ? -1.0 : 1.0;
    }
    return make_num(acos(x));
}

Value* builtin_atan(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "atan", "a number", make_num(0));
    return make_num(atan(arg->data.num));
}

Value* builtin_atan2(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "atan2", "[y, x]", make_num(0));
    Value *y = arg->data.list.items[0];
    Value *x = arg->data.list.items[1];
    ARG_GUARD(!y || y->type != VAL_NUM || !x || x->type != VAL_NUM, "atan2", "two numbers", make_num(0));
    return make_num(atan2(y->data.num, x->data.num));
}

Value* builtin_floor(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "floor", "a number", make_num(0));
    return make_num(floor(arg->data.num));
}

Value* builtin_ceil(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "ceil", "a number", make_num(0));
    return make_num(ceil(arg->data.num));
}

Value* builtin_round(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "round", "a number", make_num(0));
    return make_num(round(arg->data.num));
}

Value* builtin_abs(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "abs", "a number", make_num(0));
    return make_num(fabs(arg->data.num));
}

/* #317: min/max are N-ary reductions over a flat list of numbers — the old
 * code silently read only items[0..1] (`max of [1,2,3]` was 2) and returned 0
 * for a 1-element list. A single bare number returns itself (mirrors `sum`);
 * an empty list or any non-number element keeps the old 0 fallback rather
 * than inventing a partial answer. */
static Value* minmax_reduce(Value *arg, int want_max) {
    if (arg && arg->type == VAL_NUM) return make_num(arg->data.num);
    /* Split from the empty-list case below: #317 chose the 0 fallback for BOTH
     * a wrong type and an empty list in one condition, and only the first half
     * is a type mistake. Splitting keeps the non-strict answer identical while
     * letting strict speak about the half it should. */
    ARG_GUARD(!arg || arg->type != VAL_LIST, want_max ? "max" : "min", "a number or a list of numbers", make_num(0));
    /* fs:EMPTY no elements to reduce over; #317 chose 0 rather than inventing a
     * partial answer, and an empty list is not a type mistake. */
    if (arg->data.list.count < 1) return make_num(0);
    double best = 0.0;
    for (int i = 0; i < arg->data.list.count; i++) {
        Value *v = arg->data.list.items[i];
        ARG_GUARD(!v || v->type != VAL_NUM, want_max ? "max" : "min", "every element to be a number", make_num(0));
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

void eigs_ensure_random_seeded(void) {
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
    eigs_ensure_random_seeded();
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
    eigs_ensure_random_seeded();
    /* Range-check as doubles before any integer cast — a double outside the
     * int64_t range (or non-finite) makes the cast itself UB (#698 fixed the
     * same cast-before-range-check class in value_to_string). */
    double lo_d = lo->data.num;
    double hi_d = hi->data.num;
    if (!isfinite(lo_d) || !isfinite(hi_d) ||
        lo_d < -9223372036854775808.0 || hi_d < -9223372036854775808.0 ||
        lo_d >= 9223372036854775808.0 || hi_d >= 9223372036854775808.0) {
        rt_error(EK_VALUE, 0,
                 "random_int: bounds must be finite and within int64 range");
        return make_null();
    }
    int64_t lo_i = (int64_t)lo_d;
    int64_t hi_i = (int64_t)hi_d;
    if (hi_i < lo_i) TRACE_NONDET_RET("random_int", make_num(lo_i));
    /* Span in uint64_t: a wide-but-legal int64 range (e.g. INT64_MIN..0) would
     * overflow a signed int64 subtraction before the rejection below. Cannot
     * wrap uint64: the double guard above keeps hi_d < 2^63, and the largest
     * double below 2^63 is 2^63 - 1024, so hi_i - lo_i + 1 <= 2^64 - 1023. */
    uint64_t span = (uint64_t)hi_i - (uint64_t)lo_i + 1;
    if (span > (uint64_t)INT32_MAX + 1) {
        rt_error(EK_VALUE, 0,
                 "random_int: range span %llu exceeds 2^31 (lrand48 supplies 31 bits)",
                 (unsigned long long)span);
        return make_null();
    }
    TRACE_NONDET_RET("random_int", make_num(lo_i + (lrand48() % (int64_t)span)));
}

/* seed_random of n → seeds the RNG, returns 1 */
Value* builtin_seed_random(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "seed_random", "a number", make_num(0));
    srand48((long)arg->data.num);
    g_random_seeded = 1;
    return make_num(1);
}


/* ---- Command-line arguments ----
 * Non-static: builtins_host.c's exe_path uses g_argv[0] as its fallback
 * when /proc/self/exe is unavailable (declared in builtins_internal.h). */
int g_argc = 0;
char **g_argv = NULL;

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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "path_join", "[a, b]", make_str(""));
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    ARG_GUARD(!a || a->type != VAL_STR || !b || b->type != VAL_STR, "path_join", "two strings", make_str(""));
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
    ARG_GUARD(!arg || arg->type != VAL_STR, "path_dir", "a string", make_str(""));
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
    ARG_GUARD(!arg || arg->type != VAL_STR, "path_base", "a string", make_str(""));
    const char *s = arg->data.str;
    const char *last = strrchr(s, '/');
    return make_str(last ? last + 1 : s);
}

/* path_ext of "a/b/c.txt" → ".txt" */
Value* builtin_path_ext(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "path_ext", "a string", make_str(""));
    const char *base = strrchr(arg->data.str, '/');
    const char *s = base ? base + 1 : arg->data.str;
    const char *dot = strrchr(s, '.');
    return make_str(dot ? dot : "");
}


/* free_val of value → frees a heap-allocated Value tree. Returns null.
 * Use this to release large temporary results (e.g. tokenize_with_names output)
 * when the arena is not active. No-op on arena-allocated values. */
Value* builtin_free_val(Value *arg) {
    if (arg && !g_arena.active) val_decref(arg);
    return make_null();
}


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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "json_path", "[json_string, path]", make_str(""));
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
            /* fs:CHANNEL the rt_error above already raised (#507) */
            return make_str("");
        }
    }

    int pos = 0;
    Value *root = eigs_json_parse_root(json_str, &pos);   /* #777: fresh parse */
    /* fs:TODO #971 PHASE C. This is NOT "no value at that path" — the
     * DOCUMENT failed to parse, and that input error is laundered into the
     * same "" that a legitimately-absent key returns, so a caller cannot
     * tell malformed JSON from a missing field. Converting it means deciding
     * whether JSON parse failure raises at all, which is a contract change
     * with its own consumers (the flag channel below, ext_http, tidelog).
     * Deliberately left soft here and recorded as the Phase C decision. */
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
            /* fs:ANSWER key absent from the object — "no value at that path" is
             * this function's documented result. */
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
                    /* fs:ANSWER array index out of range — no value at that path */
                    val_decref(root); return make_str("");
                }
            } else {
                /* String key: treat as object lookup */
                current = json_obj_get(current, segment);
                /* fs:ANSWER key absent — no value at that path */
                if (!current) { val_decref(root); return make_str(""); }
            }
        } else {
            /* fs:ANSWER a scalar cannot be descended into; the path does not
             * resolve, which is the documented "" result. */
            val_decref(root); return make_str("");
        }
        segment = strtok_r(NULL, ".", &saveptr);
    }

    /* fs:ANSWER the walk ended on nothing — no value at that path */
    if (!current) { val_decref(root); return make_str(""); }
    if (current->type == VAL_STR) {
        Value *r = make_str(current->data.str);
        val_decref(root);
        return r;
    }
    if (current->type == VAL_NUM) {
        char buf[64];
        eigs_num_text(buf, sizeof(buf), current->data.num);   /* #875 */
        val_decref(root);
        return make_str(buf);
    }
    /* fs:ANSWER JSON null renders as the empty string, the documented
     * scalar rendering — not a rejected argument. */
    if (current->type == VAL_NULL) { val_decref(root); return make_str(""); }
    /* For complex types, json_encode them */
    strbuf out;
    strbuf_init(&out);
    if (eigs_json_encode_value(current, &out, 0) != 0) {
        strbuf_free(&out);
        val_decref(root);
        json_encode_depth_error("json_path");
        return make_null();
    }
    /* #965: the strbuf payload is already charged (reserve growth + finish
     * shortfall) — take ownership. */
    Value *r = make_str_owned(strbuf_finish(&out));
    val_decref(root);
    return r;
}


int resolve_eigenscript_file(const char *path, char *resolved, size_t resolved_cap) {
    return resolve_eigenscript_file_from(g_script_dir, path, resolved, resolved_cap);
}


/* ================================================================
 * THIN BUILTINS — individual capabilities for .eigs orchestration
 * ================================================================ */


/* ================================================================
 * CORE PLATFORM BUILTINS (always available)
 * ================================================================ */


Value* builtin_env_get(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("env_get", make_str(""));
    const char *val = getenv(arg->data.str);
    TRACE_NONDET_RET("env_get", make_str(val ? val : ""));
}


/* Issue #148 — subprocess and channel builtins cannot be safely replayed.
 * Forking real children, draining real fds, and waking real channel
 * waiters under EIGS_REPLAY would let a recorded script re-run its
 * side effects against a tape that does not carry the host-side causal
 * structure (child exit codes, channel ordering, syscall errnos).
 * Wrapping these with TRACE_NONDET_TAKE is not enough — the value the
 * tape carries does not pin down the host state — so the contract is
 * "fail loudly" at the boundary. Documented in docs/TRACE.md. */
int replay_blocks(const char *fn) {
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0,
            "%s: not replayable under EIGS_REPLAY (subprocess/concurrency "
            "boundary; see docs/TRACE.md)", fn);
        return 1;
    }
    return 0;
}


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

/* ==== BUILTIN: heap_inuse ==== */
/* heap_inuse of null — bytes currently in use by the C allocator
 * (glibc mallinfo2().uordblks): LIVE allocated bytes, so unlike RSS it is
 * immune to resident free-heap slack — a fresh leak shows up in the very
 * first batch, not only after the slack is exhausted (#770). Debug
 * surface; exists so the per-request leak gate
 * (tests/test_http_rss_growth.sh) can watch exact accounting instead of
 * the RSS proxy.
 *
 * Constraints, both inherited by that gate (which is already Linux-only
 * because it reads /proc):
 *   - glibc only. Returns null where mallinfo2 does not exist (musl,
 *     macOS, freestanding libc). The freestanding profile is carved out
 *     explicitly (not just by __GLIBC__): it compiles on a glibc host,
 *     so the host's mallinfo2 would otherwise leak into its import
 *     surface and no HAL/mini-libc provides it (tools/freestanding_check.sh).
 *   - mallinfo2 reports the MAIN arena only. Sequential request traffic
 *     (what the gate drives) is served on the main arena, so per-request
 *     leaks on that path are fully counted; allocations pinned to a
 *     contended per-thread arena are not. */
Value* builtin_heap_inuse(Value *arg) {
    (void)arg;
#if defined(__GLIBC__) && !EIGENSCRIPT_FREESTANDING
    return make_num((double)mallinfo2().uordblks);
#else
    return make_null();
#endif
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "secure_equals", "[string, string]", make_num(0));
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    ARG_GUARD(!a || !b || a->type != VAL_STR || b->type != VAL_STR, "secure_equals", "two strings", make_num(0));
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
    /* #1008: this was ONE condition carrying two different verdicts — a
     * non-string argument (a mistake) OR an empty string (the documented
     * answer). The classifier never revisits a site that carries a decision,
     * so tagging it either way would have blessed the other half; split, per
     * the same rule that #1008 applied to sum/mean/norm. Non-strict is
     * byte-identical: both halves still answer -1. */
    ARG_GUARD(!arg || arg->type != VAL_STR || !arg->data.str,
              "ord", "a string", make_num(-1));
    /* fs:ANSWER an empty string has no first byte, so -1 is ord's documented
     * result for it, not a rejected argument. */
    if (arg->data.str[0] == '\0') return make_num(-1);
    return make_num((double)(unsigned char)arg->data.str[0]);
}

/* ==== BUILTIN: try_parse ==== */
/* try_parse of string → 1 if valid EigenScript syntax, 0 if not.
 * Tokenizes and parses without executing. Suppresses stderr. */
Value* builtin_try_parse(Value *arg) {
    /* The wrong-TYPE half is a mistake; the parse-FAILED half below is the
     * documented answer. Phase A's writeup used `try_parse of "!!!"` as its
     * example of a 0 that is an answer — that is the string path, which is
     * untouched here. Handing `try_parse` a number is not that. */
    ARG_GUARD(!arg || arg->type != VAL_STR, "try_parse", "a string", make_num(0));
    const char *src = arg->data.str;
    /* fs:ANSWER empty source is not valid EigenScript syntax; 0 is the
     * documented result ("1 if valid, 0 if not"), the same channel a
     * syntactically bad program uses. */
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
/* #704: the ABI revision stamp on a top-level chunk descriptor.
 *
 * An external bytecode producer (ouroboros' self-hosted codegen, iLambdaAi's
 * vendored copy of it) hardcodes the EIGS_BYTECODE_ABI it was written against
 * as element 0; anything else is refused. See the constant in src/vm.h for why
 * this exists and when to bump it. Element 0 discriminates by TYPE — a stamped
 * descriptor has a number there, an unstamped (pre-#704) one has the code list
 * — so a stale producer is detected with certainty, never guessed at.
 *
 * Nested function descriptors carry NO stamp: the revision describes the chunk
 * handed across the boundary, not every chunk nested inside it.
 *
 * Returns NULL when the stamp is present and current, else the reason (written
 * into buf). */
static const char *vm_desc_abi_error(Value *desc, char *buf, size_t buflen) {
    if (!desc || desc->type != VAL_LIST || desc->data.list.count < 1)
        return "chunk descriptor must be a list";
    Value *rev = desc->data.list.items[0];
    if (!rev || rev->type != VAL_NUM) {
        snprintf(buf, buflen,
                 "chunk descriptor carries no bytecode ABI revision (element 0 "
                 "must be the number %d, found %s) — this producer predates the "
                 "revision stamp and its operand widths are unverifiable",
                 EIGS_BYTECODE_ABI, rev ? val_type_name(rev->type) : "nothing");
        return buf;
    }
    if ((int)rev->data.num != EIGS_BYTECODE_ABI) {
        snprintf(buf, buflen,
                 "chunk was produced for bytecode ABI revision %d, but this "
                 "runtime speaks revision %d — regenerate it with a matching "
                 "producer",
                 (int)rev->data.num, EIGS_BYTECODE_ABI);
        return buf;
    }
    return NULL;
}

/* ---- Sandbox descriptor verification: ONE context for the whole graph ----
 *
 * A sandbox descriptor is untrusted DATA that becomes an executable chunk
 * before any of the sandbox's own bounds exist: the loop cap and the byte
 * budget are armed only AFTER vm_build_chunk_desc returns, so verification
 * must carry its own bound or become the DoS the sandbox exists to prevent.
 * It must also carry the OWNERSHIP decision, because the constant pool is one
 * of the two ways host state reaches sandboxed code (the other is the
 * allowlist copy in builtin_sandbox_run).
 *
 * One DescVerify context is created per sandbox descriptor build and threaded
 * through every recursive arm — root chunk, nested function chunks, code,
 * constant containers, function lists, local-name lists:
 *
 *   work   ONE total allowance for the ENTIRE graph. A per-chunk or per-pool
 *          allowance is not a bound at all: N nested chunks multiply it by N,
 *          which is exactly how "every child is well inside the limit" sums
 *          to a graph that is not. Exhaustion refuses the descriptor — the
 *          fail-closed direction: a graph that cannot be verified within the
 *          bound is refused, not trusted.
 *   path   the nodes on the CURRENT recursion path. A node that is its own
 *          ancestor is a back edge: refuse rather than recurse forever.
 *          Merely REPEATED aliases (a DAG) are not cycles — they are charged
 *          once per visit and bounded by `work`, which is what stops the
 *          aliased all-data DAG whose every path is explored because nothing
 *          unsafe short-circuits it.
 *   depth  the length of `path`, and so an explicit structural bound on C
 *          recursion across BOTH the value walk and the chunk walk.
 *
 * The allowance is larger than the constants-only bound it replaces because
 * it now also pays for chunk structure, code bytes, function lists and local
 * names: a descriptor that fit the old pool-only bound must still fit the new
 * total. It stays far below the aliased-DAG shapes the pool bound refused. */
#define SANDBOX_DESC_MAX_DEPTH 64
#define SANDBOX_DESC_MAX_WORK  150000

typedef struct {
    long        work;                          /* remaining total allowance */
    int         depth;                         /* nodes on `path` */
    const void *path[SANDBOX_DESC_MAX_DEPTH];  /* current recursion path */
} DescVerify;

/* Spend n units of the one graph allowance; 0 = exhausted. A NULL context is
 * the TRUSTED build (vm_run_bytecode): that descriptor is the host's own
 * bootstrap output, not untrusted input, and is neither bounded nor copied. */
static int desc_spend(DescVerify *ctx, long n) {
    if (!ctx) return 1;
    if (n < 0 || n > ctx->work) { ctx->work = 0; return 0; }
    ctx->work -= n;
    return 1;
}

/* Push a node onto the current path: bounds recursion depth and refuses a
 * back edge. Every successful desc_enter is paired with one desc_leave. */
static int desc_enter(DescVerify *ctx, const void *node) {
    if (!ctx) return 1;
    if (!node || ctx->depth >= SANDBOX_DESC_MAX_DEPTH) return 0;
    for (int i = 0; i < ctx->depth; i++)
        if (ctx->path[i] == node) return 0;
    ctx->path[ctx->depth++] = node;
    return 1;
}

static void desc_leave(DescVerify *ctx) {
    if (ctx && ctx->depth > 0) ctx->depth--;
}

/* Verify AND isolate one descriptor constant: returns a fresh OWNED value
 * that shares no mutable object with the host, or NULL when the value is not
 * admissible data, closes a cycle, or the graph allowance runs out.
 *
 * Verifying and copying are deliberately the SAME walk. Checking the pool and
 * then retaining the checked object by reference is what let a host-owned
 * list stay the very object the sandbox mutates: `append` is allowlisted, a
 * container with spare capacity mutates in place with no allocation and no
 * charge, and the direct-result scan cannot undo a change the host can
 * already see through its own alias — the callable never appears in the
 * returned result at all. So the boundary is closed on the way IN.
 *
 * Scalars are immutable and are shared by refcount; only containers are
 * copied. Dict keys are interned C strings rather than Values, so a dict
 * costs one node per VALUE and needs no separate key walk. A buffer's element
 * storage is its real weight — the same accounting the sibling result scan
 * spends (#965) — and is copied, since buf_set writes it in place.
 * VAL_FN/VAL_BUILTIN are ambient capability and VAL_TEXT_BUILDER is host-owned
 * mutable state: none of them may cross, at any depth. Enumerated rather than
 * covered by a `default:` so -Werror=switch forces a new ValType to choose. */
static Value *desc_isolate_const(DescVerify *ctx, Value *v) {
    if (!v || !desc_spend(ctx, 1)) return NULL;
    switch (v->type) {
    case VAL_NUM:
    case VAL_STR:
    case VAL_NULL:
    case VAL_JSON_RAW:
        val_incref(v);
        return v;
    case VAL_BUFFER: {
        long n = v->data.buffer.count > 0 ? (long)v->data.buffer.count : 0;
        if (!desc_spend(ctx, n)) return NULL;
        Value *c = xcalloc(1, sizeof(Value));
        c->type = VAL_BUFFER;
        c->data.buffer.count = v->data.buffer.count;
        c->data.buffer.rows  = v->data.buffer.rows;
        c->data.buffer.cols  = v->data.buffer.cols;
        c->data.buffer.data  = xcalloc(n > 0 ? (size_t)n : 1, sizeof(double));
        if (n > 0)
            memcpy(c->data.buffer.data, v->data.buffer.data,
                   (size_t)n * sizeof(double));
        c->refcount = 1;
        return c;
    }
    case VAL_LIST: {
        if (!desc_enter(ctx, v)) return NULL;
        /* make_list_heap, not make_list: the copy outlives this builtin call
         * and must not be arena-allocated, and it is sized by a graph already
         * in memory (the uncharged-wrapper rule make_list_heap documents). */
        Value *c = make_list_heap(v->data.list.count);
        for (int i = 0; i < v->data.list.count; i++) {
            Value *e = desc_isolate_const(ctx, v->data.list.items[i]);
            if (!e) { val_decref(c); desc_leave(ctx); return NULL; }
            list_append_owned(c, e);
        }
        desc_leave(ctx);
        return c;
    }
    case VAL_DICT: {
        if (!desc_enter(ctx, v)) return NULL;
        Value *c = make_dict(v->data.dict.count);
        for (int i = 0; i < v->data.dict.count; i++) {
            Value *e = desc_isolate_const(ctx, v->data.dict.vals[i]);
            if (!e) { val_decref(c); desc_leave(ctx); return NULL; }
            dict_set_owned(c, v->data.dict.keys[i], e);
        }
        desc_leave(ctx);
        return c;
    }
    case VAL_FN:
    case VAL_BUILTIN:
    case VAL_TEXT_BUILDER:
        return NULL;
    }
    return NULL;   /* unreachable for a valid ValType */
}

static EigsChunk *vm_build_chunk_desc_ctx(Value *desc, int off, int sandbox_mode,
                                          DescVerify *ctx);

/* Build an EigsChunk from a descriptor list, recursively for nested functions.
 * `off` skips the leading ABI-revision stamp: 1 at the top level (where
 * vm_desc_abi_error has already validated it), 0 for nested descriptors, which
 * carry no stamp. After the offset the layout is:
 *   [ code, constants, functions?, param_count?, name?, local_names? ]
 *   - code        : list of byte ints (opcodes + little-endian operands; 16-bit
 *                   except OP_LINE's, which is 32-bit since #630)
 *   - constants   : constant pool (ordinary values; sandbox mode restricts it
 *                   recursively to data-only scalars/containers; strings double as
 *                   GET_NAME/SET_NAME names)
 *   - functions   : (optional) list of descriptors for nested function chunks,
 *                   referenced by OP_CLOSURE [fn_idx]
 *   - param_count : (optional) number of leading local slots that are params
 *   - name        : (optional) chunk/function name
 *   - local_names : (optional) names for local slots in slot order; the count
 *                   sizes the call frame, and the first param_count are the
 *                   parameter names OP_CLOSURE binds.
 * The minimal form is code+constants (a flat module chunk).
 *
 * In sandbox mode every arm below spends the ONE DescVerify allowance and
 * every constant is isolated from the host; see DescVerify above. */
static EigsChunk *vm_build_chunk_desc_body(Value *desc, int off, int sandbox_mode,
                                           DescVerify *ctx) {
    if (!desc || desc->type != VAL_LIST || desc->data.list.count < off + 2)
        return NULL;
    Value **d = desc->data.list.items + off;
    int n = desc->data.list.count - off;
    Value *code = d[0], *consts = d[1];
    if (!code || code->type != VAL_LIST || !consts || consts->type != VAL_LIST)
        return NULL;
    /* This chunk plus its code stream: charged BEFORE anything is allocated,
     * so an over-wide code list is refused rather than emitted first. */
    if (!desc_spend(ctx, 1 + (long)code->data.list.count)) return NULL;

    const char *name = (n >= 5 && d[4] && d[4]->type == VAL_STR) ? d[4]->data.str
                                                                 : "<bootstrap>";
    EigsChunk *chunk = chunk_new(name);

    for (int i = 0; i < code->data.list.count; i++) {
        Value *b = code->data.list.items[i];
        int byte = (b && b->type == VAL_NUM) ? ((int)b->data.num & 0xFF) : 0;
        chunk_emit(chunk, (uint8_t)byte, 1);
    }
    /* Positional: the code stream indexes this pool by position, so neither
     * the dedup collapse nor a skipped NULL may shift an entry (#721). A hole
     * in the pool is a malformed descriptor — reject rather than renumber.
     * In sandbox mode the pool is verified and ISOLATED in one walk against
     * the graph-wide allowance: the chunk owns a private copy of every
     * mutable constant, so nothing the sandbox does to a constant is visible
     * to the host, and nothing the host does mid-run is visible to it. */
    for (int i = 0; i < consts->data.list.count; i++) {
        Value *item = consts->data.list.items[i];
        if (!item) { chunk_free(chunk); return NULL; }
        if (sandbox_mode) {
            Value *iso = desc_isolate_const(ctx, item);
            if (!iso) { chunk_free(chunk); return NULL; }
            chunk_add_constant_positional(chunk, iso);
            val_decref(iso);            /* the pool holds its own ref */
        } else {
            chunk_add_constant_positional(chunk, item);
        }
    }

    /* nested function chunks (creator ref transfers into functions[]). A
     * nested descriptor that fails to build/verify invalidates the whole
     * chunk — silently dropping it would shift the indices OP_CLOSURE refers
     * to (wrong function, or out of range). The recursion carries the SAME
     * context: a child that reset the allowance would multiply it. */
    if (n >= 3 && d[2] && d[2]->type == VAL_LIST) {
        if (!desc_spend(ctx, d[2]->data.list.count)) {
            chunk_free(chunk);
            return NULL;
        }
        for (int i = 0; i < d[2]->data.list.count; i++) {
            EigsChunk *fn = vm_build_chunk_desc_ctx(d[2]->data.list.items[i], 0,
                                                    sandbox_mode, ctx);
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
        if (!desc_spend(ctx, lc)) { chunk_free(chunk); return NULL; }
        chunk->local_names = xcalloc(lc, sizeof(char *));
        for (int i = 0; i < lc; i++) {
            Value *nm = d[5]->data.list.items[i];
            chunk->local_names[i] = env_intern_name((nm && nm->type == VAL_STR) ? nm->data.str : "");
        }
        chunk->local_count = lc;
        /* #1063: a descriptor carries no interrogation scan; record every
         * slot write (the unfiltered trace_assign path applies anyway). */
        chunk->local_traced = xmalloc((size_t)(lc > 0 ? lc : 1));
        memset(chunk->local_traced, 1, (size_t)(lc > 0 ? lc : 1));
    }
    /* The VM runs on its global value stack (VM_STACK_MAX), so max_stack is a
     * hint only. */
    chunk->max_stack = 64;

    /* Reject untrusted bytecode with out-of-range constant/function/jump
     * operands before it reaches the VM (which trusts operand indices). */
    if (!chunk_verify(chunk)) { chunk_free(chunk); return NULL; }
    return chunk;
}

/* Enter one chunk of the descriptor graph. The depth/back-edge bound covers
 * CHUNK recursion too, so a self-referential or unboundedly nested descriptor
 * is refused instead of running the C stack out. Wrapping the body keeps the
 * enter/leave pairing off every one of its early returns. */
static EigsChunk *vm_build_chunk_desc_ctx(Value *desc, int off, int sandbox_mode,
                                          DescVerify *ctx) {
    if (!desc_enter(ctx, desc)) return NULL;
    EigsChunk *chunk = vm_build_chunk_desc_body(desc, off, sandbox_mode, ctx);
    desc_leave(ctx);
    return chunk;
}

/* The one verification context is created HERE — once per sandbox descriptor
 * build — and threaded through every recursive builder and walker arm below
 * it. The trusted (non-sandbox) build runs with no context at all. */
static EigsChunk *vm_build_chunk_desc(Value *desc, int off, int sandbox_mode) {
    if (!sandbox_mode) return vm_build_chunk_desc_ctx(desc, off, 0, NULL);
    DescVerify ctx;
    ctx.work  = SANDBOX_DESC_MAX_WORK;
    ctx.depth = 0;
    return vm_build_chunk_desc_ctx(desc, off, 1, &ctx);
}

/* vm_run_bytecode of <chunk-descriptor> — assemble a chunk (and its nested
 * function chunks) from EigenScript values and run it on the C VM. The
 * self-hosting bootstrap bridge: a compiler written in EigenScript emits
 * bytecode as data, and this hands it to the same vm_execute the C compiler's
 * output runs through — reusing the bytecode VM and its JIT. The caller is
 * responsible for a well-formed chunk ending in OP_RETURN, stamped with the
 * bytecode ABI revision it was built against (#704). */
/* #915: a descriptor chunk never passes through compile_ast, so the observer
 * gate's compile-time scan never saw it. Two things follow, and only one of
 * them is solved here.
 *
 * SOLVED — the descriptor's OWN work. eigs_obs_enable() arms recording before
 * vm_execute, the observer twin of chunk_arm_temporal below (#831: "a
 * descriptor must turn recording ON itself"). It also records the history gap,
 * so a mid-run arming cannot disarm the load_file guard — a benign descriptor
 * call used to do exactly that, silently, for the rest of the process.
 *
 * NOT SOLVED, and filed rather than half-guarded — see the issue referenced in
 * docs: a descriptor that READS observer state about a host binding assigned
 * before the call gets a rest value, because that history was never recorded.
 * Three static guards were tried and each traded one wrong answer for another:
 * "reads at all" broke 57 bridge assertions; "reads a NAME operand" missed the
 * slot form; "reads a NAME or an in-range assigned slot, or the thread alias"
 * fires on tests/test_vm_run_bytecode.eigs's own #737 fixture, whose operand
 * bytes are load-bearing (1,1 == two OP_NULLs, chosen so a drifted operand walk
 * stays synced) and whose reader is JUMPED OVER. Distinguishing that from a
 * real host read needs reachability analysis over caller-supplied bytecode,
 * which is its own change with its own review. Shipping a guard that breaks a
 * legitimate fixture, or a fourth variant tuned until the suite passes, would
 * both be worse than a stated residual. */

Value* builtin_vm_run_bytecode(Value *arg) {
    char abibuf[256];
    const char *abi_err = vm_desc_abi_error(arg, abibuf, sizeof abibuf);
    if (abi_err) { rt_error(EK_VALUE, 0, "%s", abi_err); return make_null(); }
    EigsChunk *chunk = vm_build_chunk_desc(arg, 1, 0);
    if (!chunk) return make_null();
    /* #915: ARM the observer for what this descriptor itself does, exactly as
     * chunk_arm_temporal two lines below arms the temporal channel (#831: "a
     * descriptor must turn recording ON itself" — nothing scanned this chunk).
     *
     * The guard above and this line answer DIFFERENT questions and an earlier
     * revision wrongly swapped one for the other: the guard covers host
     * bindings assigned BEFORE the call, whose history is unrecoverable; this
     * covers everything the descriptor writes and reads AFTER it. Deleting this
     * made a descriptor that writes a geometric series into its own frame slot
     * and reads it back answer `equilibrium` — a regression a blind critic
     * bisected to the commit that removed it. Both are needed.
     *
     * Through eigs_obs_enable, not a bare assignment: this flip happens mid-
     * execution, so it must also record that earlier bindings have no history. */
    eigs_obs_enable();
    /* #831: the compiler's temporal scan is what turns history recording on,
     * and it never saw this chunk — arm from the verified bytecode instead,
     * or the chunk's own `prev of` / `at` reads answer null whenever the
     * host program happens to contain no temporal query. */
    chunk_arm_temporal(chunk);
    Env *target = g_builtin_call_env ? g_builtin_call_env : g_global_env;
    /* #1030: a descriptor that DECLARES local slots gets its own frame env.
     * vm_run reserves the chunk's slots in whatever env it is handed and
     * OP_SET_LOCAL writes them by index, so a top-level descriptor run in
     * the caller's env wrote the CALLER's slot 0 -- decref'ing the host's
     * own first binding, which the host then read after the builtin
     * returned (heap-use-after-free under ASan, a clobbered value without
     * it). A child env keeps name resolution (GET_NAME walks the parent
     * chain) and isolates the slots. */
    /* EVERY descriptor, slot-declaring or not: a slot-less descriptor's
     * `SET_LOCAL 0` passed the #348 range check against the HOST env's
     * slot count and clobbered the global env's slot 0 -- `print` became
     * the number 7 ("cannot call num" on the next print). In a fresh child
     * env that write is out of range and raises, as #348 specifies. */
    Env *fenv = env_new(target);
    Value *result = vm_execute(chunk, fenv);
    env_decref(fenv);
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
    "list_contains", "list_index_of", "list_insert_at", "list_remove_at",
    "list_slice", "list_truncate", "set_at",
    "sort", "sort_by", "range",
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
    /* DEFLATE codecs (pure bytes <-> bytes; #684) */
    "deflate", "inflate", "zlib_deflate", "zlib_inflate",
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

/* Does `v` carry a callable? A VAL_FN made inside the sandbox closes over the
 * sandbox env, and handing one back to the host is an escape hatch: the host
 * calls it AFTER sandbox_run has already restored the loop cap and the
 * allocation budget, so sandbox-authored code runs unbounded.
 *
 * Bounded by a NODE budget, not just by depth: containers may be cyclic, and a
 * depth-only bound is exponential on a self-referential list (a list holding
 * itself k times explores k^depth nodes) — the walk itself would become the
 * DoS the sandbox exists to prevent. Exhausting either bound returns "yes",
 * the fail-closed direction: an unwalkable result is refused, not trusted. */
#define SANDBOX_RESULT_MAX_DEPTH 32
#define SANDBOX_RESULT_MAX_NODES 100000
/* Returns 1 if the result contains — or cannot be shown NOT to contain — a
 * callable. Fails closed on an exhausted node/depth budget, but sets
 * `*unverified` when that is why, because the two are different facts and the
 * caller reports them differently: a 10M-element list of numbers is not "a
 * callable crossing the boundary", it just outruns the scan. Blaming a
 * callable there sends the caller hunting for a function that was never in
 * the result. */
static int sandbox_value_has_callable(Value *v, int depth, long *budget,
                                      int *unverified) {
    if (!v) return 0;
    if (v->type == VAL_FN || v->type == VAL_BUILTIN) return 1;
    if (depth > SANDBOX_RESULT_MAX_DEPTH || --(*budget) <= 0) {
        *unverified = 1;
        return 1;
    }
    if (v->type == VAL_BUFFER) {
        /* #965: a buffer's element storage is its real weight. Counting it
         * as ONE node let a huge buffer cross the boundary as a single node
         * — aggregated buffers escaped both the byte charge and the node
         * scan (the double-bypass that made buf_from_list land). Spend one
         * node per element ON TOP OF the container node the entry check
         * already spent: exactly 1 + count nodes, including count zero, the
         * identical accounting a
         * flat list of the same length gets — so the exact node boundary
         * behaves the same for both. Exhaustion fails closed like any other
         * unwalkable result. */
        long elems = v->data.buffer.count > 0 ? (long)v->data.buffer.count : 0;
        *budget -= elems;
        if (*budget <= 0) {
            *unverified = 1;
            return 1;
        }
    }
    if (v->type == VAL_LIST) {
        for (int i = 0; i < v->data.list.count; i++)
            if (sandbox_value_has_callable(v->data.list.items[i], depth + 1,
                                           budget, unverified))
                return 1;
    } else if (v->type == VAL_DICT) {
        for (int i = 0; i < v->data.dict.count; i++) {
            /* #1014: this walk once re-homed escaping dict keys as well
             * (a promote_keys arm, run as a second pass at the result
             * boundary). Measured: dict_set_hashed promotes at INSERTION
             * whenever a sandbox intern scope is open, so that pass
             * changed 0 of 128 keys -- deleted. One job: callable
             * detection. */
            if (sandbox_value_has_callable(v->data.dict.vals[i], depth + 1,
                                           budget, unverified))
                return 1;
        }
    }
    return 0;
}

/* sandbox_run of [descriptor, max_iterations?] — run an EigenScript-assembled
 * chunk (same descriptor as vm_run_bytecode) under two safety bounds: dangerous
 * builtins are shadowed by a blocked stub, and loops are capped at
 * max_iterations (default 1,000,000) so runaway code can't hang. Runtime errors
 * are caught (not propagated). Returns {"ok": 1/0, "result": value} — the graded
 * "does it run?" rung for a self-hosted compiler validating generated code. */
Value* builtin_sandbox_run(Value *arg) {
    /* #915: same descriptor hazard as vm_run_bytecode. Unexploitable TODAY only
     * because the sandbox env is a sealed root (parent == NULL), so a descriptor
     * cannot reach a host binding's slot — that is the sandbox's defence, not
     * the gate's, and it evaporates the day sealing is relaxed. The guard runs
     * below, once the chunk exists. */
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

    /* Descriptor values are untrusted input. Start the run-owned intern scope
     * before validation/assembly: vm_build_chunk_desc interns every string
     * constant, including unused literals, before the VM itself starts. Keep
     * the scope active through execution so runtime names share the same
     * lifetime; output/error wrapper keys are added only after it is restored. */
    uint32_t saved_intern_scope = g_sandbox_intern_scope;
    uint32_t intern_scope = env_intern_scope_begin();

    /* #704: an ABI-revision mismatch is a build failure like any other, but it
     * gets its own message — a grading ladder must be able to tell "your
     * producer is stale" from "your bytecode is malformed" without re-running. */
    char abibuf[256];
    const char *abi_err = vm_desc_abi_error(desc, abibuf, sizeof abibuf);
    EigsChunk *chunk = abi_err ? NULL : vm_build_chunk_desc(desc, 1, 1);
    if (chunk) eigs_obs_enable();     /* #915: see vm_run_bytecode */
    Value *out = make_dict(2);
    if (!chunk) {
        /* Descriptor verification may already have interned constants before
         * rejecting the graph. Restore the caller's scope before constructing
         * the host-owned diagnostic dictionary, then release this run's names. */
        env_intern_scope_end(intern_scope, saved_intern_scope);
        Value *zero = make_num(0);
        dict_set(out, "ok", zero);   /* dict_set increfs; drop our ref */
        val_decref(zero);
        /* #406: surface the build failure structurally — a descriptor
         * that doesn't verify is a bad argument value, same shape as a
         * runtime failure's error field. */
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str(err_kind_name(EK_VALUE)));
        dict_set_owned(ev, "message",
                       make_str(abi_err ? abi_err : "invalid chunk descriptor"));
        dict_set_owned(ev, "line", make_num(0));
        dict_set_owned(out, "error", ev);
        return out;
    }
    /* #831: same as vm_run_bytecode — the temporal opcodes in an assembled
     * chunk must arm recording themselves; the compiler never scanned it. */
    chunk_arm_temporal(chunk);

    /* SEALED restricted env. The parent link is NULL, not g_global_env: the
     * sandbox env is a root, and the allowed builtins are COPIED into it.
     *
     * Parenting at the global env leaked in two directions, both confirmed
     * escapes rather than theory:
     *
     *   (1) WRITE-THROUGH. `is` is an outward assignment (OP_SET_NAME), and
     *       env_set walks the parent chain and writes to the first env that
     *       already binds the name. Allowlisted names were deliberately NOT
     *       shadowed, so they resolved straight through — a sandboxed
     *       `sum is 42`, or `len is <closure>`, rebound the HOST's global.
     *       Planting a closure that way ran sandbox-authored code in the host
     *       the next time the host called that builtin, with the loop cap and
     *       allocation budget already torn down.
     *
     *   (2) STALE SNAPSHOT. The stub shadows were a snapshot of the global env
     *       taken at entry, so any name the host defined AFTER this call had no
     *       shadow and stayed reachable through the parent link.
     *
     * Copying the allowlist into a root env closes both at once: there is no
     * outer binding to write through to, and no chain to fall through. The
     * blocked stub is still bound over every other name the global env holds,
     * purely for the diagnostic — an EK_SANDBOX "blocked in sandbox" is far
     * more useful to a grading ladder than a bare undefined-variable error. */
    Env *sbox = env_new(NULL);
    Value *stub = make_builtin(builtin_sandbox_blocked);
    for (int i = 0; SANDBOX_ALLOW[i]; i++) {
        Value *v = env_get(g_global_env, SANDBOX_ALLOW[i]);
        if (!v) continue;               /* extension absent from this build */
        /* Only the pure C BUILTIN the allowlist names may cross. A host that
         * rebound the name holds an arbitrary value there — often a mutable
         * container, possibly a function — and copying it aliases host state
         * inward through a second root: sandboxed code could then mutate a
         * container the host still holds (the descriptor-constant escape by
         * another door) or call host code outright. The allowlist grants a
         * pure-compute capability, not whatever currently answers to its
         * name, so anything else gets the blocked stub — which is also the
         * better diagnostic. */
        env_set_local(sbox, SANDBOX_ALLOW[i],
                      v->type == VAL_BUILTIN ? v : stub);
    }
    /* #1035: the walk reads g_global_env's count/names while pthread
     * workers may be binding new module names under g_module_env_lock
     * (env_set_local_pre_interned_slot); TSan caught the unlocked read.
     * Snapshot the names UNDER the lock, then bind outside it: sbox is a
     * sealed root env, so env_set_local on it takes the same non-recursive
     * lock -- binding inside the locked walk deadlocked the first cut
     * (measured: the program hung at 0% CPU). Interned names are stable
     * pointers, so the snapshot stays valid after the unlock. The lock
     * is a no-op until the process goes multithreaded. */
    env_global_shared_lock();
    int snap_n = g_global_env->count;
    const char **snap = xcalloc(snap_n > 0 ? (size_t)snap_n : 1, sizeof(char *));
    for (int i = 0; i < snap_n; i++) snap[i] = g_global_env->names[i];
    env_global_shared_unlock();
    for (int i = 0; i < snap_n; i++) {
        const char *nm = snap[i];
        if (nm && !sandbox_name_allowed(nm))
            env_set_local(sbox, nm, stub);
    }
    free(snap);
    val_decref(stub);

    int saved_max = g_sandbox_loop_max;
    int saved_cap_hit = g_sandbox_cap_hit;
    long long saved_iters = g_loop_iterations;
    /* #940: the back-edge counter is the sandbox budget's second half — it
     * is saved/restored HERE, at the sandbox boundary only, never per call
     * frame (a budget on untrusted code must not reset because the chunk
     * called a function). */
    long long saved_backedge_iters = g_loop_backedge_count;
    g_sandbox_loop_max = max_iter > 0 ? max_iter : 1000000;
    g_sandbox_cap_hit = 0;
    g_loop_iterations = 0;
    g_loop_backedge_count = 0;
    /* #292: arm the allocation budget. Save/restore so nested sandbox_run (or a
     * sandbox_run invoked from already-budgeted code) composes correctly. */
    int    saved_sb_active = g_sandbox_active;
    int    saved_sb_error_latched = g_sandbox_error_latched;
    /* #965 (fix5): the sticky policy-refusal record composes the same way —
     * an inner run arms, reports, and then restores the outer run's record. */
    int    saved_sb_refusal = g_sandbox_refusal;
    int    saved_sb_refusal_kind = g_sandbox_refusal_kind;
    int    saved_sb_refusal_line = g_sandbox_refusal_line;
    char   saved_sb_refusal_msg[sizeof g_sandbox_refusal_msg];
    memcpy(saved_sb_refusal_msg, g_sandbox_refusal_msg,
           sizeof saved_sb_refusal_msg);
    size_t saved_sb_used   = g_sandbox_bytes_used;
    size_t saved_sb_max    = g_sandbox_byte_max;
    /* Names made by untrusted descriptor assembly or VM execution belong to
     * this run until a dictionary insertion promotes them (dict_set_hashed,
     * at insertion -- the only promotion site since #1014).
     * Pre-existing scope-zero host/global names retain their process lifetime
     * and pointer identity; channel keys live in their separate stable table. */
    g_sandbox_active     = 1;
    g_sandbox_error_latched = 0;
    g_sandbox_refusal    = 0;
    g_sandbox_bytes_used = 0;
    g_sandbox_byte_max   = max_bytes;

    Value *result = vm_execute(chunk, sbox);

    /* #965 (fix5): the run fails on the sticky policy-refusal record too, not
     * only on the catch-clearable g_has_error — a byte-budget refusal the
     * untrusted chunk CAUGHT is still a refused run. */
    int ok = (g_has_error || g_sandbox_refusal) ? 0 : 1;
    /* #965 (fix1): restore the budget/loop state BEFORE building any error
     * result. The dicts below are made of make_dict/make_str calls, which
     * CHARGE an armed budget — and after a refusal the budget is exhausted,
     * so each diagnostic allocation refused again and rt_error CLOBBERED
     * g_error_raw before it could be read into the message, replacing the
     * original "used U + R > M" numbers with a re-entrant refusal's. With
     * the budget disarmed first, error construction charges nothing and the
     * original diagnostic survives verbatim. cap_hit/loop_max are snapshotted
     * for the partial-run message, which is the only consumer. */
    int cap_hit = g_sandbox_cap_hit;
    int loop_max = g_sandbox_loop_max;
    g_sandbox_loop_max = saved_max;
    g_sandbox_cap_hit = saved_cap_hit;
    g_loop_iterations = saved_iters;
    g_loop_backedge_count = saved_backedge_iters;   /* #940 */
    g_sandbox_active     = saved_sb_active;
    g_sandbox_bytes_used = saved_sb_used;
    g_sandbox_byte_max   = saved_sb_max;
    /* Stop tagging names created while we assemble the host-owned diagnostic
     * wrapper. The run-owned entries remain linked until the result scan has
     * rehomed every escaped key and the temporary sandbox env is released. */
    g_sandbox_intern_scope = saved_intern_scope;

    /* A cap-truncated loop is NOT a clean run: the program continued past a
     * silently cut loop and produced partial results with exit 0. Reporting
     * ok:1 let a graded validator award its top "runs cleanly" rung to
     * infinite and truncated programs (found by iLambdaAi's grader review,
     * 2026-08-17). Surface it as a structured sandbox error instead. */
    if (ok && cap_hit) {
        ok = 0;
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str("sandbox"));
        char capmsg[96];
        snprintf(capmsg, sizeof(capmsg),
                 "loop budget exhausted (max_iterations=%d): partial run",
                 loop_max);
        dict_set_owned(ev, "message", make_str(capmsg));
        dict_set_owned(ev, "line", make_num(0));
        dict_set_owned(out, "error", ev);
    }
    if (!ok && g_sandbox_refusal) {
        /* #965 (fix5): the run failed BECAUSE of a sandbox policy refusal —
         * report the FIRST refusal's own triple. Not the latched g_error_*,
         * which an earlier caught ordinary error (e.g. throw("sentinel")) may
         * occupy without being a refusal; and not a later error. */
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind",
                       make_str(err_kind_name((ErrKind)g_sandbox_refusal_kind)));
        dict_set_owned(ev, "message", make_str(g_sandbox_refusal_msg));
        dict_set_owned(ev, "line", make_num((double)g_sandbox_refusal_line));
        dict_set_owned(out, "error", ev);
        if (g_has_error) {
            g_has_error = 0;
            eigs_clear_error_value();
        }
    } else if (g_has_error) {
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

    /* A callable in the result is a containment break, not a value: calling it
     * from the host runs sandbox-authored code with the caps already restored.
     * Drop the result and report it as a sandbox denial — same {kind, message,
     * line} shape as any other refusal, so a grading ladder sees it. */
    long scan_budget = SANDBOX_RESULT_MAX_NODES;
    int scan_unverified = 0;
    int scan_hit = result &&
        sandbox_value_has_callable(result, 0, &scan_budget, &scan_unverified);
    /* #1014: a second walk once re-homed dictionary keys at this result
     * boundary. Measured: dict_set_hashed promotes at INSERTION whenever a
     * sandbox intern scope is open, so that walk changed 0 of 128 keys on
     * the test that exercises it -- redundant, and deleted with its
     * promote_keys arm. */
    if (scan_hit) {
        val_decref(result);
        result = NULL;
    }
    if (scan_hit && ok) {
        ok = 0;
        Value *ev = make_dict(3);
        dict_set_owned(ev, "kind", make_str(err_kind_name(EK_SANDBOX)));
        dict_set_owned(ev, "message",
                       make_str(scan_unverified
                                ? "sandbox result too large to scan for "
                                  "callables (exceeds the result node/depth "
                                  "budget); refusing to cross the boundary"
                                : "sandbox result contains a callable; "
                                  "functions cannot cross the sandbox boundary"));
        dict_set_owned(ev, "line", make_num(0));
        dict_set_owned(out, "error", ev);
    }

    Value *okv = make_num((double)ok);
    dict_set(out, "ok", okv);   /* dict_set increfs; drop our ref */
    val_decref(okv);
    if (result) { dict_set(out, "result", result); val_decref(result); }
    chunk_free(chunk);
    env_decref(sbox);
    env_intern_scope_end(intern_scope, saved_intern_scope);
    g_sandbox_error_latched = saved_sb_error_latched;
    g_sandbox_refusal      = saved_sb_refusal;
    g_sandbox_refusal_kind = saved_sb_refusal_kind;
    g_sandbox_refusal_line = saved_sb_refusal_line;
    memcpy(g_sandbox_refusal_msg, saved_sb_refusal_msg,
           sizeof saved_sb_refusal_msg);
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
    /* #827: no name to narrow on — a self-hosted compiler calling this is
     * standing in for the whole-program arming, so it gets the wildcard. */
    if (on) { trace_arm_history_all(); trace_flag_store(g_trace_obs_hist_storage, 1); }
    else    trace_history_disable();
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
 * Copies elements from src into dest starting at dest_offset:
 * `copy_into of [dest, offset, src]`. Lists into a list; a buffer or a list
 * of numbers into a buffer. Mutates dest in-place, returns dest.
 * #1069: every failure used to `return make_null()` silently -- a wrong arity,
 * a non-list dest, a swapped argument order (docs/BUILTINS.md listed
 * [dest, src, offset] while this read [dest, offset, src]) -- and a buffer
 * destination was one of them. Loud now, like the rest of the numeric
 * contexts; the doc row states the order this code reads. */
Value* builtin_copy_into(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "copy_into requires [dest, offset, src]");
        return make_null();
    }
    Value *dest = arg->data.list.items[0];
    Value *offv = arg->data.list.items[1];
    Value *src = arg->data.list.items[2];
    if (!offv || offv->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "copy_into: offset must be a number, got %s (the order is [dest, offset, src])",
                 offv ? val_type_name(offv->type) : "null");
        return make_null();
    }
    int offset = (int)offv->data.num;
    if (offset < 0) { rt_error(EK_INDEX, 0, "copy_into: offset %d is negative", offset); return make_null(); }
    if (dest && dest->type == VAL_BUFFER) {
        /* buffer destination: numbers from a buffer or a list of numbers */
        if (src && src->type == VAL_BUFFER) {
            for (int i = 0; i < src->data.buffer.count && offset + i < dest->data.buffer.count; i++)
                dest->data.buffer.data[offset + i] = src->data.buffer.data[i];
            return dest;   /* borrowed, like the list path below */
        }
        if (src && src->type == VAL_LIST) {
            for (int i = 0; i < src->data.list.count && offset + i < dest->data.buffer.count; i++) {
                Value *it = src->data.list.items[i];
                if (!it || it->type != VAL_NUM) {
                    rt_error(EK_TYPE, 0, "cannot store %s in a buffer (copy_into element %d; buffers hold numbers)",
                             it ? val_type_name(it->type) : "null", i);
                    return make_null();
                }
                dest->data.buffer.data[offset + i] = it->data.num;
            }
            return dest;   /* borrowed, like the list path below */
        }
        rt_error(EK_TYPE, 0, "copy_into: a buffer destination takes a buffer or a list source, got %s",
                 src ? val_type_name(src->type) : "null");
        return make_null();
    }
    if (!dest || dest->type != VAL_LIST || !src || src->type != VAL_LIST) {
        rt_error(EK_TYPE, 0, "copy_into: dest and src must be lists (or a buffer dest), got %s and %s",
                 dest ? val_type_name(dest->type) : "null", src ? val_type_name(src->type) : "null");
        return make_null();
    }
    for (int i = 0; i < src->data.list.count && offset + i < dest->data.list.count; i++) {
        Value *item = src->data.list.items[i];
        /* #873: promote arena items landing in a heap destination. */
        if (item && item->arena && !dest->arena) {
            Value *promoted = promote_if_arena(item);
            if (promoted != item) {
                val_decref(dest->data.list.items[offset + i]);
                dest->data.list.items[offset + i] = promoted;
                continue;
            }
        }
        val_incref(item);
        val_decref(dest->data.list.items[offset + i]);
        dest->data.list.items[offset + i] = item;
    }
    return dest;
}

/* ==== BUILTIN: list_slice ==== */
/* list_slice of [list, start, end] → new list with the elements of [start, end).
 * Dual of copy_into (which copies a range IN). Negative indices count from the
 * end (like get_at/set_at, #312); both bounds then clamp to [0, len].
 * start >= end gives []. Never raises on bounds. */
Value* builtin_list_slice(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *list = arg->data.list.items[0];
    if (!list || list->type != VAL_LIST) return make_null();
    Value *start_v = arg->data.list.items[1];
    Value *end_v = arg->data.list.items[2];
    if (!start_v || start_v->type != VAL_NUM || !end_v || end_v->type != VAL_NUM)
        return make_null();
    int n = list->data.list.count;
    int start = (int)start_v->data.num;
    int end = (int)end_v->data.num;
    if (start < 0) start += n;
    if (end < 0) end += n;
    if (start < 0) start = 0;
    if (start > n) start = n;
    if (end < 0) end = 0;
    if (end > n) end = n;
    if (start >= end) return make_list(0);
    int out_n = end - start;
    /* #292: charge the new slots, same as concat. */
    if (!sandbox_charge((size_t)out_n * sizeof(Value *))) return make_null();
    Value *result = make_list(out_n);
    for (int i = start; i < end; i++)
        list_append(result, list->data.list.items[i]);
    return result;
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
        /* #873: promote an arena value stored into a heap list. */
        if (val && val->arena && !list->arena) {
            Value *promoted = promote_if_arena(val);
            if (promoted != val) {
                val_decref(list->data.list.items[idx]);
                list->data.list.items[idx] = promoted;
                return list;
            }
        }
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
        /* #873: promote an arena value stored into a heap row. */
        if (val && val->arena && !rowv->arena) {
            Value *promoted = promote_if_arena(val);
            if (promoted != val) {
                val_decref(rowv->data.list.items[col]);
                rowv->data.list.items[col] = promoted;
                return list;
            }
        }
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
        /* #989: a 1-parameter callee RE-COLLECTS the whole argument list at
         * every other entry point (`one of [5, 6]` binds `a = [5, 6]`), but
         * here `bind_n = min(...)` bound 5 and dropped 6 with no diagnostic.
         * Over-arity on 2+-param callees is refused at the spawn site, so
         * this was the last place surplus arguments could still vanish
         * silently. Re-collect instead of truncating, matching the oracle. */
        int recollected = (fn->data.fn.param_count == 1 && h->fn_arg_count > 1);
        if (recollected) {
            Value *collected = make_list(h->fn_arg_count);
            for (int i = 0; i < h->fn_arg_count; i++)
                list_append(collected, h->fn_args[i]);
            env_set_local_owned(call_env, fn->data.fn.params[0], collected);
        }
        for (int i = 0; !recollected && i < bind_n; i++) {
            env_set_local(call_env, fn->data.fn.params[i], h->fn_args[i]);
        }
        /* Under-arity null-fill — skipped when the single slot was
         * re-collected above, or it would overwrite the collected list. */
        for (int i = bind_n; !recollected && i < fn->data.fn.param_count; i++) {
            env_set_local_owned(call_env, fn->data.fn.params[i], make_null());
        }
        Value *result = make_null();
        g_returning = 0;
        g_return_val = NULL;
        if (fn->data.fn.body_count == -1) {
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            if (fn_chunk->local_count > fn->data.fn.param_count)
                env_reserve_slots(call_env, fn_chunk->local_count);
            /* #997: state the REAL argc so an under-arity spawn still fires
             * the callee's defaults — `spawn of [d, 1]` on
             * `define d(a, b is 3)` bound b = null where `d of 1` binds 3.
             * A re-collected single slot counts as one supplied argument. */
            int supplied = recollected ? 1 : h->fn_arg_count;
            result = vm_execute_argc(fn_chunk, call_env, supplied);
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
        int consumes_arg = (fn->data.builtin == builtin_free_val);
        Value *result = fn->data.builtin(bin_arg);
        /* #720: this site owns bin_arg (increfed above, or freshly built)
         * and drops it below, so it runs the VM's own contract —
         * caller_owns_arg=1, and `result == bin_arg` transfers rather than
         * being decrefed. `spawn of [append, xs, 5]` returns a borrowed
         * direct child and used to hand the handle a ref it never held. */
        if (!result) {
            result = make_null();
        } else if (!consumes_arg) {
            vm_borrow_compensate(bin_arg, result, 1, fn, NULL);
        }
        if (!consumes_arg && result != bin_arg) val_decref(bin_arg);
        /* The handle takes over the now-owned ref (see the VAL_FN path
         * above) — no extra incref, which would leak. */
        h->result = result;
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
    /* #989: `spawn of [fn, 1, 2, 3]` onto a 2-param fn dropped the third arg
     * inside thread_entry. Raise HERE, not in the worker: the mismatch is
     * fully known before the thread exists, and an error raised on a spawned
     * thread has no good way back to the spawning program — it would surface
     * as a worker that quietly returned the wrong answer. Same kind and
     * message as the direct call path; the arity-1 re-collect carve-out does
     * not apply (spawn passes its args flat, never as one re-collected list). */
    if (fn->type == VAL_FN && fn->data.fn.param_count >= 2 &&
        fn_arg_count > fn->data.fn.param_count) {
        int pc = fn->data.fn.param_count;
        for (int i = 0; i < fn_arg_count; i++) val_decref(fn_args[i]);
        free(fn_args);
        rt_error(EK_VALUE, 0, "call passes %d arguments but the callee takes %d",
                 fn_arg_count, pc);
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
    /* #827: #739's per-thread history is filtered by a PROCESS-global armed-name
     * set that the compiler grows. Single-threaded that is fine (compile, then
     * run), but a worker calling eval/load_file compiles concurrently with other
     * workers recording assignments — a realloc of the name array under a
     * reader is a use-after-free, not just a torn read. So the last
     * single-threaded act before the first spawn is to widen to the wildcard,
     * permanently: from here the filter reads only the two ints (the same
     * benign shape as g_trace_hist itself) and the name array is never touched
     * again. Costs nothing that matters — the history is bounded either way
     * now; the narrowing is a per-assign CPU optimization for the
     * single-threaded long-running programs #827 was actually about. */
    trace_arm_history_all_mt();
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
            /* Same rebalance as task_do_kill: a task torn down while suspended
             * inside a try never runs its TRY_ENDs, and the leftover process-
             * global depth silences every later uncaught error (#726). The
             * g_try_depth fixup is frame bookkeeping, not an owned ref, so it
             * stays here; the owned-field drop (env iff owns_env, then chunk)
             * goes through vm.c's shared callframe_release (#743) — this is the
             * third saved-frame teardown loop, matching the two in vm.c. */
            g_try_depth -= f->try_count;
            callframe_release(f);
        }
        if (g_try_depth < 0) g_try_depth = 0;
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
    /* #989: same over-arity hole as spawn, on the cooperative-task path
     * (task_start, vm.c). Raised here at spawn time for the same reason —
     * the task has not started, so the error lands on the line that made
     * the mistake instead of inside a scheduled task. */
    if (fn->type == VAL_FN && fn->data.fn.param_count >= 2 &&
        argc > fn->data.fn.param_count) {
        int pc = fn->data.fn.param_count;
        for (int i = 0; i < argc; i++) val_decref(args[i]);
        free(args);
        rt_error(EK_VALUE, 0, "call passes %d arguments but the callee takes %d",
                 argc, pc);
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
 * inside, so no cooperative task switch occurs while it is set. PER THREAD
 * (#1036): the old process-global counter predated pthread workers; two
 * workers' non-atomic ++/-- raced (TSan 3/3), and a lost decrement left the
 * counter stuck nonzero for the whole process, poisoning every later
 * guarded operation with spurious raises. A region belongs to the thread
 * that entered it, so thread-local storage is the exact scope: no race, and
 * one worker's region never forbids another's yields. */
static __thread int g_no_yield_depth = 0;

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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "task_send", "[id, value]", make_num(0));
    Value *idv = arg->data.list.items[0];
    /* The type guard precedes the scheduler-state check deliberately. With the
     * state check first, `task_send of ["x", 1]` outside a task context
     * returned 0 without ever reaching this guard — a guard nothing can
     * trigger, and the differential's probe (which spawns a task first) could
     * not see it. `task_kill` and `stream_write` already order it this way.
     * Non-strict is unchanged: both halves answer 0. */
    ARG_GUARD(!idv || idv->type != VAL_NUM, "task_send", "a task id (number)", make_num(0));
    /* fs:ANSWER no scheduler means there is no task to deliver to, which is
     * the dead-letter drop this function's contract documents ("0 if
     * dropped") — split out of the arity guard above, which is a mistake. */
    if (!g_task_sched) return make_num(0);
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
    ARG_GUARD(!arg || arg->type != VAL_NUM, "task_kill", "a task id (number)", make_num(0));
    /* fs:ANSWER no scheduler means no such target; 0 is the documented
     * "bad/self/finished target" answer, split from the type guard above. */
    if (!g_task_sched) return make_num(0);
    return make_num(task_do_kill((int)arg->data.num) ? 1 : 0);
}

/* task_alive of id → 1 while the task is READY/RUNNING/SUSPENDED, else 0
 * (DONE, DEAD, or an unknown id). */
Value* builtin_task_alive(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_NUM, "task_alive", "a task id (number)", make_num(0));
    Task *t = (Task*)handle_lookup((int)arg->data.num, HANDLE_TASK);
    /* fs:ANSWER an unknown id is NOT alive; 0 is this function's documented
     * answer. Four lines above, an identical `return make_num(0)` is a type
     * guard that DID convert — the pair Phase A pinned as the reason this
     * phase is read by hand and not swept. Do not convert this one. */
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
#if EIGENSCRIPT_EXT_NET
    /* #414 sockets: an outstanding listener/connection at exit is an OS fd
     * plus one malloc'd row — close and free. No thread can still be using
     * it: every worker was joined above. */
    for (int i = 1; i < HANDLE_TABLE_SIZE; i++) {
        if (st->handle_table[i].type != HANDLE_NET) continue;
        EigsNetSock *ns = (EigsNetSock*)st->handle_table[i].ptr;
        if (!ns) continue;
        close(ns->fd);
        free(ns);
        st->handle_table[i].ptr = NULL;
    }
#endif

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
    /* Same buffer chokepoint as buf_from_list — reshape copies the payload. */
    if (!sandbox_charge((b->data.buffer.count > 0 ? (size_t)b->data.buffer.count : 1) * sizeof(double)))
        return make_null();
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
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    Value *buf = arg->data.list.items[0];
    if (!buf || buf->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_get: first argument must be a buffer");
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    int idx = (int)arg->data.list.items[1]->data.num;
    if (idx < 0 || idx >= buf->data.buffer.count) {
        rt_error(EK_INDEX, 0, "buffer index %d out of range (length %d)",
                 idx, buf->data.buffer.count);
        /* fs:CHANNEL the EK_INDEX rt_error above already raised (#502) */
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
    /* #1061: both operands were read through the num union member unchecked
     * -- a string index or value read garbage bits (the #1007 type-pun class).
     * Loud, like the `b[i] is v` opcode path. */
    if (arg->data.list.items[1]->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "buf_set: index must be a number, got %s", val_type_name(arg->data.list.items[1]->type));
        return make_null();
    }
    if (arg->data.list.items[2]->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "cannot store %s in a buffer (buffers hold numbers)", val_type_name(arg->data.list.items[2]->type));
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
    ARG_GUARD(!arg || arg->type != VAL_BUFFER, "buf_len", "a buffer", make_num(0));
    return make_num(arg->data.buffer.count);
}

/* buf_from_list of list — convert list of numbers to buffer */
Value* builtin_buf_from_list(Value *arg) {
    if (!arg || arg->type != VAL_LIST) return make_null();
    int n = arg->data.list.count;
    /* Sandbox chokepoint: the only two buffer producers not routed through the
     * charged make_shaped_buffer/buf_alloc_flat allocators (this + reshape).
     * Per-call output == input, but a loop re-using one charged input spawns N
     * uncharged copies past the budget (blind round, 2026-08-17): 50 copies of
     * an 800k buffer held 320MB under the 256MB default and abort under a
     * ulimit. Charge like every other buffer producer. */
    if (!sandbox_charge((n > 0 ? (size_t)n : 1) * sizeof(double))) return make_null();
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = n;
    v->data.buffer.data = xcalloc(n > 0 ? n : 1, sizeof(double));
    v->refcount = 1;
    for (int i = 0; i < n; i++) {
        if (arg->data.list.items[i]->type == VAL_NUM) {
            v->data.buffer.data[i] = arg->data.list.items[i]->data.num;
        } else {
            /* #1061: a non-number element silently stayed 0.0. */
            const char *tn = val_type_name(arg->data.list.items[i]->type);
            val_decref(v);
            rt_error(EK_TYPE, 0, "buf_from_list: element %d is %s (buffers hold numbers)", i, tn);
            return make_null();
        }
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
        ARG_GUARD(1, "str_from_bytes", "a list or buffer of byte values", make_str(""));
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
    /* #965: the xcalloc above is an uncharged producer — wrap with the
     * charging copy constructor, not make_str_owned. */
    Value *r = make_str(s);
    free(s);
    return r;
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
        ARG_GUARD(1, "f64_from_bytes", "a list or buffer of 8 byte values", make_num(0));
    }
    uint64_t bits = 0;
    for (int i = 0; i < 8; i++)
        bits = (bits << 8) | (uint64_t)((int)bytes_in[i] & 0xFF);
    double d;
    memcpy(&d, &bits, sizeof(d));
    return make_num(d);
}

/* ---- DEFLATE codecs (inflate/deflate, #684) ----
 * Thin wrappers over the system zlib (-lz), gated behind
 * EIGENSCRIPT_EXT_ZLIB — the same EIGENSCRIPT_EXT_* mechanism the http
 * variant uses. Default OFF so the minimal build stays zero-dependency;
 * compiled without zlib the four names stay registered but raise a
 * catchable runtime error, so a script can feature-detect with
 * try/catch instead of dying on "undefined variable".
 *
 * Byte representation mirrors read_bytes/write_bytes exactly: input is
 * a list of ints 0-255 (values taken mod 256, non-numbers read as 0)
 * or a VAL_BUFFER; output is always a fresh list of ints 0-255.
 *
 * inflate/deflate are the RAW DEFLATE pair (windowBits -15) — the ZIP
 * member format, so .xlsx/.ods entries are readable. zlib_inflate/
 * zlib_deflate are the zlib-wrapped pair; zlib_inflate uses windowBits
 * 15+32, which auto-detects zlib AND gzip headers — that is what makes
 * plain .gz files readable.
 */
#if EIGENSCRIPT_EXT_ZLIB

/* Inflate is an amplifier: a few KB of DEFLATE can expand without bound
 * (zip bomb). Cap the decompressed size like the other size caps
 * (read_bytes 10 MB, read_bytes_buf 512 MB): over the cap is a loud,
 * catchable `limit` error, never silent truncation. 256 MiB matches the
 * sandbox_run default allocation budget. */
#define EIGS_INFLATE_MAX_OUT ((unsigned long)256 * 1024 * 1024)

/* Shared argument extraction for the four codecs: accept the byte
 * representations write_bytes accepts and copy them into a malloc'd
 * byte array. Returns 1 on success; on a wrong-shape argument raises
 * `type` and returns 0. */
static int zlib_bytes_arg(Value *arg, const char *who,
                          unsigned char **out, size_t *out_n) {
    *out = NULL;
    *out_n = 0;
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
        rt_error(EK_TYPE, 0,
                 "%s requires a list of byte values (0-255) or a buffer, got %s",
                 who, val_type_name(arg ? arg->type : VAL_NULL));
        return 0;
    }
    unsigned char *b = xmalloc((size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) {
        double dv = items ? (items[i] && items[i]->type == VAL_NUM ? items[i]->data.num : 0.0)
                          : bufd[i];
        b[i] = (unsigned char)((int)dv & 0xFF);
    }
    *out = b;
    *out_n = (size_t)n;
    return 1;
}

/* Wrap a finished byte buffer as the list-of-ints result value (the
 * read_bytes shape). Takes ownership of nothing; caller still frees. */
static Value *zlib_bytes_result(const unsigned char *buf, unsigned long n) {
    /* #292: the result is `n` fresh number Values at sizeof(Value)+sizeof(Value*)
     * each — ~80 bytes per decompressed BYTE. Charging only the codec's own
     * output buffer would therefore miss 98% of the cost, so charge the list
     * here too, with the same accounting range/zeros use. Without this an
     * allowlisted `inflate` allocates straight past max_bytes: the budget
     * bounds allocators the caller has to *name* a size for, and a compressed
     * blob names nothing. */
    if (!sandbox_charge((size_t)n * (sizeof(Value) + sizeof(Value *))))
        return make_null();
    Value *result = make_list((int)n);
    for (unsigned long i = 0; i < n; i++)
        list_append_owned(result, make_num((double)buf[i]));
    return result;
}

/* Shared inflate core. window_bits selects the wrapper (-15 raw,
 * 15+32 zlib/gzip auto-detect). A corrupt or truncated stream raises a
 * catchable `value` error; output over EIGS_INFLATE_MAX_OUT raises
 * `limit` (the zip-bomb bound). */
static Value *zlib_inflate_impl(const char *who, int window_bits, Value *arg) {
    unsigned char *src;
    size_t src_n;
    if (!zlib_bytes_arg(arg, who, &src, &src_n)) return make_null();

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (inflateInit2(&zs, window_bits) != Z_OK) {
        free(src);
        rt_error(EK_INTERNAL, 0, "%s: inflateInit2 failed", who);
        return make_null();
    }
    size_t cap = src_n * 3 + 64;
    if (cap > EIGS_INFLATE_MAX_OUT) cap = EIGS_INFLATE_MAX_OUT;
    /* #292: charge the codec's own buffer as it grows, so a bomb is refused
     * before the memory is touched rather than after. EIGS_INFLATE_MAX_OUT
     * bounds this at 256 MiB, which is the *default* whole-run budget — a
     * caller that lowered max_bytes must not be overrun by one call. */
    if (!sandbox_charge(cap)) {
        inflateEnd(&zs);
        free(src);
        return make_null();
    }
    unsigned char *out = xmalloc(cap);
    int zrc = Z_OK;
    for (;;) {
        if (zs.avail_in == 0 && zs.total_in < src_n) {
            /* uInt is 32-bit: feed a >4 GiB input in chunks. */
            zs.next_in = src + zs.total_in;
            unsigned long rem = src_n - zs.total_in;
            zs.avail_in = (uInt)(rem > UINT_MAX ? UINT_MAX : rem);
        }
        if (zs.total_out == cap) {
            if (cap >= EIGS_INFLATE_MAX_OUT) break; /* limit raise below */
            size_t ncap = cap * 2;
            if (ncap > EIGS_INFLATE_MAX_OUT) ncap = EIGS_INFLATE_MAX_OUT;
            if (!sandbox_charge(ncap - cap)) {   /* #292: charge the delta */
                inflateEnd(&zs);
                free(out);
                free(src);
                return make_null();
            }
            out = xrealloc(out, ncap);
            cap = ncap;
        }
        zs.next_out = out + zs.total_out;
        zs.avail_out = (uInt)(cap - zs.total_out);
        zrc = inflate(&zs, Z_NO_FLUSH);
        if (zrc == Z_STREAM_END) break;
        if (zrc != Z_OK) break;
        if (zs.avail_out != 0 && zs.total_in == src_n) {
            /* Output not full yet zlib made no progress: input ran out
             * mid-stream — truncated. */
            zrc = Z_BUF_ERROR;
            break;
        }
    }
    if (zrc != Z_STREAM_END) {
        if (zrc == Z_OK && zs.total_out >= EIGS_INFLATE_MAX_OUT) {
            inflateEnd(&zs);
            free(out);
            free(src);
            rt_error(EK_LIMIT, 0,
                     "%s: decompressed output exceeds the %lu-byte cap",
                     who, EIGS_INFLATE_MAX_OUT);
            return make_null();
        }
        const char *msg = zs.msg;
        inflateEnd(&zs);
        free(out);
        free(src);
        rt_error(EK_VALUE, 0, "%s: invalid or truncated compressed stream (%s)",
                 who, msg ? msg : "unexpected end of input");
        return make_null();
    }
    unsigned long n = zs.total_out;
    inflateEnd(&zs);
    free(src);
    Value *result = zlib_bytes_result(out, n);
    free(out);
    return result;
}

/* Shared deflate core (dual of zlib_inflate_impl). The output buffer is
 * deflateBound-sized up front, so a single Z_FINISH pass always fits. */
static Value *zlib_deflate_impl(const char *who, int window_bits, Value *arg) {
    unsigned char *src;
    size_t src_n;
    if (!zlib_bytes_arg(arg, who, &src, &src_n)) return make_null();

    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window_bits,
                     8, Z_DEFAULT_STRATEGY) != Z_OK) {
        free(src);
        rt_error(EK_INTERNAL, 0, "%s: deflateInit2 failed", who);
        return make_null();
    }
    uLong bound = deflateBound(&zs, (uLong)src_n);
    /* #292: deflate amplifies far less than inflate (bound ~= src_n), but the
     * budget should account for every codec buffer, not just the dangerous
     * one — an uncharged allocator is a gap whether or not it is exploitable. */
    if (!sandbox_charge((size_t)bound)) {
        deflateEnd(&zs);
        free(src);
        return make_null();
    }
    unsigned char *out = xmalloc(bound > 0 ? bound : 1);
    size_t pos = 0;
    int zrc = Z_OK;
    for (;;) {
        if (zs.avail_in == 0 && pos < src_n) {
            unsigned long rem = src_n - pos;
            uInt chunk = (uInt)(rem > UINT_MAX ? UINT_MAX : rem);
            zs.next_in = src + pos;
            zs.avail_in = chunk;
            pos += chunk;
        }
        int flush = (pos == src_n && zs.avail_in == 0) ? Z_FINISH : Z_NO_FLUSH;
        zs.next_out = out + zs.total_out;
        zs.avail_out = (uInt)(bound - zs.total_out);
        zrc = deflate(&zs, flush);
        if (zrc == Z_STREAM_END) break;
        if (zrc != Z_OK && zrc != Z_BUF_ERROR) break;
        if (flush == Z_FINISH) break; /* cannot happen with bound space */
    }
    if (zrc != Z_STREAM_END) {
        const char *msg = zs.msg;
        deflateEnd(&zs);
        free(out);
        free(src);
        rt_error(EK_INTERNAL, 0, "%s: deflate failed (%s)",
                 who, msg ? msg : "unknown zlib error");
        return make_null();
    }
    unsigned long n = zs.total_out;
    deflateEnd(&zs);
    free(src);
    Value *result = zlib_bytes_result(out, n);
    free(out);
    return result;
}

Value* builtin_inflate(Value *arg)      { return zlib_inflate_impl("inflate", -15, arg); }
Value* builtin_zlib_inflate(Value *arg) { return zlib_inflate_impl("zlib_inflate", 15 + 32, arg); }
Value* builtin_deflate(Value *arg)      { return zlib_deflate_impl("deflate", -15, arg); }
Value* builtin_zlib_deflate(Value *arg) { return zlib_deflate_impl("zlib_deflate", 15, arg); }

#else /* !EIGENSCRIPT_EXT_ZLIB */

/* Minimal build: the names exist so scripts can feature-detect (and the
 * sandbox allowlist can name real builtins), but every call raises a
 * clear catchable error pointing at the zlib build. */
static Value *zlib_unavailable(const char *who) {
    rt_error(EK_VALUE, 0,
             "%s: compiled without zlib support (rebuild with `make zlib`)",
             who);
    return make_null();
}

Value* builtin_inflate(Value *arg)      { (void)arg; return zlib_unavailable("inflate"); }
Value* builtin_zlib_inflate(Value *arg) { (void)arg; return zlib_unavailable("zlib_inflate"); }
Value* builtin_deflate(Value *arg)      { (void)arg; return zlib_unavailable("deflate"); }
Value* builtin_zlib_deflate(Value *arg) { (void)arg; return zlib_unavailable("zlib_deflate"); }

#endif /* EIGENSCRIPT_EXT_ZLIB */


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
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    Value *buf = arg->data.list.items[0];
    long long count, off;
    if (!buf_count_arg("buf_peak", arg->data.list.items[2], &count) ||
        !buf_window_arg("buf_peak", buf, arg->data.list.items[1], count, &off))
        /* fs:CHANNEL buf_count_arg/buf_window_arg raise before returning 0 */
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
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    long long count, a_off, b_off;
    if (!buf_count_arg("buf_dot", arg->data.list.items[4], &count) ||
        !buf_window_arg("buf_dot", a, arg->data.list.items[2], count, &a_off) ||
        !buf_window_arg("buf_dot", b, arg->data.list.items[3], count, &b_off))
        /* fs:CHANNEL buf_count_arg/buf_window_arg raise before returning 0 */
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "sign_extend", "[val, bits]", make_num(0));
    /* The ELEMENT type check below is new, and it is the one place in this
     * change where the non-strict result is not byte-identical to before.
     * It was not fail-softness — it was a union type-pun: both reads below
     * took `.data.num` off items that were never checked, so
     * `sign_extend of ["x", 8]` reinterpreted a `char *` as a `double` and
     * sign-extended whatever that produced. There is no previous behaviour
     * to preserve, because the previous behaviour was undefined; 0 is the
     * same stand-in every sibling here uses. Filed as its own issue. */
    Value *v0 = arg->data.list.items[0], *v1 = arg->data.list.items[1];
    ARG_GUARD(!v0 || v0->type != VAL_NUM || !v1 || v1->type != VAL_NUM, "sign_extend", "two numbers", make_num(0));
    double val = v0->data.num;
    int bits = (int)v1->data.num;
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

/* list_insert_at of [list, index, value] — insert value at index, shift tail
 * up. Dual of list_remove_at. index == count appends; any other out-of-bounds
 * index is a no-op. Returns the list. */
Value* builtin_list_insert_at(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *list = arg->data.list.items[0];
    Value *idx_val = arg->data.list.items[1];
    Value *val = arg->data.list.items[2];
    if (!list || list->type != VAL_LIST) return make_null();
    if (!idx_val || idx_val->type != VAL_NUM) return list;
    int idx = (int)idx_val->data.num;
    int count = list->data.list.count;
    if (idx < 0 || idx > count) return list;
    if (idx == count) {
        list_append(list, val);
        return list;
    }
    /* Grow by one slot (list_append handles capacity + arena lists), then move
     * the tail up one place and drop the value into the vacated slot.
     * list_append increfs the old last element, but the memmove overwrites
     * its original slot with a raw pointer copy (no decref) — balance that
     * spurious incref afterwards so old_last keeps exactly the one reference
     * its single remaining slot owns. It still occupies slot [count] at that
     * point, so the decref cannot free it. */
    Value *old_last = list->data.list.items[count - 1];
    list_append(list, old_last);
    memmove(&list->data.list.items[idx + 1], &list->data.list.items[idx],
            (count - idx) * sizeof(Value *));
    /* #873: promote an arena value inserted into a heap list. */
    if (val && val->arena && !list->arena) {
        Value *promoted = promote_if_arena(val);
        if (promoted != val) {
            list->data.list.items[idx] = promoted;
            val_decref(old_last);
            return list;
        }
    }
    val_incref(val);
    list->data.list.items[idx] = val;
    val_decref(old_last);
    return list;
}

/* list_index_of of [list, value] — index of the first element structurally
 * equal to value, reusing values_equal (the same comparison `==` uses), so
 * nested lists and dicts match by structure. -1 when absent. Bad args give
 * -1, mirroring index_of's miss. (That parenthetical used to say there was
 * "no raise mechanism in the builtin layer"; ARG_GUARD is one, and #1008
 * wired these guards into it — the -1 still stands with the flag off.) */
Value* builtin_list_index_of(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "list_index_of", "[list, value]", make_num(-1));
    Value *list = arg->data.list.items[0];
    Value *needle = arg->data.list.items[1];
    ARG_GUARD(!list || list->type != VAL_LIST,
              "list_index_of", "a list as its first argument", make_num(-1));
    for (int i = 0; i < list->data.list.count; i++) {
        if (values_equal(list->data.list.items[i], needle))
            return make_num((double)i);
    }
    /* fs:ANSWER the whole list was scanned and nothing equalled the needle —
     * -1 is list_index_of's documented miss. */
    return make_num(-1);
}

/* list_contains of [list, value] — 1 if any element structurally equals
 * value (same values_equal scan as list_index_of), else 0. Bad args give 0,
 * mirroring contains. */
Value* builtin_list_contains(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "list_contains", "[list, value]", make_num(0));
    Value *list = arg->data.list.items[0];
    Value *needle = arg->data.list.items[1];
    ARG_GUARD(!list || list->type != VAL_LIST, "list_contains", "a list as its first argument", make_num(0));
    for (int i = 0; i < list->data.list.count; i++) {
        if (values_equal(list->data.list.items[i], needle))
            return make_num(1);
    }
    /* fs:ANSWER the scan completed and found nothing; 0 is the predicate's
     * answer, not a stand-in for a rejected argument. */
    return make_num(0);
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
        /* #989: the key function itself raised (over-arity, or anything its
         * body threw). Its error is the real one — reporting "must return a
         * number" on top of it would bury the cause under a symptom. */
        if (g_has_error) {
            if (kv) val_decref(kv);
            free(pairs);
            return make_null();
        }
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
        /* free_val CONSUMES a reference, and fn_arg is a child of our own
         * arg vector, which still points at it — lend it a ref of our own
         * making rather than the arg vector's (#720). */
        if (fn->data.builtin == builtin_free_val) {
            if (fn_arg) val_incref(fn_arg);
            Value *consumed = fn->data.builtin(fn_arg);
            return consumed ? consumed : make_null();
        }
        Value *result = fn->data.builtin(fn_arg);
        if (!result) return make_null();
        /* #720: the inner builtin may return a borrow of fn_arg, which is a
         * *grandchild* of our own arg vector — one level deeper than any
         * caller's direct-child scan can see. Own it here, per the protocol's
         * rule that a deeper-than-direct-child borrow is the builtin's to
         * incref. caller_owns_arg=1 deliberately leaves `result == fn_arg`
         * a raw borrow: that IS a direct child of our arg, so our own
         * caller's compensation covers it, and increfing here would
         * double-count into a leak. */
        vm_borrow_compensate(fn_arg, result, 1, fn, NULL);
        return result;
    }

    if (fn->type == VAL_FN) {
        int dpc = fn->data.fn.param_count;
        Env *call_env = env_new(fn->data.fn.closure);
        if (dpc > 0) {
            env_set_local(call_env, fn->data.fn.params[0], fn_arg);
        }
        if (fn->data.fn.body_count == -1) {
            /* Bytecode function */
            EigsChunk *fn_chunk = (EigsChunk *)fn->data.fn.body;
            /* #997: mirror CASE(DISPATCH) (vm.c). This C fallback fed
             * call_argc = param_count, so the callee's OP_DEFAULT_PARAM
             * prologue never fired and `dispatch of argv` gave [1, null]
             * where the compiled OP_DISPATCH form of the SAME call, and a
             * direct `d of 1`, both give [1, 3]. The two forms are chosen by
             * a compiler guard that falls back here whenever the unit merely
             * MENTIONS eval (#459), so an unrelated eval reference silently
             * changed parameter binding.
             *
             * CASE(DISPATCH) additionally null-fills slots [1, param_count)
             * before running the prologue. That is NOT needed here and is
             * deliberately omitted: this path enters through vm_run_ex, whose
             * first act is `if (chunk->local_count > env->count)
             * env_reserve_slots(...)`, so the slots exist by the time
             * OP_DEFAULT_PARAM writes them. CASE(DISPATCH) is a mid-execution
             * frame push and gets no such entry reserve, which is why it
             * carries its own fill. Verified by removing the fill here: all
             * repros still pass (mechanical-gates §42 — a mutation that
             * survives may mean redundant, so prove which and delete it). */
            if (fn_chunk->local_count > dpc)
                env_reserve_slots(call_env, fn_chunk->local_count);
            Value *result = vm_execute_argc(fn_chunk, call_env, dpc > 0 ? 1 : 0);
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
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2, "dot", "[a, b]", make_num(0));
    Value *a = arg->data.list.items[0];
    Value *b = arg->data.list.items[1];
    ARG_GUARD(!a || !b || a->type != VAL_BUFFER || b->type != VAL_BUFFER, "dot", "two buffers", make_num(0));
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
    env_set_local_owned(env, "usleep", make_builtin(builtin_usleep));
    env_set_local_owned(env, "monotonic_ns", make_builtin(builtin_monotonic_ns));
    env_set_local_owned(env, "monotonic_ms", make_builtin(builtin_monotonic_ms));
    env_set_local_owned(env, "clock_unix", make_builtin(builtin_clock_unix));
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
    env_set_local_owned(env, "math_flags", make_builtin(builtin_math_flags));            /* #865 */
    env_set_local_owned(env, "clear_math_flags", make_builtin(builtin_clear_math_flags));
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
    env_set_local_owned(env, "free_val", make_builtin(builtin_free_val));
    env_set_local_owned(env, "contains", make_builtin(builtin_contains));
    env_set_local_owned(env, "starts_with", make_builtin(builtin_starts_with));
    env_set_local_owned(env, "split", make_builtin(builtin_split));
    env_set_local_owned(env, "scan_ints", make_builtin(builtin_scan_ints));
    env_set_local_owned(env, "scan_tokens", make_builtin(builtin_scan_tokens));
    env_set_local_owned(env, "scan_int_tokens", make_builtin(builtin_scan_int_tokens));
    env_set_local_owned(env, "trim", make_builtin(builtin_trim));
    env_set_local_owned(env, "str_replace", make_builtin(builtin_str_replace));
    env_set_local_owned(env, "env_get", make_builtin(builtin_env_get));

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
    env_set_local_owned(env, "state_at", make_builtin(builtin_state_at));
    env_set_local_owned(env, "secure_equals", make_builtin(builtin_secure_equals));
    env_set_local_owned(env, "try_parse", make_builtin(builtin_try_parse));
    env_set_local_owned(env, "eval", make_builtin(builtin_eval));
    env_set_local_owned(env, "vm_run_bytecode", make_builtin(builtin_vm_run_bytecode));
    env_set_local_owned(env, "record_history", make_builtin(builtin_record_history));
    env_set_local_owned(env, "sandbox_run", make_builtin(builtin_sandbox_run));
    env_set_local_owned(env, "copy_into", make_builtin(builtin_copy_into));
    env_set_local_owned(env, "list_slice", make_builtin(builtin_list_slice));
    env_set_local_owned(env, "num_copy", make_builtin(builtin_num_copy));
    env_set_local_owned(env, "concat", make_builtin(builtin_concat));
    env_set_local_owned(env, "range", make_builtin(builtin_range));
    env_set_local_owned(env, "arena_mark", make_builtin(builtin_arena_mark));
    env_set_local_owned(env, "arena_reset", make_builtin(builtin_arena_reset));
    env_set_local_owned(env, "arena_stats", make_builtin(builtin_arena_stats));
    env_set_local_owned(env, "heap_inuse", make_builtin(builtin_heap_inuse));

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
    /* DEFLATE codecs (#684) — registered unconditionally; the bodies
     * raise "compiled without zlib support" when EIGENSCRIPT_EXT_ZLIB=0. */
    env_set_local_owned(env, "inflate", make_builtin(builtin_inflate));
    env_set_local_owned(env, "zlib_inflate", make_builtin(builtin_zlib_inflate));
    env_set_local_owned(env, "deflate", make_builtin(builtin_deflate));
    env_set_local_owned(env, "zlib_deflate", make_builtin(builtin_zlib_deflate));
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
    env_set_local_owned(env, "list_insert_at", make_builtin(builtin_list_insert_at));
    env_set_local_owned(env, "list_index_of", make_builtin(builtin_list_index_of));
    env_set_local_owned(env, "list_contains", make_builtin(builtin_list_contains));
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

#if EIGENSCRIPT_EXT_NET
    register_net_builtins(env);
#endif

#if EIGENSCRIPT_EXT_MODEL
    register_model_builtins(env);
#endif

#if EIGENSCRIPT_EXT_GFX
    register_gfx_builtins(env);
#endif

    /* EigenStore — always compiled (ext_store.c; freestanding builds get
     * its linkable no-op). gfx and store used to be registered by hand at
     * every entry point (#742): main.c only for gfx, so `make gfx` used
     * through the embed API had NO gfx builtins. Every entry point now
     * composes the global env through this one seam — new registrars go
     * HERE, never at a call site. */
    register_store_builtins(env);

#if EIGS_BORROW_GUARD
    /* #548 guard self-test hook — see builtin_borrow_guard_selftest. */
    if (eigs_env_flag("EIGS_BORROW_GUARD_SELFTEST"))
        env_set_local_owned(env, "__borrow_guard_selftest", make_builtin(builtin_borrow_guard_selftest));
#endif

    /* ---- Host-only builtins (#741): one registrar, whole-TU gated ---- */
    register_host_builtins(env);

    /* Everything bound above this line is the language; everything bound after
     * it belongs to whatever program is running. See eigs_is_registered_builtin. */
    g_builtin_binding_count = env->count;
}
