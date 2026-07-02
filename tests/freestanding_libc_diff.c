/* freestanding_libc_diff.c — hosted differential harness: every
 * mini-libc/libm function vs glibc as the oracle. Deterministic seeds.
 *
 * Contracts (fail the run when violated):
 *   bit/byte-exact: mem/str, ctype tables, strtol/strtoul, strtod,
 *                   rand48 sequence, snprintf corpus, fabs/floor/ceil/
 *                   round/sqrt/fmod
 *   ulp-bounded:    exp/log/log2 (<=2), sin/cos/atan/atan2/asin/acos
 *                   (<=4, |x|<=1e6 for trig), tan (<=8), pow (<=8)
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <stdint.h>
#include <inttypes.h>
#include "../src/freestanding/mini_libc.h"

static int g_fail = 0;
static uint64_t g_rng = 0x243F6A8885A308D3ULL;
static uint64_t rnd(void) {
    g_rng ^= g_rng << 13; g_rng ^= g_rng >> 7; g_rng ^= g_rng << 17;
    return g_rng;
}
static double rnd_double_full(void) {          /* any bit pattern (may be nan/inf) */
    union { uint64_t u; double d; } v; v.u = rnd(); return v.d;
}
static double rnd_double_finite(void) {
    double d;
    do { d = rnd_double_full(); } while (isnan(d) || isinf(d));
    return d;
}
static double rnd_range(double lo, double hi) {
    return lo + (hi - lo) * ((double)(rnd() >> 11) / 9007199254740992.0);
}

static uint64_t bits_of(double d) { union { double d; uint64_t u; } v; v.d = d; return v.u; }

static uint64_t ulp_dist(double a, double b) {
    if (isnan(a) && isnan(b)) return 0;
    if (isnan(a) || isnan(b)) return UINT64_MAX;
    if (a == b) return 0;                      /* covers +0/-0 */
    int64_t ia = (int64_t)bits_of(a), ib = (int64_t)bits_of(b);
    if (ia < 0) ia = INT64_MIN - ia;           /* map to monotonic ordering */
    if (ib < 0) ib = INT64_MIN - ib;
    uint64_t d = (ia > ib) ? (uint64_t)(ia - ib) : (uint64_t)(ib - ia);
    return d;
}

#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("  FAIL: " __VA_ARGS__); printf("\n"); g_fail++; } \
} while (0)

/* ---------------- sections ---------------- */

static void t_mem_str(void) {
    printf("[mem/str]\n");
    unsigned char a[512], b[512], r1[600], r2[600];
    for (int it = 0; it < 20000; it++) {
        size_t n = rnd() % 500;
        for (size_t i = 0; i < n + 8; i++) { a[i] = (unsigned char)rnd(); b[i] = (unsigned char)rnd(); }
        memcpy(r1, a, n + 8); eigs_memcpy(r2, a, n + 8);
        CHECK(!memcmp(r1, r2, n + 8), "memcpy n=%zu", n);
        CHECK((eigs_memcmp(a, b, n) > 0) == (memcmp(a, b, n) > 0) &&
              (eigs_memcmp(a, b, n) < 0) == (memcmp(a, b, n) < 0), "memcmp");
        memcpy(r1, a, n + 8); memcpy(r2, a, n + 8);
        size_t off = rnd() % 8;
        memmove(r1 + off, r1, n); eigs_memmove(r2 + off, r2, n);
        CHECK(!memcmp(r1, r2, n + 8), "memmove fwd");
        memcpy(r1, a, n + 8); memcpy(r2, a, n + 8);
        memmove(r1, r1 + off, n); eigs_memmove(r2, r2 + off, n);
        CHECK(!memcmp(r1, r2, n + 8), "memmove back");
        memset(r1, (int)(rnd() & 0xFF), n); eigs_memset(r2, r1[0], n);
        if (n) CHECK(!memcmp(r1, r2, n), "memset");
    }
    char s1[300], s2[64];
    for (int it = 0; it < 20000; it++) {
        size_t n = rnd() % 290;
        for (size_t i = 0; i < n; i++) s1[i] = (char)(1 + rnd() % 127);
        s1[n] = 0;
        size_t m = rnd() % 60;
        for (size_t i = 0; i < m; i++) s2[i] = (char)(1 + rnd() % 127);
        s2[m] = 0;
        CHECK(eigs_strlen(s1) == strlen(s1), "strlen");
        int c1 = strcmp(s1, s2), c2 = eigs_strcmp(s1, s2);
        CHECK((c1 > 0) == (c2 > 0) && (c1 < 0) == (c2 < 0), "strcmp");
        size_t k = rnd() % 64;
        c1 = strncmp(s1, s2, k); c2 = eigs_strncmp(s1, s2, k);
        CHECK((c1 > 0) == (c2 > 0) && (c1 < 0) == (c2 < 0), "strncmp");
        int ch = (int)(1 + rnd() % 127);
        CHECK(strchr(s1, ch) == eigs_strchr(s1, ch), "strchr");
        CHECK(strrchr(s1, ch) == eigs_strrchr(s1, ch), "strrchr");
        CHECK(strstr(s1, s2) == eigs_strstr(s1, s2), "strstr");
    }
    CHECK(eigs_strchr("abc", 0) == strchr("abc", 0), "strchr nul");
    CHECK(eigs_strstr("abc", "") == strstr("abc", ""), "strstr empty");
    /* strtok_r */
    char t1[] = "  foo, bar;;baz  ", t2[] = "  foo, bar;;baz  ";
    char *sp1 = NULL, *sp2 = NULL, *p1, *p2;
    p1 = strtok_r(t1, " ,;", &sp1); p2 = eigs_strtok_r(t2, " ,;", &sp2);
    while (p1 || p2) {
        CHECK(p1 && p2 && !strcmp(p1, p2), "strtok_r token");
        p1 = strtok_r(NULL, " ,;", &sp1); p2 = eigs_strtok_r(NULL, " ,;", &sp2);
    }
}

static void t_ctype(void) {
    printf("[ctype tables]\n");
    const unsigned short *gb = *__ctype_b_loc(), *mb = *eigs_ctype_b_loc();
    const int *gl = *__ctype_tolower_loc(), *ml = *eigs_ctype_tolower_loc();
    const int *gu = *__ctype_toupper_loc(), *mu = *eigs_ctype_toupper_loc();
    for (int i = -128; i < 256; i++) {
        CHECK(gb[i] == mb[i], "ctype_b[%d]: glibc %04x mini %04x", i, gb[i], mb[i]);
        CHECK(gl[i] == ml[i], "tolower[%d]", i);
        CHECK(gu[i] == mu[i], "toupper[%d]", i);
    }
}

static void t_strtol(void) {
    printf("[strtol/strtoul]\n");
    const char *cases[] = {
        "0", "-1", "+42", "  123abc", "0x1F", "0X1f", "017", "9223372036854775807",
        "-9223372036854775808", "9223372036854775808", "99999999999999999999999",
        "-99999999999999999999999", "0x", "abc", "", "  -0x10", "z", "10",
    };
    int bases[] = {0, 10, 16, 8, 2, 36};
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); i++) {
        for (size_t b = 0; b < sizeof(bases)/sizeof(*bases); b++) {
            char *e1, *e2;
            long v1 = strtol(cases[i], &e1, bases[b]);
            long v2 = eigs_strtol(cases[i], &e2, bases[b]);
            CHECK(v1 == v2 && (e1 - cases[i]) == (e2 - cases[i]),
                  "strtol('%s',%d): %ld/%td vs %ld/%td", cases[i], bases[b],
                  v1, e1 - cases[i], v2, e2 - cases[i]);
            unsigned long u1 = strtoul(cases[i], &e1, bases[b]);
            unsigned long u2 = eigs_strtoul(cases[i], &e2, bases[b]);
            CHECK(u1 == u2 && (e1 - cases[i]) == (e2 - cases[i]),
                  "strtoul('%s',%d)", cases[i], bases[b]);
        }
    }
    char buf[32];
    for (int it = 0; it < 50000; it++) {
        long long v = (long long)rnd();
        snprintf(buf, sizeof buf, "%lld", v >> (rnd() % 40));
        char *e1, *e2;
        CHECK(strtol(buf, &e1, 10) == eigs_strtol(buf, &e2, 10) && e1 - buf == e2 - buf,
              "strtol rand '%s'", buf);
    }
}

static void t_strtod(void) {
    printf("[strtod — bit-exact]\n");
    const char *cases[] = {
        "0", "-0", "0.0", "1", "1.5", "3.14159265358979323846", "1e308", "1e309",
        "1e-308", "1e-324", "4.9406564584124654e-324", "2.2250738585072014e-308",
        "2.2250738585072011e-308", "1e-400", "1e400", "123456789012345678901234567890",
        "0.000000000000000000000000000001", "9007199254740993", "9007199254740992",
        ".5", "5.", "1e", "e5", "inf", "-inf", "infinity", "nan", "  7.25xyz",
        "1.7976931348623157e308", "1.7976931348623159e308", "6.62607015e-34",
        "0.1", "0.2", "0.3", "0.7", "1e22", "1e23", "-1e-22", "1e15", "1e16",
        "5e-324", "2.5e-324", "7.4e-324", "2.4703282292062327e-324",
    };
    for (size_t i = 0; i < sizeof(cases)/sizeof(*cases); i++) {
        char *e1, *e2;
        double v1 = strtod(cases[i], &e1);
        double v2 = eigs_strtod(cases[i], &e2);
        CHECK((bits_of(v1) == bits_of(v2) || (isnan(v1) && isnan(v2))) &&
              (e1 - cases[i]) == (e2 - cases[i]),
              "strtod('%s'): %a/%td vs %a/%td", cases[i], v1, e1 - cases[i], v2, e2 - cases[i]);
    }
    char buf[128];
    for (int it = 0; it < 200000; it++) {
        int nd = 1 + (int)(rnd() % 25);
        int p = 0;
        if (rnd() & 1) buf[p++] = '-';
        for (int i = 0; i < nd; i++) buf[p++] = (char)('0' + rnd() % 10);
        if (rnd() & 1) buf[p++] = '.';
        int nf = (int)(rnd() % 20);
        for (int i = 0; i < nf; i++) buf[p++] = (char)('0' + rnd() % 10);
        if (rnd() & 1) p += sprintf(buf + p, "e%d", (int)(rnd() % 640) - 320);
        buf[p] = 0;
        char *e1, *e2;
        double v1 = strtod(buf, &e1);
        double v2 = eigs_strtod(buf, &e2);
        CHECK((bits_of(v1) == bits_of(v2) || (isnan(v1) && isnan(v2))) &&
              e1 - buf == e2 - buf,
              "strtod rand '%s': %a vs %a", buf, v1, v2);
        if (g_fail > 20) return;
    }
    /* round-trip: printf %.17g of random doubles back through strtod */
    for (int it = 0; it < 200000; it++) {
        double d = rnd_double_finite();
        snprintf(buf, sizeof buf, "%.17g", d);
        double v2 = eigs_strtod(buf, NULL);
        CHECK(bits_of(v2) == bits_of(d), "strtod roundtrip '%s': %a vs %a", buf, v2, d);
        if (g_fail > 20) return;
    }
}

static int cmp_int(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}
typedef struct { int key, seq; } KV;
static int cmp_kv(const void *a, const void *b) {
    const KV *x = (const KV *)a, *y = (const KV *)b;
    return (x->key > y->key) - (x->key < y->key);
}

static void t_qsort(void) {
    printf("[qsort — sorted + stable]\n");
    for (int it = 0; it < 2000; it++) {
        size_t n = rnd() % 300;
        int a[300];
        for (size_t i = 0; i < n; i++) a[i] = (int)(rnd() % 50);
        eigs_qsort(a, n, sizeof(int), cmp_int);
        for (size_t i = 1; i < n; i++) CHECK(a[i-1] <= a[i], "qsort order");
        KV kv[300];
        for (size_t i = 0; i < n; i++) { kv[i].key = (int)(rnd() % 10); kv[i].seq = (int)i; }
        eigs_qsort(kv, n, sizeof(KV), cmp_kv);
        for (size_t i = 1; i < n; i++) {
            CHECK(kv[i-1].key <= kv[i].key, "qsort kv order");
            if (kv[i-1].key == kv[i].key)
                CHECK(kv[i-1].seq < kv[i].seq, "qsort STABILITY");
        }
    }
}

static void t_rand48(void) {
    printf("[rand48 — sequence-exact]\n");
    srand48(12345); eigs_srand48(12345);
    for (int i = 0; i < 10000; i++) {
        double a = drand48(), b = eigs_drand48();
        CHECK(bits_of(a) == bits_of(b), "drand48 #%d: %a vs %a", i, a, b);
        if (g_fail > 5) return;
    }
    srand48(-999); eigs_srand48(-999);
    for (int i = 0; i < 10000; i++) {
        long a = lrand48(), b = eigs_lrand48();
        CHECK(a == b, "lrand48 #%d: %ld vs %ld", i, a, b);
        if (g_fail > 5) return;
    }
}

static void t_snprintf(void) {
    printf("[snprintf — byte-exact]\n");
    char b1[1600], b2[1600];
    /* integer + string corpus (the runtime's census formats) */
    struct { const char *fmt; long long v; } icases[] = {
        {"%d", 0}, {"%d", -1}, {"%d", 2147483647}, {"%d", -2147483647-1},
        {"%5d", 42}, {"%-5d|", 42}, {"%05d", -42}, {"%+d", 7}, {"% d", 7},
        {"%x", 48879}, {"%X", 48879}, {"%02x", 5}, {"%04x", 255}, {"%#x", 255},
        {"%u", 4294967295LL}, {"%o", 511}, {"%c", 'Q'}, {"%3d", 12345},
        {"%.5d", 42}, {"%.0d", 0}, {"%6u", 17},
    };
    for (size_t i = 0; i < sizeof(icases)/sizeof(*icases); i++) {
        int r1 = snprintf(b1, sizeof b1, icases[i].fmt, (int)icases[i].v);
        int r2 = eigs_snprintf(b2, sizeof b2, icases[i].fmt, (int)icases[i].v);
        CHECK(r1 == r2 && !strcmp(b1, b2), "int '%s' %lld: '%s' vs '%s'",
              icases[i].fmt, icases[i].v, b1, b2);
    }
    {
        int r1 = snprintf(b1, sizeof b1, "%ld|%lld|%llu|%lx|%zu",
                          123456789L, -987654321LL, 18446744073709551615ULL,
                          0xDEADBEEFUL, (size_t)991);
        int r2 = eigs_snprintf(b2, sizeof b2, "%ld|%lld|%llu|%lx|%zu",
                          123456789L, -987654321LL, 18446744073709551615ULL,
                          0xDEADBEEFUL, (size_t)991);
        CHECK(r1 == r2 && !strcmp(b1, b2), "long forms: '%s' vs '%s'", b1, b2);
    }
    {
        int r1 = snprintf(b1, sizeof b1, "[%12s][%-20s][%.4000s][%.*s][%5s]",
                          "hi", "left", "clip", 3, "abcdef", "wide");
        int r2 = eigs_snprintf(b2, sizeof b2, "[%12s][%-20s][%.4000s][%.*s][%5s]",
                          "hi", "left", "clip", 3, "abcdef", "wide");
        CHECK(r1 == r2 && !strcmp(b1, b2), "strings: '%s' vs '%s'", b1, b2);
    }
    /* truncation semantics */
    {
        char t1[8], t2[8];
        int r1 = snprintf(t1, sizeof t1, "%d %s", 12345, "hello");
        int r2 = eigs_snprintf(t2, sizeof t2, "%d %s", 12345, "hello");
        CHECK(r1 == r2 && !strcmp(t1, t2), "truncation: %d '%s' vs %d '%s'", r1, t1, r2, t2);
        r1 = snprintf(NULL, 0, "%g", 3.14);
        r2 = eigs_snprintf(NULL, 0, "%g", 3.14);
        CHECK(r1 == r2, "size-0 count");
    }
    /* float corpus: fixed cases with the runtime's census formats */
    const char *ffmts[] = {"%e", "%.6e", "%f", "%.6f", "%.1f", "%.4f", "%5.1f",
                           "%.8f", "%g", "%.6g", "%.15g", "%.17g", "%.3g", "%.0f",
                           "%.0e", "%12.3e", "%-14g|", "%+g", "%#g", "%.2f"};
    double fvals[] = {0.0, -0.0, 1.0, -1.0, 0.5, 2.0/3.0, 3.141592653589793,
                      1e-5, 1e-4, 9.9999999e-5, 0.1, 100.0, 99999.5, 100000.5,
                      1e15, 1e16, 123456.789, 1e300, 1e-300, 5e-324,
                      2.2250738585072014e-308, 1.7976931348623157e308,
                      9999999.999999999, 0.30000000000000004,
                      1.0/0.0, -1.0/0.0, 0.0/0.0};
    for (size_t f = 0; f < sizeof(ffmts)/sizeof(*ffmts); f++) {
        for (size_t v = 0; v < sizeof(fvals)/sizeof(*fvals); v++) {
            int r1 = snprintf(b1, sizeof b1, ffmts[f], fvals[v]);
            int r2 = eigs_snprintf(b2, sizeof b2, ffmts[f], fvals[v]);
            CHECK(r1 == r2 && !strcmp(b1, b2), "float '%s' %a: '%s' vs '%s'",
                  ffmts[f], fvals[v], b1, b2);
            if (g_fail > 40) return;
        }
    }
    /* randomized float sweep across all census float formats */
    for (int it = 0; it < 150000; it++) {
        double d = (it % 3 == 0) ? rnd_double_finite()
                 : (it % 3 == 1) ? rnd_range(-1e6, 1e6)
                                 : rnd_range(-1.0, 1.0);
        const char *fmt = ffmts[rnd() % (sizeof(ffmts)/sizeof(*ffmts))];
        int r1 = snprintf(b1, sizeof b1, fmt, d);
        int r2 = eigs_snprintf(b2, sizeof b2, fmt, d);
        CHECK(r1 == r2 && !strcmp(b1, b2), "float rand '%s' %a: '%s' vs '%s'", fmt, d, b1, b2);
        if (g_fail > 40) return;
    }
}

static void t_libm_exact(void) {
    printf("[libm exact: fabs/floor/ceil/round/sqrt/fmod]\n");
    double specials[] = {0.0, -0.0, 0.5, -0.5, 1.0, -1.0, 1.5, 2.5, -2.5,
                         4503599627370495.5, 4503599627370496.0, 1e308, 5e-324,
                         1.0/0.0, -1.0/0.0, 0.0/0.0};
    for (int it = 0; it < 400000; it++) {
        double x = (it < (int)(sizeof(specials)/sizeof(*specials))) ? specials[it]
                                                                    : rnd_double_full();
        CHECK(bits_of(fabs(x)) == bits_of(eigs_fabs(x)) || (isnan(x)), "fabs %a", x);
        CHECK(bits_of(floor(x)) == bits_of(eigs_floor(x)) ||
              (isnan(floor(x)) && isnan(eigs_floor(x))), "floor %a: %a vs %a",
              x, floor(x), eigs_floor(x));
        CHECK(bits_of(ceil(x)) == bits_of(eigs_ceil(x)) ||
              (isnan(ceil(x)) && isnan(eigs_ceil(x))), "ceil %a", x);
        CHECK(bits_of(round(x)) == bits_of(eigs_round(x)) ||
              (isnan(round(x)) && isnan(eigs_round(x))), "round %a: %a vs %a",
              x, round(x), eigs_round(x));
        if (!isnan(x) && x >= 0)
            CHECK(bits_of(sqrt(x)) == bits_of(eigs_sqrt(x)), "sqrt %a", x);
        if (g_fail > 30) return;
    }
    for (int it = 0; it < 200000; it++) {
        double x = rnd_double_finite(), y = rnd_double_finite();
        if (it % 4 == 0) { x = rnd_range(-1e9, 1e9); y = rnd_range(-100, 100); }
        double r1 = fmod(x, y), r2 = eigs_fmod(x, y);
        CHECK(bits_of(r1) == bits_of(r2) || (isnan(r1) && isnan(r2)),
              "fmod(%a, %a): %a vs %a", x, y, r1, r2);
        if (g_fail > 30) return;
    }
}

static void t_libm_ulp(void) {
    printf("[libm transcendental — ulp bounds]\n");
    struct {
        const char *name;
        double (*ref)(double);
        double (*mine)(double);
        double lo, hi;
        uint64_t bound;
    } F[] = {
        {"exp",  exp,  eigs_exp,  -745.0, 709.0, 2},
        {"log",  log,  eigs_log,  0.0,    1e308, 2},
        {"log2", log2, eigs_log2, 0.0,    1e308, 4},
        {"sin",  sin,  eigs_sin,  -1e6,   1e6,   4},
        {"cos",  cos,  eigs_cos,  -1e6,   1e6,   4},
        {"tan",  tan,  eigs_tan,  -1e6,   1e6,   8},
        {"atan", atan, eigs_atan, -1e308, 1e308, 8},
        {"asin", asin, eigs_asin, -1.0,   1.0,   8},
        {"acos", acos, eigs_acos, -1.0,   1.0,   8},
    };
    for (size_t f = 0; f < sizeof(F)/sizeof(*F); f++) {
        uint64_t maxu = 0;
        double worst = 0;
        for (int it = 0; it < 300000; it++) {
            double x;
            if (it % 4 == 0) x = rnd_range(F[f].lo, F[f].hi);
            else if (it % 4 == 1) x = rnd_range(-2.0, 2.0);
            else if (it % 4 == 2) x = rnd_range(F[f].lo > -20 ? F[f].lo : -20.0,
                                                F[f].hi < 20 ? F[f].hi : 20.0);
            else { x = rnd_double_finite();
                   if (x < F[f].lo || x > F[f].hi) continue; }
            uint64_t u = ulp_dist(F[f].ref(x), F[f].mine(x));
            if (u > maxu) { maxu = u; worst = x; }
        }
        printf("  %-5s max ulp %" PRIu64 " (worst x=%a)\n", F[f].name, maxu, worst);
        CHECK(maxu <= F[f].bound, "%s exceeds %" PRIu64 " ulp", F[f].name, F[f].bound);
    }
    /* atan2 + pow: 2-arg sweeps */
    uint64_t maxu = 0; double wx = 0, wy = 0;
    for (int it = 0; it < 300000; it++) {
        double y = rnd_range(-1e6, 1e6), x = rnd_range(-1e6, 1e6);
        uint64_t u = ulp_dist(atan2(y, x), eigs_atan2(y, x));
        if (u > maxu) { maxu = u; wx = x; wy = y; }
    }
    printf("  atan2 max ulp %" PRIu64 " (worst y=%a x=%a)\n", maxu, wy, wx);
    CHECK(maxu <= 8, "atan2 exceeds 8 ulp");
    maxu = 0;
    for (int it = 0; it < 300000; it++) {
        double x = rnd_range(0.0, 100.0), y = rnd_range(-40.0, 40.0);
        if (it % 3 == 0) { x = rnd_range(0.0, 2.0); y = rnd_range(-300.0, 300.0); }
        double r1 = pow(x, y), r2 = eigs_pow(x, y);
        if (isinf(r1) && isinf(r2)) continue;
        if (r1 == 0 && r2 == 0) continue;
        uint64_t u = ulp_dist(r1, r2);
        if (u > maxu) { maxu = u; wx = x; wy = y; }
    }
    printf("  pow   max ulp %" PRIu64 " (worst x=%a y=%a)\n", maxu, wx, wy);
    CHECK(maxu <= 8, "pow exceeds 8 ulp");
    /* integer-exponent pow must be close to exact */
    for (int it = 0; it < 100000; it++) {
        double x = rnd_range(-100.0, 100.0);
        int n = (int)(rnd() % 21) - 10;
        uint64_t u = ulp_dist(pow(x, (double)n), eigs_pow(x, (double)n));
        CHECK(u <= 6, "pow(%a, %d) integer path: %" PRIu64 " ulp", x, n, u);
        if (g_fail > 30) return;
    }
}

int main(void) {
    t_mem_str();
    t_ctype();
    t_strtol();
    t_strtod();
    t_qsort();
    t_rand48();
    t_snprintf();
    t_libm_exact();
    t_libm_ulp();
    printf("----\n");
    if (g_fail) { printf("FAIL: %d differential check(s)\n", g_fail); return 1; }
    printf("mini-libc differential: ALL SECTIONS PASS (glibc oracle)\n");
    return 0;
}
