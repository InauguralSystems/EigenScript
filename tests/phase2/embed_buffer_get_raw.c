/* R2.4 explicitly amends R1.6z-D1's NaN-payload promise at the C double
 * boundary. Canonical NaN replaces a payload NaN; every non-NaN bit and
 * the no-error/no-math-flags contract remain pinned. The historical test
 * name stays stable for the reader gate's invocation. */
#include "eigenscript_all.c"
static int checks, failures;
static void check(int ok, const char *label) {
    ++checks;
    if (!ok) { ++failures; printf("phase2-embed-buffer: FAIL %s\n", label); }
}
int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 1;
    const uint64_t bits[] = {UINT64_C(0x7ff8000000000000), UINT64_C(0x7ff8000000000042),
        UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000), UINT64_C(0x8000000000000000)};
    const uint64_t want_bits[] = {UINT64_C(0x7ff8000000000000), UINT64_C(0x7ff8000000000000),
        UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000), UINT64_C(0x8000000000000000)};
    for (int strict = 0; strict <= 1; ++strict) {
        g_strict = strict;
        EigsValue *b = eigs_value_new_buffer(5);
        for (int i = 0; i < 5; ++i) {
            double x; memcpy(&x, &bits[i], sizeof x);
            eigs_value_buffer_set(b, i, x);
            g_math_flags = EIGS_MATH_UNDERFLOW;
            double got = eigs_value_buffer_get(b, i);
            check(memcmp(&want_bits[i], &got, sizeof got) == 0, "set/get canonical NaN or exact non-NaN bits");
            check(!eigs_has_error(), "get never raises");
            check(g_math_flags == EIGS_MATH_UNDERFLOW, "get preserves flags");
            eigs_clear_error();
        }
        eigs_value_release(b);
        g_math_flags = 0;
        EigsValue *r = eigs_eval_string("p is buf_from_list of ([1e308])\n"
            "g is buf_from_list of ([1e308])\nsgd_update of [p, g, 1e308]\n"
            "sgd_update of [p, p, 1.0]\np\n");
        check(r && !eigs_has_error(), "program stores a NaN through SGD");
        if (r) {
            double stored = ((Value *)r)->data.buffer.data[0];
            unsigned flags = g_math_flags;
            double got = eigs_value_buffer_get(r, 0);
            uint64_t canonical_nan = UINT64_C(0x7ff8000000000000);
            check(isnan(stored) && memcmp(&canonical_nan, &got, sizeof got) == 0 &&
                  memcmp(&stored, &((Value *)r)->data.buffer.data[0], sizeof stored) == 0,
                  "program NaN returns canonical without rewriting raw storage");
            check(!eigs_has_error() && flags == g_math_flags, "program getter no side effects");
            eigs_value_release(r);
        }
        eigs_clear_error();
    }
    eigs_close(st);
    printf("phase2-embed-buffer: %s checks=%d failures=%d\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
