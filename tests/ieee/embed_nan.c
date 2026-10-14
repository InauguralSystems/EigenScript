/* #1746 Phase 1 (ieee build only): the embed API hands a C host the canonical
 * NaN (bits 0x7FF8000000000000, printf "nan"), and eigs_value_as_num of a bool
 * is 0.0 with a pending `type` error, not a NaN. Built and run by
 * tools/ieee_rows.sh against the ieee objects. Prints `EMBED <n> passed, <m> failed`. */
#include "eigs_embed.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
static int pass = 0, fail = 0;
#define CHECK(c, what) do { if (c) pass++; else { fail++; printf("FAIL %s\n", what); } } while (0)
static uint64_t bits(double d) { uint64_t u; memcpy(&u, &d, 8); return u; }
int main(void) {
    EigsState *st = eigs_open();
    if (!st) { printf("FAIL eigs_open\nEMBED 0 passed, 1 failed\n"); return 1; }
    EigsValue *r = eigs_eval_string("x is 0 / 0\nb is buffer of 1\nb[0] is 0 / 0\n");
    if (r) eigs_value_release(r);
    CHECK(!eigs_has_error(), "setup ran");
    EigsValue *x = eigs_get_global("x");
    double d = x ? eigs_value_as_num(x) : 0.0;
    char buf[32]; snprintf(buf, sizeof buf, "%g", d);
    CHECK(bits(d) == 0x7FF8000000000000ULL, "get_global NaN has canonical bits");
    CHECK(strcmp(buf, "nan") == 0, "a C host prints the global NaN as nan");
    if (x) eigs_value_release(x);
    EigsValue *b = eigs_get_global("b");
    double e = b ? eigs_value_buffer_get(b, 0) : 0.0;
    CHECK(bits(e) == 0x7FF8000000000000ULL, "buffer_get NaN has canonical bits");
    if (b) eigs_value_release(b);
    EigsValue *t = eigs_eval_string("5 > 3");
    double tv = t ? eigs_value_as_num(t) : 1.0;
    CHECK(tv == 0.0 && !isnan(tv), "as_num of a bool is 0.0, not NaN");
    CHECK(eigs_has_error() && eigs_last_error_kind() && strcmp(eigs_last_error_kind(), "type_mismatch") == 0,
          "as_num of a bool leaves a pending type_mismatch error");
    eigs_clear_error();
    if (t) eigs_value_release(t);
    eigs_close(st);
    printf("EMBED %d passed, %d failed\n", pass, fail);
    return fail != 0;
}
