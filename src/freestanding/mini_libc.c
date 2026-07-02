/* mini_libc.c — mem/str, ctype tables, strtol/strtoul, stable qsort,
 * rand48, glue. See mini_libc.h for the contracts. Freestanding-safe:
 * no libc calls except malloc/free (the heap HAL root) from strdup and
 * the mergesort scratch buffer. Compiled with -fno-builtin so gcc can't
 * rewrite these loops back into calls to themselves. */
#include "mini_libc.h"

/* The heap root — provided by glibc hosted, by the kernel freestanding. */
extern void *malloc(size_t);
extern void free(void *);

#define EIGS_ERANGE 34

/* ---- mem/str ---- */

void *eigs_memcpy(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    for (size_t i = 0; i < n; i++) d[i] = s[i];
    return dst;
}

void *eigs_memmove(void *dst, const void *src, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d == s || n == 0) return dst;
    if (d < s) {
        for (size_t i = 0; i < n; i++) d[i] = s[i];
    } else {
        for (size_t i = n; i > 0; i--) d[i - 1] = s[i - 1];
    }
    return dst;
}

void *eigs_memset(void *dst, int c, size_t n) {
    unsigned char *d = (unsigned char *)dst;
    for (size_t i = 0; i < n; i++) d[i] = (unsigned char)c;
    return dst;
}

int eigs_memcmp(const void *a, const void *b, size_t n) {
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    for (size_t i = 0; i < n; i++) {
        if (x[i] != y[i]) return (int)x[i] - (int)y[i];
    }
    return 0;
}

size_t eigs_strlen(const char *s) {
    const char *p = s;
    while (*p) p++;
    return (size_t)(p - s);
}

int eigs_strcmp(const char *a, const char *b) {
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int eigs_strncmp(const char *a, const char *b, size_t n) {
    for (size_t i = 0; i < n; i++) {
        unsigned char ca = (unsigned char)a[i], cb = (unsigned char)b[i];
        if (ca != cb) return (int)ca - (int)cb;
        if (ca == 0) return 0;
    }
    return 0;
}

char *eigs_strchr(const char *s, int c) {
    char ch = (char)c;
    for (;; s++) {
        if (*s == ch) return (char *)s;
        if (*s == 0) return NULL;
    }
}

char *eigs_strrchr(const char *s, int c) {
    char ch = (char)c;
    const char *found = NULL;
    for (;; s++) {
        if (*s == ch) found = s;
        if (*s == 0) return (char *)found;
    }
}

char *eigs_strstr(const char *hay, const char *needle) {
    if (!needle[0]) return (char *)hay;
    size_t nlen = eigs_strlen(needle);
    for (; *hay; hay++) {
        if (*hay == needle[0] && eigs_strncmp(hay, needle, nlen) == 0)
            return (char *)hay;
    }
    return NULL;
}

char *eigs_strncpy(char *dst, const char *src, size_t n) {
    size_t i = 0;
    for (; i < n && src[i]; i++) dst[i] = src[i];
    for (; i < n; i++) dst[i] = 0;
    return dst;
}

char *eigs_strdup(const char *s) {
    size_t n = eigs_strlen(s) + 1;
    char *p = (char *)malloc(n);
    if (!p) return NULL;
    return (char *)eigs_memcpy(p, s, n);
}

char *eigs_strtok_r(char *str, const char *delim, char **saveptr) {
    char *s = str ? str : *saveptr;
    if (!s) return NULL;
    while (*s && eigs_strchr(delim, *s)) s++;          /* skip leading delims */
    if (!*s) { *saveptr = NULL; return NULL; }
    char *tok = s;
    while (*s && !eigs_strchr(delim, *s)) s++;
    if (*s) { *s = 0; *saveptr = s + 1; }
    else    { *saveptr = NULL; }
    return tok;
}

const char *eigs_strerror(int errnum) {
    switch (errnum) {
    case 0:           return "Success";
    case EIGS_ERANGE: return "Numerical result out of range";
    default:          return "Unknown error";
    }
}

/* ---- ctype: glibc-ABI tables for the C locale (ASCII) ----
 *
 * glibc's isalpha()/tolower() macros index the arrays returned by
 * __ctype_b_loc()/__ctype_tolower_loc() with values in [-128, 255].
 * The flag bit layout is a fixed glibc ABI (bits/types.h _ISbit): for a
 * little-endian target, _ISupper=0x0100 _ISlower=0x0200 _ISalpha=0x0400
 * _ISdigit=0x0800 _ISxdigit=0x1000 _ISspace=0x2000 _ISprint=0x4000
 * _ISgraph=0x8000 _ISblank=0x0001 _IScntrl=0x0002 _ISpunct=0x0004
 * _ISalnum=0x0008. The differential harness asserts our tables equal
 * glibc's for every index, so an ABI mismatch cannot land silently. */
#define B_UPPER  0x0100
#define B_LOWER  0x0200
#define B_ALPHA  0x0400
#define B_DIGIT  0x0800
#define B_XDIGIT 0x1000
#define B_SPACE  0x2000
#define B_PRINT  0x4000
#define B_GRAPH  0x8000
#define B_BLANK  0x0001
#define B_CNTRL  0x0002
#define B_PUNCT  0x0004
#define B_ALNUM  0x0008

static unsigned short g_ctype_b[384];
static int g_ctype_lower[384];
static int g_ctype_upper[384];
static const unsigned short *g_ctype_b_ptr;
static const int *g_ctype_lower_ptr;
static const int *g_ctype_upper_ptr;
static int g_ctype_ready = 0;

static void ctype_init(void) {
    /* Idempotent — a racing double-init writes identical values. */
    for (int i = -128; i < 256; i++) {
        int idx = i + 128;
        int c = i & 0xFF ? i : i;   /* table domain includes EOF-adjacent negatives */
        unsigned short f = 0;
        c = i;
        if (c >= 0 && c < 256) {
            int ch = c;
            if (ch >= 'A' && ch <= 'Z') f |= B_UPPER | B_ALPHA | B_ALNUM;
            if (ch >= 'a' && ch <= 'z') f |= B_LOWER | B_ALPHA | B_ALNUM;
            if (ch >= '0' && ch <= '9') f |= B_DIGIT | B_ALNUM;
            if ((ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'F') ||
                (ch >= 'a' && ch <= 'f')) f |= B_XDIGIT;
            if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\v' ||
                ch == '\f' || ch == '\r') f |= B_SPACE;
            if (ch == ' ' || ch == '\t') f |= B_BLANK;
            if (ch < 32 || ch == 127) f |= B_CNTRL;
            if (ch >= 33 && ch <= 126 && !(f & B_ALNUM)) f |= B_PUNCT;
            if (ch >= 33 && ch <= 126) f |= B_GRAPH;
            if (ch >= 32 && ch <= 126) f |= B_PRINT;
        }
        g_ctype_b[idx] = f;
        /* glibc ABI: negative indices mirror the high chars (i + 256) for
         * signed-char callers, except EOF (-1) which passes through. */
        int lo, up;
        if (c < 0) {
            lo = up = (c == -1) ? -1 : c + 256;
        } else {
            lo = c; up = c;
            if (c >= 'A' && c <= 'Z') lo = c - 'A' + 'a';
            if (c >= 'a' && c <= 'z') up = c - 'a' + 'A';
        }
        g_ctype_lower[idx] = lo;
        g_ctype_upper[idx] = up;
    }
    g_ctype_b_ptr = g_ctype_b + 128;        /* index 0 sits at offset 128 */
    g_ctype_lower_ptr = g_ctype_lower + 128;
    g_ctype_upper_ptr = g_ctype_upper + 128;
    g_ctype_ready = 1;
}

const unsigned short **eigs_ctype_b_loc(void) {
    if (!g_ctype_ready) ctype_init();
    return &g_ctype_b_ptr;
}
const int **eigs_ctype_tolower_loc(void) {
    if (!g_ctype_ready) ctype_init();
    return &g_ctype_lower_ptr;
}
const int **eigs_ctype_toupper_loc(void) {
    if (!g_ctype_ready) ctype_init();
    return &g_ctype_upper_ptr;
}

/* ---- strtol / strtoul ---- */

static int digit_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'z') return c - 'a' + 10;
    if (c >= 'A' && c <= 'Z') return c - 'A' + 10;
    return -1;
}

static int mini_isspace(char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r';
}

unsigned long eigs_strtoul(const char *nptr, char **endptr, int base) {
    const char *s = nptr;
    while (mini_isspace(*s)) s++;
    int neg = 0;
    if (*s == '+' || *s == '-') { neg = (*s == '-'); s++; }
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')
        && digit_val(s[2]) >= 0 && digit_val(s[2]) < 16) {
        s += 2;
        base = 16;
    } else if (base == 0) {
        base = (s[0] == '0') ? 8 : 10;
    }
    unsigned long acc = 0;
    int any = 0, overflow = 0;
    const unsigned long cutoff = (unsigned long)-1 / (unsigned long)base;
    const int cutlim = (int)((unsigned long)-1 % (unsigned long)base);
    for (;; s++) {
        int d = digit_val(*s);
        if (d < 0 || d >= base) break;
        any = 1;
        if (acc > cutoff || (acc == cutoff && d > cutlim)) overflow = 1;
        else acc = acc * (unsigned long)base + (unsigned long)d;
    }
    if (endptr) *endptr = (char *)(any ? s : nptr);
    if (overflow) {
        *eigs_errno_location() = EIGS_ERANGE;
        return (unsigned long)-1;
    }
    return neg ? (0UL - acc) : acc;   /* unsigned negation: defined for all acc */
}

long eigs_strtol(const char *nptr, char **endptr, int base) {
    const char *s = nptr;
    while (mini_isspace(*s)) s++;
    int neg = 0;
    if (*s == '+' || *s == '-') { neg = (*s == '-'); s++; }
    if ((base == 0 || base == 16) && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')
        && digit_val(s[2]) >= 0 && digit_val(s[2]) < 16) {
        s += 2;
        base = 16;
    } else if (base == 0) {
        base = (s[0] == '0') ? 8 : 10;
    }
    const unsigned long lmax = (unsigned long)(-(unsigned long)(-9223372036854775807L - 1));
    unsigned long limit = neg ? lmax : 9223372036854775807UL;
    unsigned long acc = 0;
    int any = 0, overflow = 0;
    for (;; s++) {
        int d = digit_val(*s);
        if (d < 0 || d >= base) break;
        any = 1;
        if (acc > (limit - (unsigned long)d) / (unsigned long)base) overflow = 1;
        else acc = acc * (unsigned long)base + (unsigned long)d;
    }
    if (endptr) *endptr = (char *)(any ? s : nptr);
    if (overflow) {
        *eigs_errno_location() = EIGS_ERANGE;
        return neg ? (-9223372036854775807L - 1) : 9223372036854775807L;
    }
    if (neg) {
        if (acc >= 9223372036854775808UL) return -9223372036854775807L - 1;
        return -(long)acc;
    }
    return (long)acc;
}

/* ---- stable mergesort qsort ----
 * Deterministic tie order (equal elements keep input order) so a sort
 * driven by an EigenScript comparator gives identical output hosted and
 * freestanding. Falls back to in-place insertion sort (also stable) if
 * the scratch allocation fails. */

static void insertion_sort(unsigned char *base, size_t n, size_t size,
                           int (*cmp)(const void *, const void *),
                           unsigned char *tmp) {
    for (size_t i = 1; i < n; i++) {
        size_t j = i;
        eigs_memcpy(tmp, base + i * size, size);
        while (j > 0 && cmp(base + (j - 1) * size, tmp) > 0) {
            eigs_memcpy(base + j * size, base + (j - 1) * size, size);
            j--;
        }
        eigs_memcpy(base + j * size, tmp, size);
    }
}

void eigs_qsort(void *vbase, size_t nmemb, size_t size,
                int (*cmp)(const void *, const void *)) {
    if (nmemb < 2 || size == 0) return;
    unsigned char *base = (unsigned char *)vbase;
    unsigned char *scratch = (unsigned char *)malloc(nmemb * size);
    if (!scratch) {
        unsigned char small[256];
        if (size <= sizeof(small)) insertion_sort(base, nmemb, size, cmp, small);
        return;
    }
    /* Bottom-up merge sort, ping-ponging between base and scratch. */
    unsigned char *src = base, *dst = scratch;
    for (size_t width = 1; width < nmemb; width *= 2) {
        for (size_t lo = 0; lo < nmemb; lo += 2 * width) {
            size_t mid = lo + width < nmemb ? lo + width : nmemb;
            size_t hi  = lo + 2 * width < nmemb ? lo + 2 * width : nmemb;
            size_t i = lo, j = mid, k = lo;
            while (i < mid && j < hi) {
                if (cmp(src + j * size, src + i * size) < 0) {
                    eigs_memcpy(dst + k * size, src + j * size, size); j++;
                } else {
                    eigs_memcpy(dst + k * size, src + i * size, size); i++;
                }
                k++;
            }
            while (i < mid) { eigs_memcpy(dst + k * size, src + i * size, size); i++; k++; }
            while (j < hi)  { eigs_memcpy(dst + k * size, src + j * size, size); j++; k++; }
        }
        unsigned char *t = src; src = dst; dst = t;
    }
    if (src != base) eigs_memcpy(base, src, nmemb * size);
    free(scratch);
}

/* ---- PRNG ----
 * drand48/lrand48/srand48 implement the POSIX-specified LCG exactly
 * (X' = (0x5DEECE66D*X + 0xB) mod 2^48) — the harness asserts sequence
 * equality with glibc. rand/srand/random are a documented divergence:
 * a SplitMix64-based generator, NOT glibc's additive generator (rand is
 * an entropy source, not a reproducibility surface — cross-profile
 * reproducibility rides srand48/drand48 and the trace/replay tape). */

static unsigned long long g_x48 = 0x1234ABCD330EULL;   /* POSIX initial */

static unsigned long long x48_step(void) {
    g_x48 = (0x5DEECE66DULL * g_x48 + 0xBULL) & 0xFFFFFFFFFFFFULL;
    return g_x48;
}

double eigs_drand48(void) {
    return (double)x48_step() / 281474976710656.0;   /* 2^48 */
}

long eigs_lrand48(void) {
    return (long)(x48_step() >> 17);
}

void eigs_srand48(long seedval) {
    g_x48 = (((unsigned long long)(unsigned int)seedval) << 16) | 0x330EULL;
}

static unsigned long long g_rand_state = 0x9E3779B97F4A7C15ULL;

static unsigned long long splitmix64(void) {
    unsigned long long z = (g_rand_state += 0x9E3779B97F4A7C15ULL);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
    return z ^ (z >> 31);
}

int eigs_rand(void) { return (int)(splitmix64() & 0x7FFFFFFF); }
void eigs_srand(unsigned seed) { g_rand_state = seed ? seed : 1; }
long eigs_random(void) { return (long)(splitmix64() & 0x7FFFFFFF); }

/* ---- glue ---- */

static int g_errno = 0;
int *eigs_errno_location(void) { return &g_errno; }

/* No environment on bare metal (yet — a kernel config table can back
 * this later). NULL means every EIGS_* toggle takes its default. */
char *eigs_getenv(const char *name) { (void)name; return NULL; }

int eigs_atexit(void (*fn)(void)) { (void)fn; return 0; }

#if EIGS_MINI_STANDARD_NAMES
void  *memcpy(void *, const void *, size_t) __attribute__((alias("eigs_memcpy")));
void  *memmove(void *, const void *, size_t) __attribute__((alias("eigs_memmove")));
void  *memset(void *, int, size_t) __attribute__((alias("eigs_memset")));
int    memcmp(const void *, const void *, size_t) __attribute__((alias("eigs_memcmp")));
size_t strlen(const char *) __attribute__((alias("eigs_strlen")));
int    strcmp(const char *, const char *) __attribute__((alias("eigs_strcmp")));
int    strncmp(const char *, const char *, size_t) __attribute__((alias("eigs_strncmp")));
char  *strchr(const char *, int) __attribute__((alias("eigs_strchr")));
char  *strrchr(const char *, int) __attribute__((alias("eigs_strrchr")));
char  *strstr(const char *, const char *) __attribute__((alias("eigs_strstr")));
char  *strncpy(char *, const char *, size_t) __attribute__((alias("eigs_strncpy")));
char  *strdup(const char *) __attribute__((alias("eigs_strdup")));
char  *strtok_r(char *, const char *, char **) __attribute__((alias("eigs_strtok_r")));
const char *strerror(int) __attribute__((alias("eigs_strerror")));
const unsigned short **__ctype_b_loc(void) __attribute__((alias("eigs_ctype_b_loc")));
const int **__ctype_tolower_loc(void) __attribute__((alias("eigs_ctype_tolower_loc")));
const int **__ctype_toupper_loc(void) __attribute__((alias("eigs_ctype_toupper_loc")));
long          strtol(const char *, char **, int) __attribute__((alias("eigs_strtol")));
unsigned long strtoul(const char *, char **, int) __attribute__((alias("eigs_strtoul")));
void qsort(void *, size_t, size_t, int (*)(const void *, const void *)) __attribute__((alias("eigs_qsort")));
double eigs_drand48(void);
double drand48(void) __attribute__((alias("eigs_drand48")));
long   lrand48(void) __attribute__((alias("eigs_lrand48")));
void   srand48(long) __attribute__((alias("eigs_srand48")));
int    rand(void) __attribute__((alias("eigs_rand")));
void   srand(unsigned) __attribute__((alias("eigs_srand")));
long   random(void) __attribute__((alias("eigs_random")));
int   *__errno_location(void) __attribute__((alias("eigs_errno_location")));
char  *getenv(const char *) __attribute__((alias("eigs_getenv")));
int    atexit(void (*)(void)) __attribute__((alias("eigs_atexit")));
#endif /* EIGS_MINI_STANDARD_NAMES */
