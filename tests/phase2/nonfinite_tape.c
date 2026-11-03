/* R2.5 discriminating companion to base-green N6/T1 MAP invariants.
 * The public rows contain no N returns. This uses the actual host writer and
 * strict replay reader; the second recording must be byte-identical. */
#include "eigenscript.h"
#include "eigs_embed.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static char journal[8192];
static size_t used;
static int overflow;
static void sink(const char *s, size_t n, void *ctx) {
    (void)ctx;
    if (n >= sizeof journal - used) { overflow = 1; return; }
    memcpy(journal + used, s, n); used += n; journal[used] = 0;
}
static uint64_t bits(double d) {
    uint64_t u; memcpy(&u, &d, sizeof u); return u;
}
int main(void) {
    EigsState *st = eigs_open();
    if (!st || !eigs_trace_declare_kind("r25_sensor", EIGS_KIND(EIGS_TYPE_NUM))) return 2;
    const uint64_t patterns[] = {UINT64_C(0x7ff0000000000000),
                                UINT64_C(0xfff0000000000000),
                                UINT64_C(0x7ff8000000000000)};
    char first[sizeof journal];
    size_t first_used = 0;
    for (int pass = 0; pass < 2; pass++) {
        used = 0; journal[0] = 0;
        eigs_set_trace_sink(sink, NULL);
        for (size_t i = 0; i < sizeof patterns / sizeof patterns[0]; i++) {
            double d; memcpy(&d, &patterns[i], sizeof d);
            EigsValue *v = eigs_value_new_num(d);
            eigs_trace_record_nondet("r25_sensor", v);
            eigs_value_release(v);
        }
        eigs_set_trace_sink(NULL, NULL);
        if (overflow) return 2;
        if (!pass) { memcpy(first, journal, used); first_used = used; }
        else if (used != first_used || memcmp(first, journal, used)) return 1;
    }
    if (!strstr(journal, " r25_sensor=inf\n") ||
        !strstr(journal, " r25_sensor=-inf\n") ||
        !strstr(journal, " r25_sensor=nan\n")) return 1;
    puts("N tokens=inf,-inf,nan recordings=2 identical");
    if (!eigs_set_replay_tape(journal, used, 1)) return 1;
    for (size_t i = 0; i < sizeof patterns / sizeof patterns[0]; i++) {
        EigsValue *v = NULL;
        int got = eigs_replay_take("r25_sensor", &v);
        if (!got || !v || v->type != VAL_FLOAT || eigs_has_error() ||
            bits(eigs_value_as_num(v)) != patterns[i]) return 1;
        char *s = value_to_string(v);
        printf("replayed=%s bits=%016llx\n", s, (unsigned long long)bits(eigs_value_as_num(v)));
        free(s); eigs_value_release(v);
    }
    if (!eigs_set_replay_tape(NULL, 0, 0)) return 1;
    eigs_close(st);
    puts("nonfinite-tape: checks=3 failures=0");
    return 0;
}
