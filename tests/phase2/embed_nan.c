/* #1758 R2.4: every DOUBLE crossing the public embedding API is canonical.
 * Call the real API. Trusted C inspection of owned Value storage separates
 * ingress canonicalization from an egress-only fix; raw valid runtime boxes
 * and raw buffer cells separately exercise egress without changing storage.
 * No slot tags/pointers are forged: buffer cells are intentionally raw f64
 * storage (N12), and a boxed VAL_FLOAT may hold any IEEE NaN bits. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"

#define CANON_NAN UINT64_C(0x7ff8000000000000)
static unsigned checks, failures, cases, callback_calls, arithmetic_cases, constructor_cases;
static uint64_t callback_payload, callback_argument;

static double from_bits(uint64_t bits) {
    double result;
    memcpy(&result, &bits, sizeof result);
    return result;
}

static uint64_t double_bits(double value) {
    uint64_t result;
    memcpy(&result, &value, sizeof result);
    return result;
}

/* Independent expected bits, without a floating comparison that could quiet
 * a signaling NaN or depend on the host's floating environment. */
static uint64_t canonical_bits(uint64_t bits) {
    return (bits & UINT64_C(0x7fffffffffffffff)) > UINT64_C(0x7ff0000000000000)
        ? CANON_NAN : bits;
}

static void check(int ok, const char *label, uint64_t input, int strict) {
    checks++;
    if (!ok) {
        failures++;
        printf("embed-nan: FAIL %s input=%016llx strict=%d\n", label,
               (unsigned long long)input, strict);
    }
}

static void check_bits(uint64_t got, uint64_t want, const char *label,
                       uint64_t input, int strict) {
    checks++;
    if (got != want) {
        failures++;
        printf("embed-nan: FAIL %s input=%016llx strict=%d got=%016llx want=%016llx\n",
               label, (unsigned long long)input, strict,
               (unsigned long long)got, (unsigned long long)want);
    }
}

static uint64_t stored_num_bits(EigsValue *value) {
    return value && value->type == VAL_FLOAT ? double_bits(VAL_F64_RAW(value)) : 0;
}

static void clean_flags(const char *label, uint64_t input, int strict) {
    check(!eigs_has_error() && g_math_flags == EIGS_MATH_UNDERFLOW,
          label, input, strict);
}

static void boundary_case(uint64_t input, int strict) {
    uint64_t want = canonical_bits(input);
    eigs_clear_error();
    g_math_flags = EIGS_MATH_UNDERFLOW;
    EigsValue *number = eigs_value_new_num(from_bits(input));
    check(number && number->type == VAL_FLOAT, "new_num returns float", input, strict);
    check_bits(stored_num_bits(number), want, "new_num ingress storage", input, strict);
    clean_flags("new_num no error or math flags", input, strict);

    check_bits(double_bits(eigs_value_as_num(number)), want,
               "as_num after new_num", input, strict);
    clean_flags("as_num no error or math flags", input, strict);

    EigsValue *buffer = eigs_value_new_buffer(1);
    check(buffer && buffer->type == VAL_BUFFER, "new_buffer returns buffer", input, strict);
    if (!buffer || buffer->type != VAL_BUFFER) {
        eigs_value_release(buffer);
        eigs_value_release(number);
        return;
    }
    eigs_value_buffer_set(buffer, 0, from_bits(input));
    check_bits(double_bits(buffer->data.buffer.data[0]), want,
               "buffer_set ingress storage", input, strict);
    clean_flags("buffer_set no error or math flags", input, strict);
    check_bits(double_bits(eigs_value_buffer_get(buffer, 0)), want,
               "buffer_get after buffer_set", input, strict);
    clean_flags("buffer_get no error or math flags", input, strict);

    /* Egress must work independently of the public input constructor. These
     * are valid runtime data, not induced faults: float Values are boxed,
     * and buffers intentionally retain arbitrary double payloads (N12). */
    EigsValue *raw_number = make_float(from_bits(input));
    check_bits(double_bits(eigs_value_as_num(raw_number)), want,
               "as_num raw runtime box egress", input, strict);
    check_bits(stored_num_bits(raw_number), input,
               "as_num does not rewrite runtime box", input, strict);
    clean_flags("raw as_num no error or math flags", input, strict);
    eigs_value_release(raw_number);

    memcpy(&buffer->data.buffer.data[0], &input, sizeof input);
    check_bits(double_bits(eigs_value_buffer_get(buffer, 0)), want,
               "buffer_get raw runtime cell egress", input, strict);
    check_bits(double_bits(buffer->data.buffer.data[0]), input,
               "buffer_get preserves raw runtime cell", input, strict);
    clean_flags("raw buffer_get no error or math flags", input, strict);

    /* Opaque Value handles in globals/containers do not add double APIs.
     * Their actual storage and getters must still expose only canonical
     * floats; retain/release ownership is exercised on every path. */
    eigs_set_global("r24_embed_number", number);
    EigsValue *got = eigs_get_global("r24_embed_number");
    check(got && got->type == VAL_FLOAT, "global returns float", input, strict);
    check_bits(stored_num_bits(got), want, "global canonical storage", input, strict);
    eigs_value_release(got);

    EigsValue *list = eigs_value_new_list(1);
    eigs_value_list_append(list, number);
    got = eigs_value_list_get(list, 0);
    check(got && got->type == VAL_FLOAT, "list returns float", input, strict);
    check_bits(stored_num_bits(got), want, "list canonical storage", input, strict);
    eigs_value_release(got);
    eigs_value_release(list);

    EigsValue *dict = eigs_value_new_dict(1);
    eigs_value_dict_set(dict, "number", number);
    got = eigs_value_dict_get(dict, "number");
    check(got && got->type == VAL_FLOAT, "dict returns float", input, strict);
    check_bits(stored_num_bits(got), want, "dict canonical storage", input, strict);
    eigs_value_release(got);
    eigs_value_release(dict);
    check(!eigs_has_error(), "global/list/dict transports leave no error", input, strict);

    eigs_value_release(buffer);
    eigs_value_release(number);
    cases++;
}

static EigsValue *host_nan(EigsValue *argument) {
    callback_calls++;
    callback_argument = double_bits(eigs_value_as_num(argument));
    return eigs_value_new_num(from_bits(callback_payload));
}

static void callback_case(uint64_t input) {
    eigs_clear_error();
    callback_payload = input;
    unsigned before = callback_calls;
    EigsValue *result = eigs_eval_string("return r24_embed_nan of (0.0 / 0.0)\n");
    check(result && !eigs_has_error(), "callback eval completed", input, 0);
    check(callback_calls == before + 1, "callback execution witness", input, 0);
    check_bits(callback_argument, CANON_NAN, "callback argument egress", input, 0);
    check_bits(stored_num_bits(result), canonical_bits(input),
               "callback return reaches canonical result", input, 0);
    eigs_value_release(result);
    eigs_clear_error();
}

/* A getter that canonicalizes its answer cannot prove that a language
 * arithmetic producer stored a canonical NaN. Inspect the actual counted
 * result/global Value instead. These ordinary regression cases complement
 * the public C-boundary rows above; they use no f64_bits/as_num oracle. */
static void arithmetic_storage_cases(void) {
    static const struct {
        const char *name, *source, *binding, *function;
        int leaf;
    } programs[] = {
        {"inline_div", "return 0.0 / 0.0\n", NULL, NULL, 0},
        {"module_div",
         "r24_embed_div_result is 0.0 / 0.0\nreturn r24_embed_div_result\n",
         "r24_embed_div_result", NULL, 0},
        {"function_sub",
         "define r24_embed_sub_fn(a) as:\n"
         "    local t is a - a\n"
         "    return t\n"
         "r24_embed_fn_result is r24_embed_sub_fn of (1e308 * 10.0)\n"
         "return r24_embed_fn_result\n",
         "r24_embed_fn_result", "r24_embed_sub_fn", 0},
        {"leaf_sub",
         "define r24_embed_sub_leaf(a, b) as:\n"
         "    return a - b\n"
         "r24_embed_leaf_result is r24_embed_sub_leaf of [1e308 * 10.0, 1e308 * 10.0]\n"
         "return r24_embed_leaf_result\n",
         "r24_embed_leaf_result", "r24_embed_sub_leaf", 1},
    };
    for (size_t i = 0; i < sizeof programs / sizeof programs[0]; i++) {
        eigs_clear_error();
        EigsValue *result = eigs_eval_string(programs[i].source);
        char label[96];
        snprintf(label, sizeof label, "%s eval returned float", programs[i].name);
        check(result && result->type == VAL_FLOAT && !eigs_has_error(), label, 0, 0);
        snprintf(label, sizeof label, "%s physical result bits", programs[i].name);
        check_bits(stored_num_bits(result), CANON_NAN, label, 0, 0);
        eigs_value_release(result);
        if (programs[i].binding) {
            EigsValue *stored = eigs_get_global(programs[i].binding);
            snprintf(label, sizeof label, "%s global returned float", programs[i].name);
            check(stored && stored->type == VAL_FLOAT && !eigs_has_error(), label, 0, 0);
            snprintf(label, sizeof label, "%s physical global bits", programs[i].name);
            check_bits(stored_num_bits(stored), CANON_NAN, label, 0, 0);
            eigs_value_release(stored);
        }
        if (programs[i].function) {
            EigsValue *fn = eigs_get_global(programs[i].function);
            EigsChunk *chunk = fn && fn->type == VAL_FN && fn->data.fn.body_count == -1
                ? (EigsChunk *)fn->data.fn.body : NULL;
            /* These cases are called once. The generic function body has
             * one real entry; a successful frameless leaf has none. This
             * is the existing execution counter, not a new test seam. */
            int witnessed = chunk && (programs[i].leaf
                ? chunk->leaf_accessor && chunk->exec_count == 0
                : !chunk->leaf_accessor && chunk->exec_count == 1);
            snprintf(label, sizeof label, "%s actual call witness", programs[i].name);
            check(witnessed, label, 0, 0);
            eigs_value_release(fn);
        }
        arithmetic_cases++;
        eigs_clear_error();
    }
}

/* f64_bits is itself a canonical boundary, so its answer cannot establish
 * what the new constructor stored. Inspect counted results independently. */
static void constructor_storage_cases(void) {
    static const char *programs[] = {
        "try:\n    return f64_from_bits of 0x7FF0000000000001\ncatch e:\n    return null\n",
        "try:\n    return f64_from_bits of 0xFFFB000000001000\ncatch e:\n    return null\n",
    };
    for (size_t i = 0; i < sizeof programs / sizeof programs[0]; i++) {
        eigs_clear_error();
        EigsValue *result = eigs_eval_string(programs[i]);
        check(result && result->type == VAL_FLOAT && !eigs_has_error(),
              "f64_from_bits returns a float", (uint64_t)i, 0);
        check_bits(stored_num_bits(result), CANON_NAN,
                   "f64_from_bits physical result bits", (uint64_t)i, 0);
        eigs_value_release(result);
        constructor_cases++;
    }
}

int main(void) {
    static const uint64_t inputs[] = {
        UINT64_C(0x3ff8000000000000), UINT64_C(0xbff8000000000000),
        UINT64_C(0x0000000000000000), UINT64_C(0x8000000000000000),
        UINT64_C(0x0000000000000001), UINT64_C(0x8000000000000001),
        UINT64_C(0x7fefffffffffffff), UINT64_C(0xffefffffffffffff),
        UINT64_C(0x7ff0000000000000), UINT64_C(0xfff0000000000000),
        UINT64_C(0x7ff8000000000000), UINT64_C(0x7ff0000000000001),
        UINT64_C(0x7ff8000000000042), UINT64_C(0xfff8000000000042),
        UINT64_C(0xfff0000000000001), UINT64_C(0xfff8000000000000),
        UINT64_C(0xfff9000000000001), UINT64_C(0xfffa000000000005),
        UINT64_C(0xfffb000000001000), UINT64_C(0xffff000000000000),
    };
    EigsState *state = eigs_open();
    if (!state) {
        printf("embed-nan: FAIL open\n");
        return 1;
    }
    for (int strict = 0; strict <= 1; strict++) {
        eigs_state_set_strict(state, strict);
        for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++)
            boundary_case(inputs[i], strict);
    }
    eigs_state_set_strict(state, 0);
    eigs_register_function("r24_embed_nan", host_nan);
    for (size_t i = 0; i < sizeof inputs / sizeof inputs[0]; i++)
        callback_case(inputs[i]);
    arithmetic_storage_cases();
    constructor_storage_cases();
    eigs_value_release(eigs_get_global("r24_embed_number"));
    eigs_clear_error();
    eigs_close(state);
    printf("embed-nan: %s inputs=%zu modes=2 cases=%u callbacks=%u arithmetic=%u constructors=%u checks=%u failures=%u\n",
           failures ? "FAIL" : "PASS", sizeof inputs / sizeof inputs[0],
           cases, callback_calls, arithmetic_cases, constructor_cases, checks, failures);
    return failures ? 1 : 0;
}
