/*
 * Numeric buffer + DSP builtins (#744).
 *
 * `buffer`/`reshape`/`buf_get`/`buf_set`, the byte<->f64 codecs, the
 * vectorized buf_* window kernels (#597), the bulk PCM16LE codecs (#602),
 * buf_resample_linear (#603) and the DEFLATE codecs (#684). Split out of
 * builtins.c, which held at least ten unrelated groups; this one is
 * self-contained — the split was measured first and NO static symbol crosses
 * the seam in either direction.
 *
 * These are ordinary builtins: registered by register_builtins (builtins.c)
 * through the prototypes in builtins_internal.h, no registrar of their own,
 * so the env-composition seam stays single (#742).
 *
 * Freestanding-safe: pure arithmetic over flat double arrays, no OS. The
 * DEFLATE block is the one variant surface — behind EIGENSCRIPT_EXT_ZLIB,
 * and with it off the four names stay registered and raise, so a script can
 * feature-detect with try/catch.
 */

#include "eigenscript.h"
#include "vm.h"
#include "builtins_internal.h"

#if EIGENSCRIPT_EXT_ZLIB
#include <zlib.h>
#endif

/* ---- Typed numeric buffers (flat double arrays) ---- */

/* buffer of count — create a zero-filled numeric buffer */
Value* builtin_buffer(Value *arg) {
    /* buffer of [rows, cols] -> shaped 2-D buffer (flat double[rows*cols]) */
    if (arg && arg->type == VAL_LIST && arg->data.list.count == 2 &&
        list_get_borrow(arg, 0)->type == VAL_NUM &&
        list_get_borrow(arg, 1)->type == VAL_NUM) {
        int r = (int)eigs_list_num(arg, 0, __func__);
        int c = (int)eigs_list_num(arg, 1, __func__);
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
    /* #971 Phase D: a non-number size (or a malformed [rows, cols]) made an
     * EMPTY buffer — a plausible object with nothing in it. */
    STRICT_REQUIRE(!arg || arg->type != VAL_NUM, "buffer", "a size or [rows, cols]");
    if (arg && arg->type == VAL_NUM) count = (int)eigs_num_arg(arg, __func__);
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
    STRICT_LIST_MAX(arg, 3, "reshape");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) return make_null();
    Value *b = list_get_borrow(arg, 0);
    if (b->type != VAL_BUFFER) return make_null();
    BOOL_REFUSE(arg, "reshape");   /* rows/cols; the buffer is not a bool */
    if (list_get_borrow(arg, 1)->type != VAL_NUM ||
        list_get_borrow(arg, 2)->type != VAL_NUM) return make_null();
    int r = (int)eigs_list_num(arg, 1, __func__);
    int c = (int)eigs_list_num(arg, 2, __func__);
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
    STRICT_LIST_MAX(arg, 2, "buf_get");
    /* #502: out-of-range used to fold to 0 — indistinguishable from a real
     * stored 0. Raise index_range, matching the buffer `[i]` operator. */
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "buf_get requires [buffer, index]");
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    Value *buf = list_get_borrow(arg, 0);
    if (!buf || buf->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_get: first argument must be a buffer");
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    int idx = (int)eigs_list_num(arg, 1, __func__);
    if (g_has_error) return make_num(0);   /* fs:CHANNEL #1637: a non-number index raised */
    if (idx < 0 || idx >= buf->data.buffer.count) {
        rt_error(EK_INDEX, 0, "buffer index %d out of range (length %d)",
                 idx, buf->data.buffer.count);
        /* fs:CHANNEL the EK_INDEX rt_error above already raised (#502) */
        return make_num(0);
    }
    return make_num(buffer_read_num(buf, idx));
}

/* buf_set of [buf, index, value] — O(1) indexed write */
Value* builtin_buf_set(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "buf_set");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {  /* #502 */
        rt_error(EK_TYPE, 0, "buf_set requires [buffer, index, value]");
        return make_null();
    }
    Value *buf = list_get_borrow(arg, 0);
    if (!buf || buf->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_set: first argument must be a buffer");
        return make_null();
    }
    /* #1061: both operands were read through the num union member unchecked
     * -- a string index or value read garbage bits (the #1007 type-pun class).
     * Loud, like the `b[i] is v` opcode path. */
    if (list_get_borrow(arg, 1)->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "buf_set: index must be a number, got %s", val_type_name(list_get_borrow(arg, 1)->type));
        return make_null();
    }
    if (list_get_borrow(arg, 2)->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "cannot store %s in a buffer (buffers hold numbers)", val_type_name(list_get_borrow(arg, 2)->type));
        return make_null();
    }
    int idx = (int)eigs_list_num(arg, 1, __func__);
    double val = eigs_list_num(arg, 2, __func__);
    if (g_has_error) return make_null();   /* #1637: a non-number index raised; nothing written */
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
        if (list_get_borrow(arg, i)->type == VAL_NUM) {
            v->data.buffer.data[i] = eigs_num_arg(list_get_borrow(arg, i), __func__);
        } else {
            /* #1061: a non-number element silently stayed 0.0. */
            const char *tn = val_type_name(list_get_borrow(arg, i)->type);
            val_decref(v);
            rt_error(EK_TYPE, 0, "buf_from_list: element %d is %s (buffers hold numbers)", i, tn);
            return make_null();
        }
    }
    return v;
}

/* Strict list-byte validation shared by text and codec conversion. Text
 * conversion stops at its first numeric NUL, so later elements are not part
 * of that conversion; codec conversion consumes the complete list. */
static int strict_numeric_byte_list(Value *arg, const char *who, int nul_ends) {
    if (!arg || arg->type != VAL_LIST) return 1;
    for (int i = 0; i < arg->data.list.count; i++) {
        Value *item = list_get_borrow(arg, i);
        /* #1637: a bool byte is refused in every strict mode. */
        if (!item || (item->type != VAL_NUM && (g_strict || item->type == VAL_BOOL))) {
            rt_error(EK_TYPE, 0, "%s: expected numeric byte values", who);
            return 0;
        }
        /* EIGS_STRICT=0 legacy: a non-number element (a bool never reaches
         * here) ends the string as a NUL would -- the documented truncation
         * the compatibility mode keeps. It is never read as a number. */
        if (nul_ends && (item->type != VAL_NUM
                         || finite_num_to_byte(eigs_num_arg(item, __func__)) == 0)) break;
    }
    return 1;
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
    if (arg && arg->type == VAL_LIST) {
        n = arg->data.list.count;
        items = list_values_storage(arg);
    } else if (arg && arg->type == VAL_BUFFER) {
        n = arg->data.buffer.count;
    } else {
        ARG_GUARD(1, "str_from_bytes", "a list or buffer of byte values", make_str(""));
    }
    if (!strict_numeric_byte_list(arg, "str_from_bytes", 1)) return make_null();
    char *s = xcalloc((size_t)(n > 0 ? n : 0) + 1, 1);
    int len = 0;
    for (int i = 0; i < n; i++) {
        double dv = items ? (items[i] && items[i]->type == VAL_NUM ? eigs_num_arg(items[i], __func__) : 0.0)
                          : buffer_read_num(arg, i);
        if (g_has_error) { free(s); return make_null(); }
        int b = finite_num_to_byte(dv);
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
    /* #971 Phase D: a non-number encoded as 0.0's eight bytes. */
    STRICT_REQUIRE(!arg || arg->type != VAL_NUM, "f64_to_bytes", "a number");
    double d = (arg && arg->type == VAL_NUM) ? eigs_num_arg(arg, __func__) : 0.0;
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
            if (list_get_borrow(arg, i) && list_get_borrow(arg, i)->type == VAL_NUM)
                bytes_in[i] = eigs_num_arg(list_get_borrow(arg, i), __func__);
    } else if (arg && arg->type == VAL_BUFFER) {
        int n = arg->data.buffer.count;
        for (int i = 0; i < 8 && i < n; i++) {
            bytes_in[i] = buffer_read_num(arg, i);
            if (g_has_error) return make_null();
        }
    } else {
        ARG_GUARD(1, "f64_from_bytes", "a list or buffer of 8 byte values", make_num(0));
    }
    uint64_t bits = 0;
    for (int i = 0; i < 8; i++)
        bits = (bits << 8) | (uint64_t)finite_num_to_byte(bytes_in[i]);
    double d;
    memcpy(&d, &bits, sizeof(d));
    /* #971: eight arbitrary bytes can spell a NaN; collapse (default) or
     * raise (strict) under this builtin's own name. */
    return make_num(num_guard_named(d, "f64_from_bytes"));
}

/* ---- DEFLATE codec implementation (#684) ----
 * Thin wrappers over the system zlib (-lz), gated behind
 * EIGENSCRIPT_EXT_ZLIB — the same EIGENSCRIPT_EXT_* mechanism the http
 * variant uses. Default OFF so the minimal build stays zero-dependency;
 * compiled without zlib the four names stay registered but raise a
 * catchable runtime error, so a script can feature-detect with
 * try/catch instead of dying on "undefined variable".
 *
 * Byte representation mirrors read_bytes/write_bytes exactly: input is
 * a list of ints 0-255 (values taken mod 256) or a VAL_BUFFER; output is
 * always a fresh list of ints 0-255. Strict mode rejects nonnumeric list
 * elements; compatibility mode retains their numeric-zero conversion.
 *
 * The raw codec uses windowBits -15 — the ZIP member format, so
 * .xlsx/.ods entries are readable. The wrapped implementation uses windowBits
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
    if (arg && arg->type == VAL_LIST) {
        n = arg->data.list.count;
        items = list_values_storage(arg);
    } else if (arg && arg->type == VAL_BUFFER) {
        n = arg->data.buffer.count;
    } else {
        rt_error(EK_TYPE, 0,
                 "%s requires a list of byte values (0-255) or a buffer, got %s",
                 who, val_type_name(arg ? arg->type : VAL_NULL));
        return 0;
    }
    if (!strict_numeric_byte_list(arg, who, 0)) return 0;
    unsigned char *b = xmalloc((size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) {
        double dv = items ? (items[i] && items[i]->type == VAL_NUM ? eigs_num_arg(items[i], __func__) : 0.0)
                          : buffer_read_num(arg, i);
        if (g_has_error) { free(b); return 0; }
        b[i] = finite_num_to_byte(dv);
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

/* Shared compression core (dual of the decompression implementation). The output buffer is
 * deflateBound-sized up front, so a single Z_FINISH pass always fits. */
Value* builtin_inflate(Value *arg)      { return zlib_inflate_impl("inflate", -15, arg); }
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
    long long c = (long long)eigs_num_arg(cnt_val, __func__);
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
    *out = eigs_num_arg(v, __func__);
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
    long long off = (long long)eigs_num_arg(off_val, __func__);
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
    STRICT_LIST_MAX(arg, 5, "buf_copy");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 5) {
        rt_error(EK_TYPE, 0, "buf_copy requires [src, src_off, dst, dst_off, count]");
        return make_null();
    }
    Value *src = list_get_borrow(arg, 0);
    Value *dst = list_get_borrow(arg, 2);
    long long count, src_off, dst_off;
    if (!buf_count_arg("buf_copy", list_get_borrow(arg, 4), &count) ||
        !buf_window_arg("buf_copy", src, list_get_borrow(arg, 1), count, &src_off) ||
        !buf_window_arg("buf_copy", dst, list_get_borrow(arg, 3), count, &dst_off))
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
    STRICT_LIST_MAX(arg, 6, "buf_mix");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 6) {
        rt_error(EK_TYPE, 0, "buf_mix requires [dst, src, dst_off, src_off, count, gain]");
        return make_null();
    }
    Value *dst = list_get_borrow(arg, 0);
    Value *src = list_get_borrow(arg, 1);
    long long count, dst_off, src_off;
    double gain;
    if (!buf_count_arg("buf_mix", list_get_borrow(arg, 4), &count) ||
        !buf_window_arg("buf_mix", dst, list_get_borrow(arg, 2), count, &dst_off) ||
        !buf_window_arg("buf_mix", src, list_get_borrow(arg, 3), count, &src_off) ||
        !buf_num_arg("buf_mix", "gain", list_get_borrow(arg, 5), &gain))
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
    STRICT_LIST_MAX(arg, 4, "buf_scale_range");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) {
        rt_error(EK_TYPE, 0, "buf_scale_range requires [buffer, off, count, gain]");
        return make_null();
    }
    Value *buf = list_get_borrow(arg, 0);
    long long count, off;
    double gain;
    if (!buf_count_arg("buf_scale_range", list_get_borrow(arg, 2), &count) ||
        !buf_window_arg("buf_scale_range", buf, list_get_borrow(arg, 1), count, &off) ||
        !buf_num_arg("buf_scale_range", "gain", list_get_borrow(arg, 3), &gain))
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
    STRICT_LIST_MAX(arg, 4, "buf_fill");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4) {
        rt_error(EK_TYPE, 0, "buf_fill requires [buffer, off, count, value]");
        return make_null();
    }
    Value *buf = list_get_borrow(arg, 0);
    long long count, off;
    double val;
    if (!buf_count_arg("buf_fill", list_get_borrow(arg, 2), &count) ||
        !buf_window_arg("buf_fill", buf, list_get_borrow(arg, 1), count, &off) ||
        !buf_num_arg("buf_fill", "value", list_get_borrow(arg, 3), &val))
        return make_null();
    double *d = &buf->data.buffer.data[off];
    for (long long i = 0; i < count; i++)
        d[i] = val;
    return make_null();
}

/* buf_peak of [b, off, count] — max |x| over a window (normalize and
 * meter scans). An empty window peaks at 0. */
Value* builtin_buf_peak(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "buf_peak");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_peak requires [buffer, off, count]");
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    Value *buf = list_get_borrow(arg, 0);
    long long count, off;
    if (!buf_count_arg("buf_peak", list_get_borrow(arg, 2), &count) ||
        !buf_window_arg("buf_peak", buf, list_get_borrow(arg, 1), count, &off))
        /* fs:CHANNEL buf_count_arg/buf_window_arg raise before returning 0 */
        return make_num(0);
    double m = 0.0;
    for (long long i = 0; i < count; i++) {
        double x = buffer_read_num(buf, off + i);
        if (g_has_error) return make_null();
        double a = x < 0 ? -x : x;
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
    STRICT_LIST_MAX(arg, 5, "buf_dot");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 5) {
        rt_error(EK_TYPE, 0, "buf_dot requires [a, b, a_off, b_off, count]");
        /* fs:CHANNEL the rt_error above already raised */
        return make_num(0);
    }
    Value *a = list_get_borrow(arg, 0);
    Value *b = list_get_borrow(arg, 1);
    long long count, a_off, b_off;
    if (!buf_count_arg("buf_dot", list_get_borrow(arg, 4), &count) ||
        !buf_window_arg("buf_dot", a, list_get_borrow(arg, 2), count, &a_off) ||
        !buf_window_arg("buf_dot", b, list_get_borrow(arg, 3), count, &b_off))
        /* fs:CHANNEL buf_count_arg/buf_window_arg raise before returning 0 */
        return make_num(0);
    double s = 0.0;
    for (long long i = 0; i < count; i++) {
        double av = buffer_read_num(a, a_off + i);
        if (g_has_error) return make_null();
        double bv = buffer_read_num(b, b_off + i);
        if (g_has_error) return make_null();
        s = num_guard(s + num_guard(av * bv));
    }
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
    STRICT_LIST_MAX(arg, 3, "buf_from_pcm16le");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_from_pcm16le requires [bytes, byte_off, count]");
        return make_null();
    }
    Value *src = list_get_borrow(arg, 0);
    long long count, off;
    if (!buf_count_arg("buf_from_pcm16le", list_get_borrow(arg, 2), &count))
        return make_null();
    if (count > (long long)INT_MAX / 2) { /* 2*count below cannot overflow */
        rt_error(EK_LIMIT, 0, "buf_from_pcm16le: count %lld over the buffer size limit", count);
        return make_null();
    }
    if (!buf_window_arg("buf_from_pcm16le", src, list_get_borrow(arg, 1),
                        count * 2, &off))
        return make_null();
    Value *out = buf_alloc_flat(count);
    if (!out) return make_null();
    double *od = out->data.buffer.data;
    for (long long i = 0; i < count; i++) {
        double lo = buffer_read_num(src, off + 2*i);
        if (g_has_error) { val_decref(out); return make_null(); }
        double hi = buffer_read_num(src, off + 2*i + 1);
        if (g_has_error) { val_decref(out); return make_null(); }
        double v = num_guard(lo + num_guard(256.0 * hi));
        if (g_has_error) { val_decref(out); return make_null(); }
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
    STRICT_LIST_MAX(arg, 3, "buf_to_pcm16le");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_to_pcm16le requires [floats, off, count]");
        return make_null();
    }
    Value *src = list_get_borrow(arg, 0);
    long long count, off;
    if (!buf_count_arg("buf_to_pcm16le", list_get_borrow(arg, 2), &count))
        return make_null();
    if (count > (long long)INT_MAX / 2) { /* output is 2*count elements */
        rt_error(EK_LIMIT, 0, "buf_to_pcm16le: count %lld over the buffer size limit", count);
        return make_null();
    }
    if (!buf_window_arg("buf_to_pcm16le", src, list_get_borrow(arg, 1),
                        count, &off))
        return make_null();
    Value *out = buf_alloc_flat(count * 2);
    if (!out) return make_null();
    double *od = out->data.buffer.data;
    for (long long i = 0; i < count; i++) {
        double x = buffer_read_num(src, off + i);
        if (g_has_error) { val_decref(out); return make_null(); }
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
    STRICT_LIST_MAX(arg, 4, "buf_deinterleave");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "buf_deinterleave requires [src, channel, nch, count?]");
        return make_null();
    }
    Value *src = list_get_borrow(arg, 0);
    if (!src || src->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_deinterleave: expected a buffer");
        return make_null();
    }
    Value *ch_v = list_get_borrow(arg, 1);
    Value *nch_v = list_get_borrow(arg, 2);
    if (!ch_v || ch_v->type != VAL_NUM || !nch_v || nch_v->type != VAL_NUM) {
        rt_error(EK_VALUE, 0, "buf_deinterleave: channel and nch must be numbers");
        return make_null();
    }
    long long nch = (long long)eigs_num_arg(nch_v, __func__);
    long long channel = (long long)eigs_num_arg(ch_v, __func__);
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
    if (arg->data.list.count >= 4 && list_get_borrow(arg, 3) &&
        list_get_borrow(arg, 3)->type != VAL_NULL) {
        if (!buf_count_arg("buf_deinterleave", list_get_borrow(arg, 3), &count))
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
    STRICT_LIST_MAX(arg, 2, "buf_resample_linear");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "buf_resample_linear requires [src, dst_len]");
        return make_null();
    }
    Value *src = list_get_borrow(arg, 0);
    if (!src || src->type != VAL_BUFFER) {
        rt_error(EK_TYPE, 0, "buf_resample_linear: expected a buffer");
        return make_null();
    }
    long long dst_len;
    if (!buf_count_arg("buf_resample_linear", list_get_borrow(arg, 1), &dst_len))
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
