/* #1758 N9: all width operations share this descriptor table and engine.
 * N5/range validation precedes arithmetic; unsigned intermediates avoid UB. */
#include "eigenscript.h"
#include "container.h"
#include "builtins_internal.h"
#include <stdint.h>
#include <string.h>
#include <stdio.h>

typedef enum { N9_WRAP, N9_CHECK, N9_SAT } N9Mode;
typedef enum { N9_ADD, N9_SUB, N9_MUL } N9Op;
typedef struct {
    const char *name;
    unsigned width;
    int is_signed;
    N9Mode mode;
    N9Op op;
    int64_t lo, hi;
} N9Spec;
static const N9Spec n9_specs[] = {
    {"i8_wrapping_add", 8, 1, N9_WRAP, N9_ADD, (-INT64_C(128)), INT64_C(127)},
    {"i8_wrapping_sub", 8, 1, N9_WRAP, N9_SUB, (-INT64_C(128)), INT64_C(127)},
    {"i8_wrapping_mul", 8, 1, N9_WRAP, N9_MUL, (-INT64_C(128)), INT64_C(127)},
    {"i8_checked_add", 8, 1, N9_CHECK, N9_ADD, (-INT64_C(128)), INT64_C(127)},
    {"i8_checked_sub", 8, 1, N9_CHECK, N9_SUB, (-INT64_C(128)), INT64_C(127)},
    {"i8_checked_mul", 8, 1, N9_CHECK, N9_MUL, (-INT64_C(128)), INT64_C(127)},
    {"i8_saturating_add", 8, 1, N9_SAT, N9_ADD, (-INT64_C(128)), INT64_C(127)},
    {"i8_saturating_sub", 8, 1, N9_SAT, N9_SUB, (-INT64_C(128)), INT64_C(127)},
    {"i8_saturating_mul", 8, 1, N9_SAT, N9_MUL, (-INT64_C(128)), INT64_C(127)},
    {"i16_wrapping_add", 16, 1, N9_WRAP, N9_ADD, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_wrapping_sub", 16, 1, N9_WRAP, N9_SUB, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_wrapping_mul", 16, 1, N9_WRAP, N9_MUL, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_checked_add", 16, 1, N9_CHECK, N9_ADD, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_checked_sub", 16, 1, N9_CHECK, N9_SUB, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_checked_mul", 16, 1, N9_CHECK, N9_MUL, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_saturating_add", 16, 1, N9_SAT, N9_ADD, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_saturating_sub", 16, 1, N9_SAT, N9_SUB, (-INT64_C(32768)), INT64_C(32767)},
    {"i16_saturating_mul", 16, 1, N9_SAT, N9_MUL, (-INT64_C(32768)), INT64_C(32767)},
    {"i32_wrapping_add", 32, 1, N9_WRAP, N9_ADD, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_wrapping_sub", 32, 1, N9_WRAP, N9_SUB, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_wrapping_mul", 32, 1, N9_WRAP, N9_MUL, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_checked_add", 32, 1, N9_CHECK, N9_ADD, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_checked_sub", 32, 1, N9_CHECK, N9_SUB, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_checked_mul", 32, 1, N9_CHECK, N9_MUL, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_saturating_add", 32, 1, N9_SAT, N9_ADD, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_saturating_sub", 32, 1, N9_SAT, N9_SUB, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i32_saturating_mul", 32, 1, N9_SAT, N9_MUL, (-INT64_C(2147483648)), INT64_C(2147483647)},
    {"i64_wrapping_add", 64, 1, N9_WRAP, N9_ADD, INT64_MIN, INT64_MAX},
    {"i64_wrapping_sub", 64, 1, N9_WRAP, N9_SUB, INT64_MIN, INT64_MAX},
    {"i64_wrapping_mul", 64, 1, N9_WRAP, N9_MUL, INT64_MIN, INT64_MAX},
    {"i64_checked_add", 64, 1, N9_CHECK, N9_ADD, INT64_MIN, INT64_MAX},
    {"i64_checked_sub", 64, 1, N9_CHECK, N9_SUB, INT64_MIN, INT64_MAX},
    {"i64_checked_mul", 64, 1, N9_CHECK, N9_MUL, INT64_MIN, INT64_MAX},
    {"i64_saturating_add", 64, 1, N9_SAT, N9_ADD, INT64_MIN, INT64_MAX},
    {"i64_saturating_sub", 64, 1, N9_SAT, N9_SUB, INT64_MIN, INT64_MAX},
    {"i64_saturating_mul", 64, 1, N9_SAT, N9_MUL, INT64_MIN, INT64_MAX},
    {"u8_wrapping_add", 8, 0, N9_WRAP, N9_ADD, INT64_C(0), INT64_C(255)},
    {"u8_wrapping_sub", 8, 0, N9_WRAP, N9_SUB, INT64_C(0), INT64_C(255)},
    {"u8_wrapping_mul", 8, 0, N9_WRAP, N9_MUL, INT64_C(0), INT64_C(255)},
    {"u8_checked_add", 8, 0, N9_CHECK, N9_ADD, INT64_C(0), INT64_C(255)},
    {"u8_checked_sub", 8, 0, N9_CHECK, N9_SUB, INT64_C(0), INT64_C(255)},
    {"u8_checked_mul", 8, 0, N9_CHECK, N9_MUL, INT64_C(0), INT64_C(255)},
    {"u8_saturating_add", 8, 0, N9_SAT, N9_ADD, INT64_C(0), INT64_C(255)},
    {"u8_saturating_sub", 8, 0, N9_SAT, N9_SUB, INT64_C(0), INT64_C(255)},
    {"u8_saturating_mul", 8, 0, N9_SAT, N9_MUL, INT64_C(0), INT64_C(255)},
    {"u16_wrapping_add", 16, 0, N9_WRAP, N9_ADD, INT64_C(0), INT64_C(65535)},
    {"u16_wrapping_sub", 16, 0, N9_WRAP, N9_SUB, INT64_C(0), INT64_C(65535)},
    {"u16_wrapping_mul", 16, 0, N9_WRAP, N9_MUL, INT64_C(0), INT64_C(65535)},
    {"u16_checked_add", 16, 0, N9_CHECK, N9_ADD, INT64_C(0), INT64_C(65535)},
    {"u16_checked_sub", 16, 0, N9_CHECK, N9_SUB, INT64_C(0), INT64_C(65535)},
    {"u16_checked_mul", 16, 0, N9_CHECK, N9_MUL, INT64_C(0), INT64_C(65535)},
    {"u16_saturating_add", 16, 0, N9_SAT, N9_ADD, INT64_C(0), INT64_C(65535)},
    {"u16_saturating_sub", 16, 0, N9_SAT, N9_SUB, INT64_C(0), INT64_C(65535)},
    {"u16_saturating_mul", 16, 0, N9_SAT, N9_MUL, INT64_C(0), INT64_C(65535)},
    {"u32_wrapping_add", 32, 0, N9_WRAP, N9_ADD, INT64_C(0), INT64_C(4294967295)},
    {"u32_wrapping_sub", 32, 0, N9_WRAP, N9_SUB, INT64_C(0), INT64_C(4294967295)},
    {"u32_wrapping_mul", 32, 0, N9_WRAP, N9_MUL, INT64_C(0), INT64_C(4294967295)},
    {"u32_checked_add", 32, 0, N9_CHECK, N9_ADD, INT64_C(0), INT64_C(4294967295)},
    {"u32_checked_sub", 32, 0, N9_CHECK, N9_SUB, INT64_C(0), INT64_C(4294967295)},
    {"u32_checked_mul", 32, 0, N9_CHECK, N9_MUL, INT64_C(0), INT64_C(4294967295)},
    {"u32_saturating_add", 32, 0, N9_SAT, N9_ADD, INT64_C(0), INT64_C(4294967295)},
    {"u32_saturating_sub", 32, 0, N9_SAT, N9_SUB, INT64_C(0), INT64_C(4294967295)},
    {"u32_saturating_mul", 32, 0, N9_SAT, N9_MUL, INT64_C(0), INT64_C(4294967295)},
    {"u64_wrapping_add", 64, 0, N9_WRAP, N9_ADD, INT64_MIN, INT64_MAX},
    {"u64_wrapping_sub", 64, 0, N9_WRAP, N9_SUB, INT64_MIN, INT64_MAX},
    {"u64_wrapping_mul", 64, 0, N9_WRAP, N9_MUL, INT64_MIN, INT64_MAX},
    {"u64_checked_add", 64, 0, N9_CHECK, N9_ADD, INT64_MIN, INT64_MAX},
    {"u64_checked_sub", 64, 0, N9_CHECK, N9_SUB, INT64_MIN, INT64_MAX},
    {"u64_checked_mul", 64, 0, N9_CHECK, N9_MUL, INT64_MIN, INT64_MAX},
    {"u64_saturating_add", 64, 0, N9_SAT, N9_ADD, INT64_MIN, INT64_MAX},
    {"u64_saturating_sub", 64, 0, N9_SAT, N9_SUB, INT64_MIN, INT64_MAX},
    {"u64_saturating_mul", 64, 0, N9_SAT, N9_MUL, INT64_MIN, INT64_MAX},
};

static int n9_pair(Value *arg, int64_t lo, int64_t hi,
                   int64_t *a, int64_t *b, const char *who) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "%s: expected [a, b]", who);
        return 0;
    }
    if (arg->data.list.count > 2) {
        rt_error(EK_TYPE, 0, "%s: expected a fixed-shape list with at most 2 elements", who);
        return 0;
    }
    EigsView av, bv;
    return eigs_int_arg_range(list_get_view(arg, 0, &av), lo, hi, a, who)
        && eigs_int_arg_range(list_get_view(arg, 1, &bv), lo, hi, b, who);
}

/* Decode bits without an out-of-range unsigned-to-signed cast. */
static int64_t n9_i64_bits(uint64_t bits) {
    int64_t value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

static Value *n9_width(Value *arg, const N9Spec *s) {
    int64_t a, b;
    if (!n9_pair(arg, s->lo, s->hi, &a, &b, s->name)) return make_null();
    uint64_t ua = (uint64_t)a, ub = (uint64_t)b;
    uint64_t mask = s->width == 64 ? UINT64_MAX : (UINT64_C(1) << s->width) - 1;
    uint64_t bits = 0;
    switch (s->op) {
        case N9_ADD: bits = ua + ub; break;
        case N9_SUB: bits = ua - ub; break;
        case N9_MUL: bits = ua * ub; break;
    }
    if (s->mode != N9_WRAP) {
        int overflow = 0, high = 0;
        if (s->is_signed) {
            int64_t result = 0;
            switch (s->op) {
                case N9_ADD:
                    overflow = __builtin_add_overflow(a, b, &result);
                    high = b > 0;
                    break;
                case N9_SUB:
                    overflow = __builtin_sub_overflow(a, b, &result);
                    high = b < 0;
                    break;
                case N9_MUL:
                    overflow = __builtin_mul_overflow(a, b, &result);
                    high = (a < 0) == (b < 0);
                    break;
            }
            if (!overflow) {
                overflow = result < s->lo || result > s->hi;
                high = result > s->hi;
            }
        } else {
            switch (s->op) {
                case N9_ADD: overflow = bits < ua || bits > mask; high = 1; break;
                case N9_SUB: overflow = ua < ub; high = 0; break;
                case N9_MUL: overflow = ub != 0 && ua > mask / ub; high = 1; break;
            }
        }
        if (overflow) {
            if (s->mode == N9_CHECK) {
                rt_error(EK_VALUE, 0, "%s: integer overflow", s->name);
                return make_null();
            }
            if (s->is_signed) return make_int(high ? s->hi : s->lo);
            return make_int(high ? n9_i64_bits(mask) : 0);
        }
    }
    bits &= mask;
    if (s->is_signed && s->width < 64 && (bits & (UINT64_C(1) << (s->width - 1))))
        return make_int(-1 - (int64_t)(mask - bits));
    return make_int(n9_i64_bits(bits));
}

/* i8_wrapping_add of [a, b] — i8 wrapping add; N5 operands, int result */
Value* builtin_i8_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[0]);
}

/* i8_wrapping_sub of [a, b] — i8 wrapping sub; N5 operands, int result */
Value* builtin_i8_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[1]);
}

/* i8_wrapping_mul of [a, b] — i8 wrapping mul; N5 operands, int result */
Value* builtin_i8_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[2]);
}

/* i8_checked_add of [a, b] — i8 checked add; N5 operands, int result */
Value* builtin_i8_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[3]);
}

/* i8_checked_sub of [a, b] — i8 checked sub; N5 operands, int result */
Value* builtin_i8_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[4]);
}

/* i8_checked_mul of [a, b] — i8 checked mul; N5 operands, int result */
Value* builtin_i8_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[5]);
}

/* i8_saturating_add of [a, b] — i8 saturating add; N5 operands, int result */
Value* builtin_i8_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[6]);
}

/* i8_saturating_sub of [a, b] — i8 saturating sub; N5 operands, int result */
Value* builtin_i8_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[7]);
}

/* i8_saturating_mul of [a, b] — i8 saturating mul; N5 operands, int result */
Value* builtin_i8_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[8]);
}

/* i16_wrapping_add of [a, b] — i16 wrapping add; N5 operands, int result */
Value* builtin_i16_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[9]);
}

/* i16_wrapping_sub of [a, b] — i16 wrapping sub; N5 operands, int result */
Value* builtin_i16_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[10]);
}

/* i16_wrapping_mul of [a, b] — i16 wrapping mul; N5 operands, int result */
Value* builtin_i16_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[11]);
}

/* i16_checked_add of [a, b] — i16 checked add; N5 operands, int result */
Value* builtin_i16_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[12]);
}

/* i16_checked_sub of [a, b] — i16 checked sub; N5 operands, int result */
Value* builtin_i16_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[13]);
}

/* i16_checked_mul of [a, b] — i16 checked mul; N5 operands, int result */
Value* builtin_i16_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[14]);
}

/* i16_saturating_add of [a, b] — i16 saturating add; N5 operands, int result */
Value* builtin_i16_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[15]);
}

/* i16_saturating_sub of [a, b] — i16 saturating sub; N5 operands, int result */
Value* builtin_i16_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[16]);
}

/* i16_saturating_mul of [a, b] — i16 saturating mul; N5 operands, int result */
Value* builtin_i16_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[17]);
}

/* i32_wrapping_add of [a, b] — i32 wrapping add; N5 operands, int result */
Value* builtin_i32_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[18]);
}

/* i32_wrapping_sub of [a, b] — i32 wrapping sub; N5 operands, int result */
Value* builtin_i32_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[19]);
}

/* i32_wrapping_mul of [a, b] — i32 wrapping mul; N5 operands, int result */
Value* builtin_i32_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[20]);
}

/* i32_checked_add of [a, b] — i32 checked add; N5 operands, int result */
Value* builtin_i32_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[21]);
}

/* i32_checked_sub of [a, b] — i32 checked sub; N5 operands, int result */
Value* builtin_i32_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[22]);
}

/* i32_checked_mul of [a, b] — i32 checked mul; N5 operands, int result */
Value* builtin_i32_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[23]);
}

/* i32_saturating_add of [a, b] — i32 saturating add; N5 operands, int result */
Value* builtin_i32_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[24]);
}

/* i32_saturating_sub of [a, b] — i32 saturating sub; N5 operands, int result */
Value* builtin_i32_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[25]);
}

/* i32_saturating_mul of [a, b] — i32 saturating mul; N5 operands, int result */
Value* builtin_i32_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[26]);
}

/* i64_wrapping_add of [a, b] — i64 wrapping add; N5 operands, int result */
Value* builtin_i64_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[27]);
}

/* i64_wrapping_sub of [a, b] — i64 wrapping sub; N5 operands, int result */
Value* builtin_i64_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[28]);
}

/* i64_wrapping_mul of [a, b] — i64 wrapping mul; N5 operands, int result */
Value* builtin_i64_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[29]);
}

/* i64_checked_add of [a, b] — i64 checked add; N5 operands, int result */
Value* builtin_i64_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[30]);
}

/* i64_checked_sub of [a, b] — i64 checked sub; N5 operands, int result */
Value* builtin_i64_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[31]);
}

/* i64_checked_mul of [a, b] — i64 checked mul; N5 operands, int result */
Value* builtin_i64_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[32]);
}

/* i64_saturating_add of [a, b] — i64 saturating add; N5 operands, int result */
Value* builtin_i64_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[33]);
}

/* i64_saturating_sub of [a, b] — i64 saturating sub; N5 operands, int result */
Value* builtin_i64_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[34]);
}

/* i64_saturating_mul of [a, b] — i64 saturating mul; N5 operands, int result */
Value* builtin_i64_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[35]);
}

/* u8_wrapping_add of [a, b] — u8 wrapping add; N5 operands, int result */
Value* builtin_u8_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[36]);
}

/* u8_wrapping_sub of [a, b] — u8 wrapping sub; N5 operands, int result */
Value* builtin_u8_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[37]);
}

/* u8_wrapping_mul of [a, b] — u8 wrapping mul; N5 operands, int result */
Value* builtin_u8_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[38]);
}

/* u8_checked_add of [a, b] — u8 checked add; N5 operands, int result */
Value* builtin_u8_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[39]);
}

/* u8_checked_sub of [a, b] — u8 checked sub; N5 operands, int result */
Value* builtin_u8_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[40]);
}

/* u8_checked_mul of [a, b] — u8 checked mul; N5 operands, int result */
Value* builtin_u8_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[41]);
}

/* u8_saturating_add of [a, b] — u8 saturating add; N5 operands, int result */
Value* builtin_u8_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[42]);
}

/* u8_saturating_sub of [a, b] — u8 saturating sub; N5 operands, int result */
Value* builtin_u8_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[43]);
}

/* u8_saturating_mul of [a, b] — u8 saturating mul; N5 operands, int result */
Value* builtin_u8_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[44]);
}

/* u16_wrapping_add of [a, b] — u16 wrapping add; N5 operands, int result */
Value* builtin_u16_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[45]);
}

/* u16_wrapping_sub of [a, b] — u16 wrapping sub; N5 operands, int result */
Value* builtin_u16_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[46]);
}

/* u16_wrapping_mul of [a, b] — u16 wrapping mul; N5 operands, int result */
Value* builtin_u16_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[47]);
}

/* u16_checked_add of [a, b] — u16 checked add; N5 operands, int result */
Value* builtin_u16_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[48]);
}

/* u16_checked_sub of [a, b] — u16 checked sub; N5 operands, int result */
Value* builtin_u16_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[49]);
}

/* u16_checked_mul of [a, b] — u16 checked mul; N5 operands, int result */
Value* builtin_u16_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[50]);
}

/* u16_saturating_add of [a, b] — u16 saturating add; N5 operands, int result */
Value* builtin_u16_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[51]);
}

/* u16_saturating_sub of [a, b] — u16 saturating sub; N5 operands, int result */
Value* builtin_u16_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[52]);
}

/* u16_saturating_mul of [a, b] — u16 saturating mul; N5 operands, int result */
Value* builtin_u16_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[53]);
}

/* u32_wrapping_add of [a, b] — u32 wrapping add; N5 operands, int result */
Value* builtin_u32_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[54]);
}

/* u32_wrapping_sub of [a, b] — u32 wrapping sub; N5 operands, int result */
Value* builtin_u32_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[55]);
}

/* u32_wrapping_mul of [a, b] — u32 wrapping mul; N5 operands, int result */
Value* builtin_u32_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[56]);
}

/* u32_checked_add of [a, b] — u32 checked add; N5 operands, int result */
Value* builtin_u32_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[57]);
}

/* u32_checked_sub of [a, b] — u32 checked sub; N5 operands, int result */
Value* builtin_u32_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[58]);
}

/* u32_checked_mul of [a, b] — u32 checked mul; N5 operands, int result */
Value* builtin_u32_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[59]);
}

/* u32_saturating_add of [a, b] — u32 saturating add; N5 operands, int result */
Value* builtin_u32_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[60]);
}

/* u32_saturating_sub of [a, b] — u32 saturating sub; N5 operands, int result */
Value* builtin_u32_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[61]);
}

/* u32_saturating_mul of [a, b] — u32 saturating mul; N5 operands, int result */
Value* builtin_u32_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[62]);
}

/* u64_wrapping_add of [a, b] — u64 wrapping add; N5 operands, int result */
Value* builtin_u64_wrapping_add(Value *arg) {
    return n9_width(arg, &n9_specs[63]);
}

/* u64_wrapping_sub of [a, b] — u64 wrapping sub; N5 operands, int result */
Value* builtin_u64_wrapping_sub(Value *arg) {
    return n9_width(arg, &n9_specs[64]);
}

/* u64_wrapping_mul of [a, b] — u64 wrapping mul; N5 operands, int result */
Value* builtin_u64_wrapping_mul(Value *arg) {
    return n9_width(arg, &n9_specs[65]);
}

/* u64_checked_add of [a, b] — u64 checked add; N5 operands, int result */
Value* builtin_u64_checked_add(Value *arg) {
    return n9_width(arg, &n9_specs[66]);
}

/* u64_checked_sub of [a, b] — u64 checked sub; N5 operands, int result */
Value* builtin_u64_checked_sub(Value *arg) {
    return n9_width(arg, &n9_specs[67]);
}

/* u64_checked_mul of [a, b] — u64 checked mul; N5 operands, int result */
Value* builtin_u64_checked_mul(Value *arg) {
    return n9_width(arg, &n9_specs[68]);
}

/* u64_saturating_add of [a, b] — u64 saturating add; N5 operands, int result */
Value* builtin_u64_saturating_add(Value *arg) {
    return n9_width(arg, &n9_specs[69]);
}

/* u64_saturating_sub of [a, b] — u64 saturating sub; N5 operands, int result */
Value* builtin_u64_saturating_sub(Value *arg) {
    return n9_width(arg, &n9_specs[70]);
}

/* u64_saturating_mul of [a, b] — u64 saturating mul; N5 operands, int result */
Value* builtin_u64_saturating_mul(Value *arg) {
    return n9_width(arg, &n9_specs[71]);
}

/* u64_compare of [a, b] — unsigned ordering of int64 bit patterns */
Value* builtin_u64_compare(Value *arg) {
    int64_t a, b;
    if (!n9_pair(arg, INT64_MIN, INT64_MAX, &a, &b, "u64_compare")) return make_null();
    return make_int(((uint64_t)a > (uint64_t)b) - ((uint64_t)a < (uint64_t)b));
}
static Value *n9_unsigned_div(Value *arg, int remainder, const char *who) {
    int64_t a, b;
    if (!n9_pair(arg, INT64_MIN, INT64_MAX, &a, &b, who)) return make_null();
    if (b == 0) {
        rt_error(EK_VALUE, 0, "division by zero");
        return make_null();
    }
    uint64_t value = remainder ? (uint64_t)a % (uint64_t)b : (uint64_t)a / (uint64_t)b;
    return make_int(n9_i64_bits(value));
}
/* u64_div of [a, b] — unsigned division; zero raises value */
Value* builtin_u64_div(Value *arg) {
    return n9_unsigned_div(arg, 0, "u64_div");
}
/* u64_rem of [a, b] — unsigned remainder; zero raises value */
Value* builtin_u64_rem(Value *arg) {
    return n9_unsigned_div(arg, 1, "u64_rem");
}
/* u64_to_string of x — unsigned decimal text from an int64 bit pattern */
Value* builtin_u64_to_string(Value *arg) {
    EigsView view;
    if (arg && arg->type == VAL_LIST && arg->data.list.count == 1)
        arg = list_get_view(arg, 0, &view);
    int64_t value = eigs_int_arg(arg, "u64_to_string");
    if (g_has_error) return make_null();
    char text[21];
    snprintf(text, sizeof(text), "%llu", (unsigned long long)(uint64_t)value);
    return make_str(text);
}
/* fround of x — binary64 to binary32 to binary64, returning float kind */
Value* builtin_fround(Value *arg) {
    EigsView view;
    if (arg && arg->type == VAL_LIST && arg->data.list.count == 1)
        arg = list_get_view(arg, 0, &view);
    double value = eigs_float_arg(arg, "fround");
    if (g_has_error) return make_null();
    /* Preserve int -> f64 -> f32 -> f64 double rounding. make_float keeps
     * today's overflow guard and math flag until the IEEE round R2.2. */
    return make_float((double)(float)value);
}
