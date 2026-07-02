/*
 * mini_libc.h — the write-once portable mini-libc/libm for the
 * freestanding profile (docs/FREESTANDING.md).
 *
 * Every function is defined with an eigs_ prefix so the hosted
 * differential harness (tests/freestanding_libc_diff.c) can link them
 * side by side with glibc and compare — glibc is the oracle. A
 * freestanding link compiles the same objects with
 * -DEIGS_MINI_STANDARD_NAMES=1, which adds standard-name aliases so the
 * runtime's unresolved imports land here.
 *
 * Deliberately NOT here (kernel-owed HAL roots): the heap
 * (malloc/calloc/realloc/free over page_alloc), console I/O
 * (printf/fprintf/fputs/putc/fflush/stdout/stderr over console_write),
 * threads (pthread_* over the scheduler roots), clock_gettime/usleep,
 * exit/_exit/abort/halt.
 *
 * Accuracy contracts (enforced by the differential harness):
 *   - mem/str/ctype/strtol/strtoul/qsort/rand48: exact (bit/byte equal)
 *   - strtod: correctly rounded (bit-equal to glibc)
 *   - snprintf/vsnprintf %d/%u/%x/%s/%c/%e/%f/%g: byte-equal to glibc
 *     (float conversions ride an exact big-decimal digit engine)
 *   - floor/ceil/round/fabs/sqrt/fmod: exact
 *   - exp/log/log2/pow/sin/cos/tan/asin/acos/atan/atan2: within a few
 *     ulp of glibc (per-function bounds asserted by the harness)
 */
#ifndef EIGS_MINI_LIBC_H
#define EIGS_MINI_LIBC_H

#include <stddef.h>
#include <stdarg.h>

/* ---- mem/str ---- */
void  *eigs_memcpy(void *dst, const void *src, size_t n);
void  *eigs_memmove(void *dst, const void *src, size_t n);
void  *eigs_memset(void *dst, int c, size_t n);
int    eigs_memcmp(const void *a, const void *b, size_t n);
size_t eigs_strlen(const char *s);
int    eigs_strcmp(const char *a, const char *b);
int    eigs_strncmp(const char *a, const char *b, size_t n);
char  *eigs_strchr(const char *s, int c);
char  *eigs_strrchr(const char *s, int c);
char  *eigs_strstr(const char *hay, const char *needle);
char  *eigs_strncpy(char *dst, const char *src, size_t n);
char  *eigs_strdup(const char *s);
char  *eigs_strtok_r(char *str, const char *delim, char **saveptr);
const char *eigs_strerror(int errnum);

/* ---- ctype (glibc-ABI table accessors; C locale, ASCII) ---- */
const unsigned short **eigs_ctype_b_loc(void);
const int **eigs_ctype_tolower_loc(void);
const int **eigs_ctype_toupper_loc(void);

/* ---- conversions ---- */
long          eigs_strtol(const char *nptr, char **endptr, int base);
unsigned long eigs_strtoul(const char *nptr, char **endptr, int base);
double        eigs_strtod(const char *nptr, char **endptr);

/* ---- sort (stable mergesort — deterministic tie order) ---- */
void eigs_qsort(void *base, size_t nmemb, size_t size,
                int (*compar)(const void *, const void *));

/* ---- PRNG ---- */
double eigs_drand48(void);
long   eigs_lrand48(void);
void   eigs_srand48(long seedval);
int    eigs_rand(void);
void   eigs_srand(unsigned seed);
long   eigs_random(void);

/* ---- glue ---- */
int   *eigs_errno_location(void);
char  *eigs_getenv(const char *name);
int    eigs_atexit(void (*fn)(void));

/* ---- formatter (exact big-decimal digit engine underneath) ---- */
int eigs_vsnprintf(char *buf, size_t size, const char *fmt, va_list ap);
int eigs_snprintf(char *buf, size_t size, const char *fmt, ...);

/* ---- libm ---- */
double eigs_fabs(double x);
double eigs_floor(double x);
double eigs_ceil(double x);
double eigs_round(double x);
double eigs_sqrt(double x);
double eigs_fmod(double x, double y);
double eigs_exp(double x);
double eigs_log(double x);
double eigs_log2(double x);
double eigs_pow(double x, double y);
double eigs_sin(double x);
double eigs_cos(double x);
double eigs_tan(double x);
double eigs_asin(double x);
double eigs_acos(double x);
double eigs_atan(double x);
double eigs_atan2(double y, double x);

#endif /* EIGS_MINI_LIBC_H */
