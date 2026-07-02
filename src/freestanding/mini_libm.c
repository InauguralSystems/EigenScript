/* mini_libm.c — the portable libm subset for the freestanding profile.
 *
 * Design: 4 real kernels (exp, log, sin/cos, atan) + derived forms,
 * exactly as docs/FREESTANDING.md prescribes. Kernels use Taylor series
 * on deeply-reduced arguments (no borrowed minimax coefficient tables),
 * with two-part constants for the range reductions. Exactness classes:
 *   exact:        fabs floor ceil round fmod sqrt (hardware sqrtsd)
 *   few-ulp:      exp log log2 sin cos atan atan2 asin acos (harness
 *                 asserts per-function ulp bounds vs glibc)
 *   composed:     tan (sin/cos), pow (exp2(y*log2 x) with double-word
 *                 product splitting)
 * Trig argument reduction is Cody-Waite (3-part pi/2): full accuracy for
 * |x| <= ~1e6, degrading beyond — documented, asserted loosely by the
 * harness out to 1e8 and not beyond (EigenScript numerics live well
 * inside that; Payne-Hanek is a later refinement if anything needs it).
 */
#include "mini_libc.h"
#include <stdint.h>

typedef union { double d; uint64_t u; } db;

static double mk_inf(void) { db v; v.u = 0x7FF0000000000000ULL; return v.d; }
static double mk_nan(void) { db v; v.u = 0x7FF8000000000000ULL; return v.d; }
static int is_nan(double x) { db v; v.d = x; return ((v.u >> 52) & 0x7FF) == 0x7FF && (v.u << 12); }
static int is_inf(double x) { db v; v.d = x; return ((v.u >> 52) & 0x7FF) == 0x7FF && !(v.u << 12); }

double eigs_fabs(double x) { db v; v.d = x; v.u &= 0x7FFFFFFFFFFFFFFFULL; return v.d; }

double eigs_floor(double x) {
    db v; v.d = x;
    int e = (int)((v.u >> 52) & 0x7FF) - 1023;
    if (e >= 52 || is_nan(x)) return x;              /* already integral (or nan/inf) */
    if (e < 0) {                                      /* |x| < 1 */
        if (x == 0.0) return x;
        return (v.u >> 63) ? -1.0 : 0.0;
    }
    uint64_t mask = 0x000FFFFFFFFFFFFFULL >> e;
    if (!(v.u & mask)) return x;                      /* integral */
    if (v.u >> 63) { v.u &= ~mask; return v.d - 1.0; }
    v.u &= ~mask; return v.d;
}

double eigs_ceil(double x) { return -eigs_floor(-x); }

double eigs_round(double x) {                         /* ties away from zero */
    if (is_nan(x) || is_inf(x) || x == 0.0) return x;   /* keeps -0.0 */
    double f = eigs_floor(eigs_fabs(x));
    double frac = eigs_fabs(x) - f;
    double r = (frac >= 0.5) ? f + 1.0 : f;
    return x < 0.0 ? -r : r;
}

double eigs_sqrt(double x) {
    /* Hardware sqrt: gcc/clang lower __builtin_sqrt to sqrtsd on
     * x86-64 (the only freestanding target today) with no libcall when
     * math-errno is off; the freestanding build compiles this file with
     * -fno-math-errno to guarantee that. Correctly rounded by IEEE. */
    return __builtin_sqrt(x);
}

double eigs_fmod(double x, double y) {                /* exact shift-subtract */
    if (is_nan(x) || is_nan(y) || is_inf(x) || y == 0.0) return mk_nan();
    if (is_inf(y) || x == 0.0) return x;
    double ax = eigs_fabs(x), ay = eigs_fabs(y);
    if (ax < ay) return x;
    /* Decompose |x| and repeatedly subtract the largest 2^k*|y| <= rem. */
    double rem = ax;
    while (rem >= ay) {
        double t = ay;
        while (rem - t >= t) {                        /* double t while it fits twice */
            t += t;
            if (is_inf(t)) break;
        }
        rem -= t;
    }
    return x < 0.0 ? -rem : rem;
}

/* ---- exp kernel ----
 * x = k*ln2 + r with |r| <= ln2/2; e^r by Taylor to r^13 (trunc error
 * ~1e-17 at the boundary); scale by 2^k through the exponent field. */
static const double LN2_HI = 6.93147180369123816490e-01;   /* top bits of ln2 */
static const double LN2_LO = 1.90821492927058770002e-10;   /* ln2 - LN2_HI */
static const double INV_LN2 = 1.44269504088896338700e+00;

static double exp_kernel(double r) {
    /* Horner over 1 + r + r^2/2! ... + r^13/13! */
    double p = 1.0 / 6227020800.0;                     /* 1/13! */
    p = p * r + 1.0 / 479001600.0;
    p = p * r + 1.0 / 39916800.0;
    p = p * r + 1.0 / 3628800.0;
    p = p * r + 1.0 / 362880.0;
    p = p * r + 1.0 / 40320.0;
    p = p * r + 1.0 / 5040.0;
    p = p * r + 1.0 / 720.0;
    p = p * r + 1.0 / 120.0;
    p = p * r + 1.0 / 24.0;
    p = p * r + 1.0 / 6.0;
    p = p * r + 0.5;
    p = p * r + 1.0;
    p = p * r + 1.0;
    return p;
}

static double scale_2k(double v, int k) {             /* v * 2^k, careful at edges */
    while (k > 1000)  { v *= 1.0715086071862673e+301; k -= 1000; }  /* 2^1000 */
    while (k < -1000) { v *= 9.3326361850321888e-302; k += 1000; }  /* 2^-1000 */
    db s; s.u = (uint64_t)(1023 + k) << 52;
    return v * s.d;
}

double eigs_exp(double x) {
    if (is_nan(x)) return mk_nan();
    if (x > 709.79) return mk_inf();
    if (x < -745.2) return 0.0;
    int k = (int)eigs_round(x * INV_LN2);
    double r = (x - (double)k * LN2_HI) - (double)k * LN2_LO;
    return scale_2k(exp_kernel(r), k);
}

/* ---- log kernel ----
 * x = m*2^e with m in [sqrt(1/2), sqrt(2)); s = (m-1)/(m+1);
 * log m = 2*atanh(s) by odd Taylor to s^21 (|s| <= 0.1716). */
static double log_kernel_2atanh(double s) {
    double z = s * s;
    double p = 1.0 / 21.0;
    p = p * z + 1.0 / 19.0;
    p = p * z + 1.0 / 17.0;
    p = p * z + 1.0 / 15.0;
    p = p * z + 1.0 / 13.0;
    p = p * z + 1.0 / 11.0;
    p = p * z + 1.0 / 9.0;
    p = p * z + 1.0 / 7.0;
    p = p * z + 1.0 / 5.0;
    p = p * z + 1.0 / 3.0;
    p = p * z + 1.0;
    return 2.0 * s * p;
}

static double log_reduce(double x, int *e_out) {
    db v; v.d = x;
    int e = 0;
    if (v.u < (1ULL << 52)) {                          /* subnormal: normalize */
        v.d = x * 4503599627370496.0;                  /* 2^52 */
        e -= 52;
    }
    e += (int)((v.u >> 52) & 0x7FF) - 1023;
    v.u = (v.u & 0x000FFFFFFFFFFFFFULL) | (1023ULL << 52);   /* m in [1,2) */
    if (v.d > 1.4142135623730951) { v.d *= 0.5; e += 1; }
    *e_out = e;
    return v.d;
}

double eigs_log(double x) {
    if (is_nan(x) || x < 0.0) return mk_nan();
    if (x == 0.0) return -mk_inf();
    if (is_inf(x)) return x;
    int e;
    double m = log_reduce(x, &e);
    double s = (m - 1.0) / (m + 1.0);
    double lm = log_kernel_2atanh(s);
    return (double)e * LN2_HI + ((double)e * LN2_LO + lm);
}

double eigs_log2(double x) {
    if (is_nan(x) || x < 0.0) return mk_nan();
    if (x == 0.0) return -mk_inf();
    if (is_inf(x)) return x;
    int e;
    double m = log_reduce(x, &e);
    double s = (m - 1.0) / (m + 1.0);
    double lm = log_kernel_2atanh(s);                  /* ln m */
    return (double)e + lm * INV_LN2;
}

/* ---- pow ----
 * Small integer exponents go through exact repeated squaring (covers
 * x^2, x^-1, x^10 ... bit-exactly). The general path is
 * 2^(y*log2 x) with the product split double-word (Dekker two-prod,
 * no FMA requirement) so the integer part of the exponent is applied
 * exactly and only the fractional residue rides the exp kernel. */

static void two_prod(double a, double b, double *hi, double *lo) {
    const double SPLIT = 134217729.0;                  /* 2^27 + 1 */
    double p = a * b;
    double a1 = a * SPLIT, b1 = b * SPLIT;
    double ah = a1 - (a1 - a), al = a - ah;
    double bh = b1 - (b1 - b), bl = b - bh;
    *hi = p;
    *lo = ((ah * bh - p) + ah * bl + al * bh) + al * bl;
}

double eigs_pow(double x, double y) {
    if (y == 0.0) return 1.0;
    if (x == 1.0) return 1.0;
    if (is_nan(x) || is_nan(y)) return mk_nan();
    int y_int = (y == eigs_floor(y) && eigs_fabs(y) <= 1e15);
    int y_odd = y_int && (eigs_fmod(eigs_fabs(y), 2.0) == 1.0);
    /* tiny integer exponents: repeated squaring is within ~1 ulp and
     * hits the common x^2 / x^3 / 1/x cases exactly where possible */
    if (y_int && eigs_fabs(y) <= 4.0) {
        long n = (long)y;
        int inv = n < 0;
        unsigned long un = (unsigned long)(inv ? -n : n);
        double acc = 1.0, base = x;
        while (un) {
            if (un & 1) acc *= base;
            base *= base;
            un >>= 1;
        }
        return inv ? 1.0 / acc : acc;
    }
    if (y == 0.5 && x >= 0.0) return eigs_sqrt(x);     /* glibc-exact shortcut */
    if (x < 0.0) {
        if (!y_int) return mk_nan();                   /* non-integer power of negative */
        double r = eigs_pow(-x, y);                    /* magnitude via general path */
        return y_odd ? -r : r;
    }
    if (x == 0.0) return y > 0.0 ? 0.0 : mk_inf();
    if (is_inf(x)) return y > 0.0 ? x : 0.0;
    if (is_inf(y)) {
        double ax = eigs_fabs(x);
        if (ax == 1.0) return 1.0;
        return (ax > 1.0) == (y > 0.0) ? mk_inf() : 0.0;
    }
    /* log2(x) in double-double so the y-scaled exponent keeps ~2^-90
     * of precision — the single-double version's error grows linearly
     * with |y| (measured ~34 ulp at y=300 before this). */
    int e;
    double m = log_reduce(x, &e);
    double d1 = m - 1.0;                               /* exact (Sterbenz) */
    double d2 = m + 1.0;
    double d2lo = (1.0 - d2) + m;                      /* Fast2Sum residue */
    double sq = d1 / d2;
    double ph, pl;
    two_prod(sq, d2, &ph, &pl);
    double slo = (((d1 - ph) - pl) - sq * d2lo) / d2;  /* s correction word */
    /* ln m = 2s + tail, tail = 2*s^3*P(s^2) + 2*slo (both tiny) */
    double z = sq * sq;
    double p = 1.0 / 21.0;
    p = p * z + 1.0 / 19.0;
    p = p * z + 1.0 / 17.0;
    p = p * z + 1.0 / 15.0;
    p = p * z + 1.0 / 13.0;
    p = p * z + 1.0 / 11.0;
    p = p * z + 1.0 / 9.0;
    p = p * z + 1.0 / 7.0;
    p = p * z + 1.0 / 5.0;
    p = p * z + 1.0 / 3.0;
    double tail = 2.0 * sq * z * p + 2.0 * slo;
    double lmh = 2.0 * sq + tail;                      /* Fast2Sum */
    double lml = (2.0 * sq - lmh) + tail;
    /* (lmh + lml) * (1/ln2) as double-double */
    static const double IL2_HI = 1.44269504088896338700e+00;
    static const double IL2_LO = 2.03552737407310267271e-17;
    double lh, ll;
    two_prod(lmh, IL2_HI, &lh, &ll);
    ll += lmh * IL2_LO + lml * IL2_HI;
    /* add the integer exponent exactly (Fast2Sum: |e| >= |lh| or e==0) */
    double eh = (double)e + lh;
    double el = ((double)e - eh) + lh;
    ll += el;
    /* t = y * log2(x) as hi+lo */
    double th, tl;
    two_prod(y, eh, &th, &tl);
    tl += y * ll;
    if (th > 1025.0) return mk_inf();
    if (th < -1075.0) return 0.0;
    double n = eigs_round(th);
    double f = (th - n) + tl;                          /* |f| <= 0.5 + eps */
    /* f*ln2 in double-double feeding the kernel, low word as (1+rl) */
    double rh, rl;
    two_prod(f, LN2_HI, &rh, &rl);
    rl += f * LN2_LO;
    double ek = exp_kernel(rh);
    return scale_2k(ek + ek * rl, (int)n);
}

/* ---- trig ----
 * Cody-Waite reduction: n = round(x * 2/pi), r = x - n*(P1+P2+P3).
 * P1/P2 carry trailing zero bits so n*P1, n*P2 are exact for |n| < 2^26.
 * Kernels: odd/even Taylor to r^17 / r^16 on |r| <= pi/4. */
static const double PIO2_1 = 1.57079632673412561417e+00;   /* first 33 bits */
static const double PIO2_2 = 6.07710050630396597660e-11;   /* next 33 bits */
static const double PIO2_3 = 2.02226624879595063154e-21;   /* residue */
static const double INV_PIO2 = 6.36619772367581382433e-01; /* 2/pi */

static double sin_kernel(double r) {
    double z = r * r;
    double p = -1.0 / 355687428096000.0;               /* -1/17!: sign folded below */
    p = -p;                                            /* +1/17! */
    p = p * z - 1.0 / 1307674368000.0;                 /* 15! */
    p = p * z + 1.0 / 6227020800.0;                    /* 13! */
    p = p * z - 1.0 / 39916800.0;                      /* 11! */
    p = p * z + 1.0 / 362880.0;                        /* 9! */
    p = p * z - 1.0 / 5040.0;                          /* 7! */
    p = p * z + 1.0 / 120.0;                           /* 5! */
    p = p * z - 1.0 / 6.0;                             /* 3! */
    return r + r * z * p;
}

static double cos_kernel(double r) {
    double z = r * r;
    double p = 1.0 / 20922789888000.0;                 /* 1/16! */
    p = p * z - 1.0 / 87178291200.0;                   /* 14! */
    p = p * z + 1.0 / 479001600.0;                     /* 12! */
    p = p * z - 1.0 / 3628800.0;                       /* 10! */
    p = p * z + 1.0 / 40320.0;                         /* 8! */
    p = p * z - 1.0 / 720.0;                           /* 6! */
    p = p * z + 1.0 / 24.0;                            /* 4! */
    p = p * z - 0.5;                                   /* 2! */
    return 1.0 + z * p;
}

/* Two-word reduction: r + c together carry x - n*pi/2 to ~2^-70 so the
 * result stays accurate even when it lands near a zero of sin/cos.
 * n*PIO2_1 is exact for |n| < 2^20 (33-bit constant), i.e. |x| <~ 1.6e6;
 * beyond that accuracy degrades gracefully (documented, not asserted). */
static int trig_reduce(double x, double *r_out, double *c_out) {
    double n = eigs_round(x * INV_PIO2);
    double hi = x - n * PIO2_1;                        /* exact cancellation */
    double t2 = n * PIO2_2;
    double r = hi - t2;
    double w = (hi - r) - t2;                          /* rounding of that step */
    double t3 = n * PIO2_3;
    double r2 = r - t3;
    w = w - ((r2 - r) + t3);
    *r_out = r2;
    *c_out = w;
    return (int)eigs_fmod(n, 4.0);                     /* quadrant, sign-correct below */
}

/* sin/cos of (r + c) with |c| tiny: first-order correction terms. */
static double sin_rc(double r, double c) {
    return sin_kernel(r) + c * (1.0 - 0.5 * r * r);
}
static double cos_rc(double r, double c) {
    return cos_kernel(r) - c * r;
}

double eigs_sin(double x) {
    if (is_nan(x) || is_inf(x)) return mk_nan();
    double r, c;
    int q = trig_reduce(x, &r, &c);
    if (q < 0) q += 4;
    switch (q) {
    case 0: return sin_rc(r, c);
    case 1: return cos_rc(r, c);
    case 2: return -sin_rc(r, c);
    default: return -cos_rc(r, c);
    }
}

double eigs_cos(double x) {
    if (is_nan(x) || is_inf(x)) return mk_nan();
    double r, c;
    int q = trig_reduce(x, &r, &c);
    if (q < 0) q += 4;
    switch (q) {
    case 0: return cos_rc(r, c);
    case 1: return -sin_rc(r, c);
    case 2: return -cos_rc(r, c);
    default: return sin_rc(r, c);
    }
}

double eigs_tan(double x) {
    if (is_nan(x) || is_inf(x)) return mk_nan();
    double r, c;
    int q = trig_reduce(x, &r, &c);
    double s = sin_rc(r, c), co = cos_rc(r, c);
    return ((q & 1) == 0) ? s / co : -co / s;
}

/* ---- atan kernel ----
 * Three argument halvings via atan(x) = 2 atan(x / (1 + sqrt(1+x^2)))
 * bring |t| under tan(pi/32) ~= 0.0985 for |x| <= 1; odd Taylor to
 * t^15 then finishes under 1e-16 truncation. |x| > 1 reflects through
 * pi/2 - atan(1/x). No coefficient tables. */
static double atan_kernel(double t) {
    double z = t * t;
    double p = -1.0 / 15.0;
    p = p * z + 1.0 / 13.0;
    p = p * z - 1.0 / 11.0;
    p = p * z + 1.0 / 9.0;
    p = p * z - 1.0 / 7.0;
    p = p * z + 1.0 / 5.0;
    p = p * z - 1.0 / 3.0;
    return t + t * z * p;
}

static const double PI_D      = 3.14159265358979311600e+00;
static const double PI_2_D    = 1.57079632679489655800e+00;

double eigs_atan(double x) {
    if (is_nan(x)) return mk_nan();
    if (is_inf(x)) return x > 0 ? PI_2_D : -PI_2_D;
    double ax = eigs_fabs(x);
    if (ax < 7.450580596923828125e-9) return x;        /* < 2^-27: atan x = x */
    int recip = 0;
    if (ax > 1.0) { ax = 1.0 / ax; recip = 1; }
    double a;
    if (ax <= 0.0625) {
        a = atan_kernel(ax);                           /* series is direct here */
    } else {
        double t = ax;
        t = t / (1.0 + eigs_sqrt(1.0 + t * t));
        t = t / (1.0 + eigs_sqrt(1.0 + t * t));
        t = t / (1.0 + eigs_sqrt(1.0 + t * t));
        a = 8.0 * atan_kernel(t);
    }
    if (recip) a = PI_2_D - a;
    return x < 0.0 ? -a : a;
}

double eigs_atan2(double y, double x) {
    if (is_nan(x) || is_nan(y)) return mk_nan();
    if (x > 0.0) {
        if (y == 0.0) return y;                        /* +-0 keeps its sign */
        if (is_inf(x) && !is_inf(y)) return y > 0 ? 0.0 : -0.0;
        return eigs_atan(y / x);
    }
    if (x < 0.0) {
        if (y == 0.0) return (db){.d = y}.u >> 63 ? -PI_D : PI_D;
        if (is_inf(x) && !is_inf(y)) return y > 0 ? PI_D : -PI_D;
        double a = eigs_atan(y / x);
        return y > 0.0 ? a + PI_D : a - PI_D;
    }
    /* x == 0 */
    if (y > 0.0) return PI_2_D;
    if (y < 0.0) return -PI_2_D;
    return (db){.d = x}.u >> 63
        ? ((db){.d = y}.u >> 63 ? -PI_D : PI_D)
        : y;                                           /* atan2(+-0, +0) = +-0 */
}

double eigs_asin(double x) {
    if (is_nan(x) || x > 1.0 || x < -1.0) return mk_nan();
    return eigs_atan2(x, eigs_sqrt((1.0 - x) * (1.0 + x)));
}

double eigs_acos(double x) {
    if (is_nan(x) || x > 1.0 || x < -1.0) return mk_nan();
    return eigs_atan2(eigs_sqrt((1.0 - x) * (1.0 + x)), x);
}

#if EIGS_MINI_STANDARD_NAMES
double fabs(double) __attribute__((alias("eigs_fabs")));
double floor(double) __attribute__((alias("eigs_floor")));
double ceil(double) __attribute__((alias("eigs_ceil")));
double round(double) __attribute__((alias("eigs_round")));
double sqrt(double) __attribute__((alias("eigs_sqrt")));
double fmod(double, double) __attribute__((alias("eigs_fmod")));
double exp(double) __attribute__((alias("eigs_exp")));
double log(double) __attribute__((alias("eigs_log")));
double log2(double) __attribute__((alias("eigs_log2")));
double pow(double, double) __attribute__((alias("eigs_pow")));
double sin(double) __attribute__((alias("eigs_sin")));
double cos(double) __attribute__((alias("eigs_cos")));
double tan(double) __attribute__((alias("eigs_tan")));
double asin(double) __attribute__((alias("eigs_asin")));
double acos(double) __attribute__((alias("eigs_acos")));
double atan(double) __attribute__((alias("eigs_atan")));
double atan2(double, double) __attribute__((alias("eigs_atan2")));
#endif /* EIGS_MINI_STANDARD_NAMES */
