/* mini_fmt.c — vsnprintf/snprintf for the freestanding profile.
 *
 * Float conversions ride an EXACT big-decimal digit engine: the double's
 * mantissa is loaded as a decimal digit string and doubled/halved |e|
 * times longhand, so every produced digit is exact and rounding at the
 * precision cut is true round-half-even — the same result glibc's
 * correctly-rounded printf produces. Slow (worst case ~1M digit ops for
 * subnormals) and completely portable; printing is never a hot path.
 *
 * Coverage (everything the runtime uses, per the format census):
 *   %d %i %u %x %X %o %c %s %e %E %f %F %g %G %%
 *   flags - + space 0 #, width (incl *), precision (incl .*),
 *   length h hh l ll z. No %p, no %n (the runtime uses neither).
 */
#include "mini_libc.h"
#include <stdint.h>

/* ---------- exact big-decimal ---------- */

#define BD_INT_MAX  340     /* 2^971*2^53 has 309 integer digits */
#define BD_FRAC_MAX 1140    /* 2^-1074 has ~1074+16 fraction digits */

typedef struct {
    unsigned char di[BD_INT_MAX];    /* integer digits, MSD first */
    unsigned char df[BD_FRAC_MAX];   /* fraction digits */
    int ni, nf;
    int neg;
    int special;                     /* 0 finite, 1 inf, 2 nan */
} BigDec;

static void bd_halve(BigDec *b) {
    int rem = 0;
    for (int i = 0; i < b->ni; i++) {
        int cur = rem * 10 + b->di[i];
        b->di[i] = (unsigned char)(cur >> 1);
        rem = cur & 1;
    }
    for (int i = 0; i < b->nf; i++) {
        int cur = rem * 10 + b->df[i];
        b->df[i] = (unsigned char)(cur >> 1);
        rem = cur & 1;
    }
    if (rem && b->nf < BD_FRAC_MAX) b->df[b->nf++] = 5;
    while (b->ni > 0 && b->di[0] == 0) {               /* trim leading zeros */
        for (int i = 1; i < b->ni; i++) b->di[i - 1] = b->di[i];
        b->ni--;
    }
}

static void bd_double(BigDec *b) {
    int carry = 0;
    for (int i = b->nf - 1; i >= 0; i--) {
        int cur = b->df[i] * 2 + carry;
        b->df[i] = (unsigned char)(cur % 10);
        carry = cur / 10;
    }
    for (int i = b->ni - 1; i >= 0; i--) {
        int cur = b->di[i] * 2 + carry;
        b->di[i] = (unsigned char)(cur % 10);
        carry = cur / 10;
    }
    if (carry) {
        for (int i = b->ni; i > 0; i--) b->di[i] = b->di[i - 1];
        b->di[0] = (unsigned char)carry;
        b->ni++;
    }
    while (b->nf > 0 && b->df[b->nf - 1] == 0) b->nf--; /* trim trailing zeros */
}

static void bd_from_double(BigDec *b, double x) {
    union { double d; uint64_t u; } v;
    v.d = x;
    b->neg = (int)(v.u >> 63);
    b->special = 0;
    b->ni = b->nf = 0;
    uint64_t exp = (v.u >> 52) & 0x7FF;
    uint64_t man = v.u & 0x000FFFFFFFFFFFFFULL;
    if (exp == 0x7FF) { b->special = man ? 2 : 1; return; }
    int e;
    if (exp == 0) { e = -1074; }                        /* subnormal */
    else { man |= 1ULL << 52; e = (int)exp - 1075; }
    /* load mantissa as decimal */
    unsigned char tmp[20];
    int n = 0;
    if (man == 0) return;                               /* zero */
    while (man) { tmp[n++] = (unsigned char)(man % 10); man /= 10; }
    b->ni = n;
    for (int i = 0; i < n; i++) b->di[i] = tmp[n - 1 - i];
    while (e > 0) { bd_double(b); e--; }
    while (e < 0) { bd_halve(b); e++; }
}

/* digit at significant position k (0 = first significant digit); the
 * caller supplies E = decimal exponent (digit 0 has weight 10^E). */
static int bd_exponent(const BigDec *b, int *is_zero) {
    if (b->ni > 0) { *is_zero = 0; return b->ni - 1; }
    for (int i = 0; i < b->nf; i++) {
        if (b->df[i]) { *is_zero = 0; return -(i + 1); }
    }
    *is_zero = 1;
    return 0;
}

/* digit with weight 10^w */
static int bd_digit_at(const BigDec *b, int w) {
    if (w >= 0) {
        int idx = b->ni - 1 - w;
        return (idx >= 0 && idx < b->ni) ? b->di[idx] : 0;
    }
    int idx = -w - 1;
    return (idx < b->nf) ? b->df[idx] : 0;
}

/* any nonzero digit strictly below weight w? */
static int bd_sticky_below(const BigDec *b, int w) {
    int lo_int = (w > 0) ? w - 1 : -1;
    for (int i = lo_int; i >= 0; i--)
        if (bd_digit_at(b, i)) return 1;
    int start = (w < 0) ? -w : 1;                      /* first frac index below w */
    for (int i = start - 1; i < b->nf; i++) {
        if (-(i + 1) < w && b->df[i]) return 1;
    }
    return 0;
}

/* Extract digits from weight hi down to weight lo into out (MSD first),
 * rounding half-even at lo using the digit below lo + sticky. Returns 1
 * if rounding carried past hi (out becomes "1000...", caller bumps hi). */
static int bd_digits_rounded(const BigDec *b, int hi, int lo, char *out) {
    int n = hi - lo + 1;
    for (int i = 0; i < n; i++)
        out[i] = (char)('0' + bd_digit_at(b, hi - i));
    int next = bd_digit_at(b, lo - 1);
    int sticky = bd_sticky_below(b, lo - 1);
    int up = 0;
    if (next > 5) up = 1;
    else if (next == 5) {
        if (sticky) up = 1;
        else up = ((out[n - 1] - '0') & 1);            /* half-even */
    }
    if (up) {
        int i = n - 1;
        while (i >= 0) {
            if (out[i] == '9') { out[i] = '0'; i--; }
            else { out[i]++; break; }
        }
        if (i < 0) {                                    /* carried out: 999->1000 */
            for (int j = n; j > 0; j--) out[j] = out[j - 1];
            out[0] = '1';
            return 1;
        }
    }
    return 0;
}

/* ---------- output sink ---------- */

typedef struct {
    char *buf;
    size_t cap;                                        /* bytes usable incl NUL */
    size_t len;                                        /* would-be length */
} Sink;

static void sink_ch(Sink *s, char c) {
    if (s->len + 1 < s->cap) s->buf[s->len] = c;
    s->len++;
}
static void sink_n(Sink *s, const char *p, size_t n) {
    for (size_t i = 0; i < n; i++) sink_ch(s, p[i]);
}
static void sink_pad(Sink *s, char c, int n) {
    for (int i = 0; i < n; i++) sink_ch(s, c);
}

/* ---------- conversion spec ---------- */

typedef struct {
    int minus, plus, space, zero, hash;
    int width;                                         /* -1 none */
    int prec;                                          /* -1 none */
    char len[3];                                       /* "", "l", "ll", "z", "h", "hh" */
} Spec;

static void emit_padded(Sink *s, const Spec *sp, const char *sign,
                        const char *prefix, const char *digits, int ndig,
                        int min_digits) {
    int zeros = (min_digits > ndig) ? min_digits - ndig : 0;
    int body = (int)eigs_strlen(sign) + (int)eigs_strlen(prefix) + zeros + ndig;
    int pad = (sp->width > body) ? sp->width - body : 0;
    if (!sp->minus && sp->zero && sp->prec < 0) {
        sink_n(s, sign, eigs_strlen(sign));
        sink_n(s, prefix, eigs_strlen(prefix));
        sink_pad(s, '0', pad);
        sink_pad(s, '0', zeros);
        sink_n(s, digits, (size_t)ndig);
        return;
    }
    if (!sp->minus) sink_pad(s, ' ', pad);
    sink_n(s, sign, eigs_strlen(sign));
    sink_n(s, prefix, eigs_strlen(prefix));
    sink_pad(s, '0', zeros);
    sink_n(s, digits, (size_t)ndig);
    if (sp->minus) sink_pad(s, ' ', pad);
}

static void fmt_uint(Sink *s, const Spec *sp, unsigned long long v, int base,
                     int upper, int neg) {
    char tmp[24];
    const char *hexd = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    int n = 0;
    if (v == 0) tmp[n++] = '0';
    while (v) { tmp[n++] = hexd[v % (unsigned)base]; v /= (unsigned)base; }
    char digits[24];
    for (int i = 0; i < n; i++) digits[i] = tmp[n - 1 - i];
    const char *sign = neg ? "-" : (sp->plus ? "+" : (sp->space ? " " : ""));
    const char *prefix = "";
    if (sp->hash && base == 16 && n && !(n == 1 && digits[0] == '0'))
        prefix = upper ? "0X" : "0x";
    if (sp->hash && base == 8 && digits[0] != '0') prefix = "0";
    int min_digits = (sp->prec >= 0) ? sp->prec : 1;
    if (sp->prec == 0 && n == 1 && digits[0] == '0') n = 0;
    emit_padded(s, sp, sign, prefix, digits, n, min_digits);
}

/* ---------- float conversions ---------- */

static void emit_special(Sink *s, const Spec *sp, const BigDec *b, int upper) {
    const char *body = (b->special == 2) ? (upper ? "NAN" : "nan")
                                         : (upper ? "INF" : "inf");
    const char *sign = b->neg ? "-" : sp->plus ? "+" : sp->space ? " " : "";
    int bodyn = (int)eigs_strlen(sign) + 3;
    int pad = (sp->width > bodyn) ? sp->width - bodyn : 0;
    if (!sp->minus) sink_pad(s, ' ', pad);              /* 0-flag ignored */
    sink_n(s, sign, eigs_strlen(sign));
    sink_n(s, body, 3);
    if (sp->minus) sink_pad(s, ' ', pad);
}

static void fmt_f(Sink *s, const Spec *sp, const BigDec *b) {
    int P = (sp->prec >= 0) ? sp->prec : 6;
    int is_zero;
    int E = bd_exponent(b, &is_zero);
    char body[BD_INT_MAX + 1140 + 8];
    int n = 0;
    int hi = (E > 0 && !is_zero) ? E : 0;
    char digs[BD_INT_MAX + 1140 + 8];
    int carried = is_zero ? 0 : bd_digits_rounded(b, hi, -P, digs);
    if (is_zero) {
        for (int i = 0; i <= hi + P; i++) digs[i] = '0';
    }
    int total = hi + P + 1 + carried;                  /* digits available */
    int int_digits = total - P;
    for (int i = 0; i < int_digits; i++) body[n++] = digs[i];
    if (P > 0 || sp->hash) body[n++] = '.';
    for (int i = 0; i < P; i++) body[n++] = digs[int_digits + i];
    const char *sign = b->neg ? "-" : (sp->plus ? "+" : (sp->space ? " " : ""));
    Spec sp2 = *sp; sp2.prec = -1;                     /* let 0-pad apply */
    emit_padded(s, &sp2, sign, "", body, n, 0);
}

static void fmt_e(Sink *s, const Spec *sp, const BigDec *b, int upper) {
    int P = (sp->prec >= 0) ? sp->prec : 6;
    int is_zero;
    int E = bd_exponent(b, &is_zero);
    char digs[32];
    if (is_zero) {
        for (int i = 0; i <= P; i++) digs[i] = '0';
        E = 0;
    } else {
        if (bd_digits_rounded(b, E, E - P, digs)) E++;
    }
    char body[64];
    int n = 0;
    body[n++] = digs[0];
    if (P > 0 || sp->hash) body[n++] = '.';
    for (int i = 0; i < P; i++) body[n++] = digs[1 + i];
    body[n++] = upper ? 'E' : 'e';
    int ex = E;
    body[n++] = (ex < 0) ? '-' : '+';
    if (ex < 0) ex = -ex;
    char et[8]; int en = 0;
    if (ex == 0) et[en++] = '0';
    while (ex) { et[en++] = (char)('0' + ex % 10); ex /= 10; }
    if (en < 2) et[en++] = '0';                        /* at least 2 exp digits */
    while (en) body[n++] = et[--en];
    const char *sign = b->neg ? "-" : (sp->plus ? "+" : (sp->space ? " " : ""));
    Spec sp2 = *sp; sp2.prec = -1;
    emit_padded(s, &sp2, sign, "", body, n, 0);
}

static void fmt_g(Sink *s, const Spec *sp, const BigDec *b, int upper) {
    int P = (sp->prec >= 0) ? sp->prec : 6;
    if (P == 0) P = 1;
    int is_zero;
    int E = bd_exponent(b, &is_zero);
    char digs[32];
    if (is_zero) {
        for (int i = 0; i < P; i++) digs[i] = '0';
        E = 0;
    } else {
        if (bd_digits_rounded(b, E, E - P + 1, digs)) E++;
    }
    char body[80];
    int n = 0;
    if (E < -4 || E >= P) {
        /* %e form with P-1 frac digits, trailing zeros stripped */
        int frac = P - 1;
        if (!sp->hash) { while (frac > 0 && digs[frac] == '0') frac--; }
        body[n++] = digs[0];
        if (frac > 0 || sp->hash) body[n++] = '.';
        for (int i = 0; i < frac; i++) body[n++] = digs[1 + i];
        body[n++] = upper ? 'E' : 'e';
        int ex = E;
        body[n++] = (ex < 0) ? '-' : '+';
        if (ex < 0) ex = -ex;
        char et[8]; int en = 0;
        if (ex == 0) et[en++] = '0';
        while (ex) { et[en++] = (char)('0' + ex % 10); ex /= 10; }
        if (en < 2) et[en++] = '0';
        while (en) body[n++] = et[--en];
    } else {
        /* %f form with P-1-E frac digits, trailing zeros stripped */
        int frac = P - 1 - E;
        int nd = P;                                    /* digits we have */
        if (!sp->hash) {
            while (frac > 0 && digs[nd - 1] == '0') { nd--; frac--; }
        }
        if (E >= 0) {
            for (int i = 0; i <= E; i++) body[n++] = digs[i];
        } else {
            body[n++] = '0';
        }
        if (frac > 0 || sp->hash) body[n++] = '.';
        if (E < 0) {
            for (int i = 0; i < -E - 1; i++) body[n++] = '0';
            for (int i = 0; i < nd; i++) body[n++] = digs[i];
        } else {
            for (int i = E + 1; i < nd; i++) body[n++] = digs[i];
        }
    }
    const char *sign = b->neg ? "-" : (sp->plus ? "+" : (sp->space ? " " : ""));
    Spec sp2 = *sp; sp2.prec = -1;
    emit_padded(s, &sp2, sign, "", body, n, 0);
}

/* ---------- the driver ---------- */

int eigs_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap) {
    Sink s = { buf, size, 0 };
    for (const char *p = fmt; *p; p++) {
        if (*p != '%') { sink_ch(&s, *p); continue; }
        p++;
        if (*p == '%') { sink_ch(&s, '%'); continue; }
        Spec sp = {0, 0, 0, 0, 0, -1, -1, {0}};
        for (;; p++) {
            if (*p == '-') sp.minus = 1;
            else if (*p == '+') sp.plus = 1;
            else if (*p == ' ') sp.space = 1;
            else if (*p == '0') sp.zero = 1;
            else if (*p == '#') sp.hash = 1;
            else break;
        }
        if (*p == '*') {
            sp.width = va_arg(ap, int);
            if (sp.width < 0) { sp.minus = 1; sp.width = -sp.width; }
            p++;
        } else {
            while (*p >= '0' && *p <= '9') {
                sp.width = (sp.width < 0 ? 0 : sp.width) * 10 + (*p - '0');
                p++;
            }
        }
        if (*p == '.') {
            p++;
            if (*p == '*') {
                sp.prec = va_arg(ap, int);
                if (sp.prec < 0) sp.prec = -1;
                p++;
            } else {
                sp.prec = 0;
                while (*p >= '0' && *p <= '9') {
                    sp.prec = sp.prec * 10 + (*p - '0');
                    p++;
                }
            }
        }
        int li = 0;
        while (*p == 'l' || *p == 'h' || *p == 'z') {
            if (li < 2) sp.len[li++] = *p;
            p++;
        }
        char conv = *p;
        switch (conv) {
        case 'd': case 'i': {
            long long v;
            if (sp.len[0] == 'l' && sp.len[1] == 'l') v = va_arg(ap, long long);
            else if (sp.len[0] == 'l') v = va_arg(ap, long);
            else if (sp.len[0] == 'z') v = (long long)va_arg(ap, size_t);
            else v = va_arg(ap, int);
            if (sp.len[0] == 'h' && sp.len[1] == 'h') v = (signed char)v;
            else if (sp.len[0] == 'h') v = (short)v;
            unsigned long long uv = (v < 0) ? (unsigned long long)(-(v + 1)) + 1
                                            : (unsigned long long)v;
            fmt_uint(&s, &sp, uv, 10, 0, v < 0);
            break;
        }
        case 'u': case 'x': case 'X': case 'o': {
            unsigned long long v;
            if (sp.len[0] == 'l' && sp.len[1] == 'l') v = va_arg(ap, unsigned long long);
            else if (sp.len[0] == 'l') v = va_arg(ap, unsigned long);
            else if (sp.len[0] == 'z') v = va_arg(ap, size_t);
            else v = va_arg(ap, unsigned int);
            if (sp.len[0] == 'h' && sp.len[1] == 'h') v = (unsigned char)v;
            else if (sp.len[0] == 'h') v = (unsigned short)v;
            int base = (conv == 'u') ? 10 : (conv == 'o') ? 8 : 16;
            fmt_uint(&s, &sp, v, base, conv == 'X', 0);
            break;
        }
        case 'c': {
            char c = (char)va_arg(ap, int);
            int pad = (sp.width > 1) ? sp.width - 1 : 0;
            if (!sp.minus) sink_pad(&s, ' ', pad);
            sink_ch(&s, c);
            if (sp.minus) sink_pad(&s, ' ', pad);
            break;
        }
        case 's': {
            const char *str = va_arg(ap, const char *);
            if (!str) str = "(null)";
            size_t sl = 0;
            while (str[sl] && (sp.prec < 0 || sl < (size_t)sp.prec)) sl++;
            int pad = (sp.width > (int)sl) ? sp.width - (int)sl : 0;
            if (!sp.minus) sink_pad(&s, ' ', pad);
            sink_n(&s, str, sl);
            if (sp.minus) sink_pad(&s, ' ', pad);
            break;
        }
        case 'f': case 'F': case 'e': case 'E': case 'g': case 'G': {
            double d = va_arg(ap, double);
            static BigDec bd;                          /* 1.5KB — off the stack;
                                                          formatter is not reentrant,
                                                          matching the runtime's
                                                          single-threaded printing */
            bd_from_double(&bd, d);
            if (bd.special) emit_special(&s, &sp, &bd, conv == 'E' || conv == 'G' || conv == 'F');
            else if (conv == 'f' || conv == 'F') fmt_f(&s, &sp, &bd);
            else if (conv == 'e' || conv == 'E') fmt_e(&s, &sp, &bd, conv == 'E');
            else fmt_g(&s, &sp, &bd, conv == 'G');
            break;
        }
        default:                                       /* unknown: emit verbatim */
            sink_ch(&s, '%');
            if (conv) sink_ch(&s, conv);
            break;
        }
        if (!conv) break;
    }
    if (size > 0) {
        size_t end = (s.len < size - 1) ? s.len : size - 1;
        buf[end] = 0;
    }
    return (int)s.len;
}

int eigs_snprintf(char *buf, size_t size, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = eigs_vsnprintf(buf, size, fmt, ap);
    va_end(ap);
    return r;
}

#if EIGS_MINI_STANDARD_NAMES
int vsnprintf(char *, size_t, const char *, va_list) __attribute__((alias("eigs_vsnprintf")));
int snprintf(char *, size_t, const char *, ...) __attribute__((alias("eigs_snprintf")));
#endif
