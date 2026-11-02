/* R2.2: IEEE result/status and real-VM strict arithmetic regression.
 * The historical filename/Make target stay stable for suite variants.
 * Raw rows check payload preservation, including tag-spelling NaNs; the
 * separate slot test owns NaN canonicalization and refcount safety.
 * Strict rows catch real interpreter errors, so expected refusals print no
 * uncaught-error stderr. Leaf rows use the existing scanner and VM call path.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"
#include "trace.h"
#include "vm.h"

static int failed;
static unsigned raw_rows, vm_rows, leaf_rows;

static uint64_t bits(double x) {
    uint64_t out;
    memcpy(&out, &x, sizeof(out));
    return out;
}

static double from_bits(uint64_t x) {
    double out;
    memcpy(&out, &x, sizeof(out));
    return out;
}

static void raw_row(const char *name, double input) {
    const unsigned before = 0x40u;
    unsigned expected = before;
    if (isnan(input)) expected |= EIGS_MATH_INVALID;
    else if (isinf(input)) expected |= EIGS_MATH_OVERFLOW;
    eigs_clear_error();
    g_math_flags = before;
    double result = eigs_math_result_named(input, "ieee-result-test");
    raw_rows++;
    if (bits(result) != bits(input) || g_math_flags != expected || eigs_has_error()) {
        fprintf(stderr, "FAIL: raw %s: input=%016llx output=%016llx flags=%u expected=%u error=%d\n",
                name, (unsigned long long)bits(input), (unsigned long long)bits(result),
                g_math_flags, expected, eigs_has_error());
        failed = 1;
    }
}

static void bind_float(const char *name, double input) {
    EigsValue *value = eigs_value_new_num(input);
    eigs_set_global(name, value);
    eigs_value_release(value);
    if (eigs_has_error()) {
        fprintf(stderr, "FAIL: non-strict binding %s: %s\n", name,
                eigs_last_error_message());
        failed = 1;
        eigs_clear_error();
    }
}

static void vm_bool(const char *name, const char *source, unsigned expected_flags) {
    eigs_clear_error();
    g_math_flags = 0;
    EigsValue *result = eigs_eval_string(source);
    vm_rows++;
    int ok = result && eigs_value_type(result) == EIGS_TYPE_BOOL &&
             eigs_value_as_bool(result) && !eigs_has_error() &&
             g_math_flags == expected_flags;
    if (!ok) {
        const char *error = eigs_last_error_message();
        fprintf(stderr, "FAIL: VM %s: result=%s flags=%u expected=%u error=%s\n",
                name, result ? "present" : "NULL", g_math_flags,
                expected_flags, error ? error : "none");
        failed = 1;
    }
    eigs_value_release(result);
    eigs_clear_error();
}

static void strict_catch(const char *name, const char *expression,
                         unsigned expected_flags) {
    char source[768];
    int n = snprintf(source, sizeof source,
        "ieee_caught is false\n"
        "try:\n"
        "    ieee_unexpected is %s\n"
        "catch err:\n"
        "    ieee_caught is err.kind == \"value\"\n"
        "ieee_caught\n", expression);
    if (n < 0 || (size_t)n >= sizeof source) {
        fprintf(stderr, "FAIL: strict fixture source too long\n");
        failed = 1;
        return;
    }
    vm_bool(name, source, expected_flags);
}

static void leaf_cases(void) {
    /* An earlier underflow is speculative until the later addition succeeds.
     * The non-finite row bails after multiplication and re-executes generically.
     * This checks the real call's result/status; static code review establishes
     * that the speculative evaluator publishes no flags before the bailout.
     */
    EigsValue *defined = eigs_eval_string(
        "define ieee_leaf(a, b, c) as:\n"
        "    return a * b + c\n"
        "true\n");
    if (!defined || eigs_has_error()) {
        fprintf(stderr, "FAIL: define leaf fixture\n");
        failed = 1;
    }
    eigs_value_release(defined);
    eigs_clear_error();
    EigsValue *fn = eigs_get_global("ieee_leaf");
    EigsChunk *chunk = fn && fn->type == VAL_FN && fn->data.fn.body_count == -1
                       ? (EigsChunk *)fn->data.fn.body : NULL;
    trace_history_disable();
    if (!chunk || !chunk->leaf_accessor || g_trace_hist) {
        fprintf(stderr, "FAIL: leaf fixture lacks its scanner/history preconditions\n");
        failed = 1;
    }
    eigs_value_release(fn);
    vm_bool("leaf finite after underflow",
            "(ieee_leaf of [1e-300, 1e-300, 2.0]) == 2.0\n",
            EIGS_MATH_UNDERFLOW);
    leaf_rows++;
    vm_bool("leaf underflow then non-finite bailout",
            "ieee_leaf_result is ieee_leaf of [1e-300, 1e-300, ieee_nan]\n"
            "ieee_leaf_result != ieee_leaf_result\n",
            EIGS_MATH_UNDERFLOW | EIGS_MATH_INVALID);
    leaf_rows++;
}

int main(void) {
    EigsState *state = eigs_open();
    if (!state) return 2;
    eigs_state_set_strict(state, 0);
    static const uint64_t nan_payloads[] = {
        UINT64_C(0x7ff8000000000000), UINT64_C(0x7ff0000000000001),
        UINT64_C(0xfff8000000000000), UINT64_C(0xfff9000000000001),
        UINT64_C(0xfffa000000000005), UINT64_C(0xfffb000000001000),
        UINT64_C(0xfffc000000000000), UINT64_C(0xfffd000000000000),
        UINT64_C(0xfffe000000000000), UINT64_C(0xffff000000000000),
    };
    for (size_t i = 0; i < sizeof nan_payloads / sizeof nan_payloads[0]; i++)
        raw_row("NaN payload", from_bits(nan_payloads[i]));
    raw_row("positive infinity", INFINITY);
    raw_row("negative infinity", -INFINITY);
    raw_row("finite above former positive rail", 1.5e308);
    raw_row("finite below former negative rail", -1.5e308);
    raw_row("positive zero", 0.0);
    raw_row("negative zero", -0.0);
    raw_row("smallest denormal", nextafter(0.0, 1.0));
    raw_row("one", 1.0);

    bind_float("ieee_inf", INFINITY);
    bind_float("ieee_nan", NAN);
    vm_bool("default mixed NaN arithmetic",
            "ieee_default is ieee_nan + 1\n"
            "ieee_default != ieee_default\n", EIGS_MATH_INVALID);
    vm_bool("default finite quotient from infinity operand",
            "(7 / ieee_inf) == 0.0\n", 0);
    leaf_cases();

    eigs_state_set_strict(state, 1);
    strict_catch("strict NEG infinity", "-ieee_inf", EIGS_MATH_OVERFLOW);
    strict_catch("strict NEG NaN", "-ieee_nan", EIGS_MATH_INVALID);
    strict_catch("strict mixed addition", "ieee_inf + 1", EIGS_MATH_OVERFLOW);
    strict_catch("strict mixed subtraction", "1 - ieee_nan", EIGS_MATH_INVALID);
    strict_catch("strict mixed multiplication", "ieee_nan * 2", EIGS_MATH_INVALID);
    strict_catch("strict mixed division", "ieee_inf / 2", EIGS_MATH_OVERFLOW);
    strict_catch("strict mixed floor division", "ieee_inf // 2", EIGS_MATH_OVERFLOW);
    strict_catch("strict mixed modulo", "ieee_nan % 2", EIGS_MATH_INVALID);
    vm_bool("strict finite quotient from infinity operand",
            "(7 / ieee_inf) == 0.0\n", 0);
    vm_bool("strict mixed comparison transports infinity",
            "ieee_inf > 1\n", 0);

    eigs_state_set_strict(state, 0);
    eigs_close(state);
    printf("ieee-result-test: raw=%u vm=%u leaf=%u failures=%d\n",
           raw_rows, vm_rows, leaf_rows, failed);
    return failed ? 1 : 0;
}
