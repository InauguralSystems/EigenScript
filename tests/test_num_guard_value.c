#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"

static int failed;

static uint64_t bits(double x) {
    uint64_t out;
    memcpy(&out, &x, sizeof(out));
    return out;
}

static void check(const char *name, double input) {
    unsigned before = 0x5a5a5a5au;
    g_math_flags = before;
    double quiet = num_guard_value(input);
    if (g_math_flags != before) {
        fprintf(stderr, "FAIL: %s: num_guard_value changed math flags\n", name);
        failed = 1;
    }
    g_math_flags = 0;
    double guarded = num_guard(input);
    if (bits(quiet) != bits(guarded)) {
        fprintf(stderr, "FAIL: %s: value mappings differ\n", name);
        failed = 1;
    }
}

int main(void) {
    EigsState *state = eigs_open();
    if (!state) return 2;
    int strict = g_strict;
    g_strict = 0;
    check("default NaN", NAN);
    check("negative NaN", -NAN);
    check("SLOT_NULL", SLOT_NUM_RAW(slot_null()));
    check("positive infinity", INFINITY);
    check("negative infinity", -INFINITY);
    check("positive maximum", EIGS_NUM_MAX);
    check("negative maximum", -EIGS_NUM_MAX);
    check("above positive maximum", nextafter(EIGS_NUM_MAX, INFINITY));
    check("below negative maximum", nextafter(-EIGS_NUM_MAX, -INFINITY));
    check("negative zero", -0.0);
    check("smallest denormal", nextafter(0.0, 1.0));
    check("one", 1.0);
    g_strict = strict;
    eigs_close(state);
    if (failed) return 1;
    puts("num_guard_value: all mappings pass");
    return 0;
}
