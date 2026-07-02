/* mini_strtod.c — correctly-rounded decimal → double for the
 * freestanding profile. Two paths:
 *   fast (Clinger): <= 15 significant digits and |10-exponent| <= 22 —
 *     one exact double multiply/divide, correctly rounded by hardware.
 *   slow (exact): digit-array arithmetic — integer bits by longhand
 *     halving, fraction bits by longhand doubling, then round half-even
 *     on guard+sticky. Bit-equal to glibc by construction (the harness
 *     asserts it over randomized corpora).
 * Parses decimal, inf/infinity/nan (case-insensitive). No hex floats
 * (the runtime's lexer never produces them) — documented divergence.
 */
#include "mini_libc.h"
#include <stdint.h>

#define EIGS_ERANGE 34

static int lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }
static int is_sp(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

static double make_bits(uint64_t sign, int e2, uint64_t man53) {
    /* man53 has its leading 1 at bit 52 (normal) — e2 is the exponent of
     * that leading bit. Subnormal callers pass man53 already shifted with
     * e2 = -1023 (biased 0). */
    union { double d; uint64_t u; } v;
    v.u = (sign << 63) | ((uint64_t)(e2 + 1023) << 52) | (man53 & 0x000FFFFFFFFFFFFFULL);
    return v.d;
}

static const double POW10[23] = {
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
};

#define MAXD 800    /* significant digits kept (rest folded into sticky) */

double eigs_strtod(const char *nptr, char **endptr) {
    const char *s = nptr;
    while (is_sp(*s)) s++;
    uint64_t sign = 0;
    if (*s == '+' || *s == '-') { sign = (*s == '-'); s++; }

    /* inf / infinity / nan */
    if (lower(s[0]) == 'i' && lower(s[1]) == 'n' && lower(s[2]) == 'f') {
        const char *e = s + 3;
        if (lower(e[0]) == 'i' && lower(e[1]) == 'n' && lower(e[2]) == 'i' &&
            lower(e[3]) == 't' && lower(e[4]) == 'y') e += 5;
        if (endptr) *endptr = (char *)e;
        union { double d; uint64_t u; } v;
        v.u = (sign << 63) | 0x7FF0000000000000ULL;
        return v.d;
    }
    if (lower(s[0]) == 'n' && lower(s[1]) == 'a' && lower(s[2]) == 'n') {
        if (endptr) *endptr = (char *)(s + 3);
        union { double d; uint64_t u; } v;
        v.u = (sign << 63) | 0x7FF8000000000000ULL;
        return v.d;
    }

    /* collect significant digits; dexp = power of 10 of the LAST kept digit */
    static unsigned char dig[MAXD];
    int nd = 0;
    long dexp = 0;
    int seen_digit = 0, seen_point = 0, sticky_in = 0;
    const char *last_ok = NULL;
    for (;; s++) {
        if (*s >= '0' && *s <= '9') {
            seen_digit = 1;
            last_ok = s + 1;
            if (nd == 0 && *s == '0' && !seen_point) continue;    /* skip leading zeros */
            if (nd < MAXD) {
                if (nd == 0 && *s == '0') {
                    /* leading zeros after the point: pure scale */
                    if (seen_point) dexp--;
                    continue;
                }
                dig[nd++] = (unsigned char)(*s - '0');
                if (seen_point) dexp--;
            } else {
                if (*s != '0') sticky_in = 1;
                if (!seen_point) dexp++;                           /* dropped int digit */
            }
        } else if (*s == '.' && !seen_point) {
            seen_point = 1;
            if (seen_digit) last_ok = s + 1;   /* "5." consumes the dot */
        } else break;
    }
    if (!seen_digit) {
        if (endptr) *endptr = (char *)nptr;
        return 0.0;
    }
    if (*s == 'e' || *s == 'E') {
        const char *es = s + 1;
        int eneg = 0;
        if (*es == '+' || *es == '-') { eneg = (*es == '-'); es++; }
        if (*es >= '0' && *es <= '9') {
            long ev = 0;
            while (*es >= '0' && *es <= '9') {
                if (ev < 1000000) ev = ev * 10 + (*es - '0');
                es++;
            }
            dexp += eneg ? -ev : ev;
            last_ok = es;
        }
    }
    if (endptr) *endptr = (char *)last_ok;

    /* trim trailing zeros of the digit string (fold into dexp) */
    while (nd > 0 && dig[nd - 1] == 0) { nd--; dexp++; }
    if (nd == 0) return sign ? -0.0 : 0.0;

    /* quick over/underflow bounds: value in [10^(dexp+nd-1), 10^(dexp+nd)) */
    long mag = dexp + nd;                    /* number of integer digits-ish */
    if (mag > 310)  { *eigs_errno_location() = EIGS_ERANGE;
                      union { double d; uint64_t u; } v;
                      v.u = (sign << 63) | 0x7FF0000000000000ULL; return v.d; }
    if (mag < -350) { *eigs_errno_location() = EIGS_ERANGE;
                      return sign ? -0.0 : 0.0; }

    /* ---- Clinger fast path ---- */
    if (nd <= 15 && !sticky_in) {
        uint64_t N = 0;
        for (int i = 0; i < nd; i++) N = N * 10 + dig[i];
        double dN = (double)N;              /* exact: N < 10^15 < 2^53 */
        if (dexp == 0) return sign ? -dN : dN;
        if (dexp > 0 && dexp <= 22) {
            double r = dN * POW10[dexp];
            return sign ? -r : r;
        }
        if (dexp < 0 && dexp >= -22) {
            double r = dN / POW10[-dexp];
            return sign ? -r : r;
        }
    }

    /* ---- exact slow path ----
     * Build fixed-point decimal: INT digits I[], FRAC digits F[]. */
    static unsigned char I[1200], F[1200];
    int ni = 0, nf = 0;
    if (dexp >= 0) {                        /* integer: digits + dexp zeros */
        for (int i = 0; i < nd; i++) I[ni++] = dig[i];
        for (long i = 0; i < dexp; i++) I[ni++] = 0;
    } else if ((long)nd + dexp <= 0) {      /* pure fraction: leading zeros */
        for (long i = 0; i < -dexp - nd; i++) F[nf++] = 0;
        for (int i = 0; i < nd; i++) F[nf++] = dig[i];
    } else {                                /* split */
        long ip = nd + dexp;
        for (long i = 0; i < ip; i++) I[ni++] = dig[i];
        for (int i = (int)ip; i < nd; i++) F[nf++] = dig[i];
    }

    /* integer part -> bits (LSB first) by longhand halving */
    static unsigned char bits[4200];
    int nbits = 0;
    {
        int len = ni;
        unsigned char *w = I;
        while (len > 0) {
            int rem = 0;
            for (int i = 0; i < len; i++) {
                int cur = rem * 10 + w[i];
                w[i] = (unsigned char)(cur >> 1);
                rem = cur & 1;
            }
            bits[nbits++] = (unsigned char)rem;
            while (len > 0 && w[0] == 0) { w++; len--; }
        }
    }

    uint64_t man = 0;           /* rounded 54-bit window builder */
    int e2;                     /* exponent of the leading mantissa bit */
    int guard = 0, sticky = sticky_in;

    if (nbits > 0) {
        e2 = nbits - 1;
        int need = 54;                       /* 53 + guard */
        int taken = 0;
        for (int i = nbits - 1; i >= 0 && taken < need; i--, taken++)
            man = (man << 1) | bits[i];
        if (taken == need) {
            guard = (int)(man & 1);
            man >>= 1;
            for (int i = 0; i < nbits - need; i++) if (bits[i]) { sticky = 1; break; }
            for (int i = 0; i < nf; i++) if (F[i]) { sticky = 1; break; }
        } else {
            /* fewer than 54 int bits: continue with fraction doubling */
            while (taken < need && nf > 0) {
                int carry = 0;
                for (int i = nf - 1; i >= 0; i--) {
                    int cur = F[i] * 2 + carry;
                    F[i] = (unsigned char)(cur % 10);
                    carry = cur / 10;
                }
                man = (man << 1) | (uint64_t)carry;
                taken++;
            }
            while (taken < need) { man <<= 1; taken++; }   /* exact zero fill */
            guard = (int)(man & 1);
            man >>= 1;
            for (int i = 0; i < nf; i++) if (F[i]) { sticky = 1; break; }
        }
    } else {
        /* no integer part: double the fraction until the first 1 bit */
        int zeros = 0;
        int first = 0;
        while (!first) {
            int carry = 0;
            for (int i = nf - 1; i >= 0; i--) {
                int cur = F[i] * 2 + carry;
                F[i] = (unsigned char)(cur % 10);
                carry = cur / 10;
            }
            if (carry) first = 1; else zeros++;
            if (zeros > 1080) return sign ? -0.0 : 0.0;    /* below subnormal floor */
        }
        e2 = -(zeros + 1);
        man = 1;
        int taken = 1;
        int need = 54;
        if (e2 < -1022) {                   /* subnormal: fewer usable bits */
            need = 54 + (e2 + 1022);        /* 53 + guard - deficit */
            if (need < 1) {
                /* Leading bit at 2^-1076 or below: strictly under half of
                 * the minimum subnormal — flushes to zero. (Exactly-half
                 * lands in the need==1 path and half-even rounds there.) */
                *eigs_errno_location() = EIGS_ERANGE;
                return sign ? -0.0 : 0.0;
            }
        }
        while (taken < need) {
            int carry = 0;
            for (int i = nf - 1; i >= 0; i--) {
                int cur = F[i] * 2 + carry;
                F[i] = (unsigned char)(cur % 10);
                carry = cur / 10;
            }
            man = (man << 1) | (uint64_t)carry;
            taken++;
        }
        guard = (int)(man & 1);
        man >>= 1;
        for (int i = 0; i < nf; i++) if (F[i]) { sticky = 1; break; }
    }

    /* round half-even */
    if (guard && (sticky || (man & 1))) {
        man++;
        if (man >> 53) { man >>= 1; e2++; }             /* carried to next power */
        else if (e2 < -1022 && (man >> 52)) e2 = -1022; /* subnormal became normal */
    }

    if (e2 > 1023) {
        *eigs_errno_location() = EIGS_ERANGE;
        union { double d; uint64_t u; } v;
        v.u = (sign << 63) | 0x7FF0000000000000ULL;
        return v.d;
    }
    if (e2 < -1022) {
        /* assemble subnormal: man already holds the shifted bits */
        union { double d; uint64_t u; } v;
        v.u = (sign << 63) | man;
        if (man == 0) *eigs_errno_location() = EIGS_ERANGE;
        return v.d;
    }
    return make_bits(sign, e2, man);
}

#if EIGS_MINI_STANDARD_NAMES
double strtod(const char *, char **) __attribute__((alias("eigs_strtod")));
#endif
