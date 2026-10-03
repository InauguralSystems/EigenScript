/* #1415/#1159: ordinary cold failed-name diagnostics, not network/device tests.
 * The same compile flags and owning objects as the CLI determine membership. */
#include "eigs_embed.h"
#include "eigenscript.h"
#include "builtins_internal.h"
#include "ext_names.h"
#include "env_flag.h"
#include "vm.h"
#include <stdio.h>
#include <string.h>

static int passed, failed, omitted, present;
static void check(int ok, const char *label) {
    if (ok) passed++; else { failed++; printf("FAIL: %s\n", label); }
}
static void succeeds(const char *source, const char *label) {
    EigsValue *v = eigs_eval_string(source);
    check(v && !eigs_has_error(), label);
    if (v) eigs_value_release(v);
    eigs_clear_error();
}
static void missing(const char *name, const char *message) {
    char source[512], expected[256];
    omitted++;
    EigsValue *v = eigs_get_global(name);
    check(v == NULL, "host lookup returns actual omitted binding absence");
    if (v) eigs_value_release(v);
    check(eigs_is_registered_builtin(name), "omitted name retains discovery membership");
    /* Five observer forms and plain reference all resolve the same missing name.
     * Each source has the read at line 2. Error kind, exact message and line
     * must survive all modes, including strict opt-out. */
    const char *forms[] = {"%s", "report of %s", "report_value of %s",
        "trajectory of %s", "observe of %s", "converged of %s"};
    for (unsigned i = 0; i < sizeof(forms)/sizeof(forms[0]); i++) {
        char expression[256];
        snprintf(expression, sizeof(expression), forms[i], name);
        snprintf(source, sizeof(source), "# line control\n%s\n", expression);
        v = eigs_eval_string(source);
        snprintf(expected, sizeof(expected), "Error line 2: %s", message);
        check(!v && eigs_has_error() && eigs_last_error_kind() &&
            strcmp(eigs_last_error_kind(), "value") == 0 &&
            eigs_last_error_line() == 2 &&
            strcmp(eigs_last_error_message(), expected) == 0,
            "missing read has exact capability kind/message/line");
        if (v) eigs_value_release(v);
        eigs_clear_error();
    }
    snprintf(source, sizeof(source),
        "effects is 0\ndefine effect as:\n    effects += 1\n    return 1\n"
        "try:\n    %s of (effect of null)\ncatch caught:\n"
        "    assert of [caught.kind == \"value\", \"caught kind\"]\n"
        "assert of [effects == 0, \"arguments must not execute\"]\n", name);
    succeeds(source, "catchable first-reference failure precedes arguments");
    snprintf(source, sizeof(source),
        "define shadow as:\n    local %s is 17\n    return %s\n"
        "assert of [(shadow of null) == 17, \"local shadow\"]\n", name, name);
    succeeds(source, "lexical shadow wins");
    snprintf(source, sizeof(source),
        "define capture as:\n    local %s is 19\n"
        "    define inner as:\n        return %s\n    return inner\n"
        "reader is capture of null\n"
        "assert of [(reader of null) == 19, \"captured shadow\"]\n", name, name);
    succeeds(source, "captured shadow wins");
    if (omitted == 1) {
        snprintf(source, sizeof(source),
            "hot_binding is 7\ndefine hot_read(flag) as:\n"
            "    if flag:\n        return %s\n    return hot_binding\n"
            "unobserved:\n    for cold_i in range of 64:\n"
            "        assert of [(hot_read of 0) == 7, \"hot successful lookup\"]\n"
            "hot_caught is 0\ntry:\n    hot_read of 1\ncatch caught:\n"
            "    assert of [caught.kind == \"value\", \"hot missing kind\"]\n"
            "    hot_caught is 1\nassert of [hot_caught == 1, \"hot caught\"]\n", name);
        succeeds(source, "hot GET_NAME then controlled missing path");
#if defined(__x86_64__) && !EIGENSCRIPT_FREESTANDING
        if (!eigs_env_flag("EIGS_JIT_OFF")) {
            v = eigs_get_global("hot_read");
            /* Match the VM's explicit bytecode-function sentinel before
             * reading its owned chunk (vm.c DEFINE_FN representation). */
            EigsChunk *chunk = v && v->type == VAL_FN && v->data.fn.body_count == -1
                ? (EigsChunk *)v->data.fn.body : NULL;
            check(chunk && chunk->jit_state == 2 && chunk->jit_code &&
                chunk->exec_count >= 65,
                "hot GET_NAME function owns a compiled native thunk and 65 entries");
            if (v) eigs_value_release(v);
        }
#endif
    }
    /* A host-bound null is successful resolution, not an absent binding. */
    v = eigs_value_new_null(); eigs_set_global(name, v); eigs_value_release(v);
    snprintf(source, sizeof(source), "assert of [%s == null, \"host null\"]\n", name);
    succeeds(source, "host null wins");
}
static void available(const char *name) {
    present++;
    EigsValue *v = eigs_get_global(name);
    check(v != NULL && v->type == VAL_BUILTIN,
          "compiled extension owns an actual builtin binding");
    if (v) eigs_value_release(v);
    check(eigs_is_registered_builtin(name), "present discovery membership");
}
int main(void) {
    (void)missing; (void)available;
    EigsState *st = eigs_open();
    if (!st) return 1;
#define M_HTTP(name, fn) missing(#name, "HTTP capability unavailable; use the server profile");
#define M_DB(name, fn) missing(#name, "database capability unavailable; use the server-db profile");
#define M_NET(name, fn) missing(#name, "network capability unavailable; use the server profile");
#define M_MODEL(name, fn) missing(#name, "model capability unavailable; use the server profile");
#define P(name, fn) available(#name);
#if EIGENSCRIPT_EXT_HTTP
    EIGS_HTTP_BUILTINS(P) EIGS_HTTP_REQUEST_BUILTINS(P)
#else
    EIGS_HTTP_BUILTINS(M_HTTP) EIGS_HTTP_REQUEST_BUILTINS(M_HTTP)
#endif
#if EIGENSCRIPT_EXT_DB
    EIGS_DB_BUILTINS(P)
#else
    EIGS_DB_BUILTINS(M_DB)
#endif
#if EIGENSCRIPT_EXT_NET
    EIGS_NET_BUILTINS(P)
#else
    EIGS_NET_BUILTINS(M_NET)
#endif
#if EIGENSCRIPT_EXT_MODEL
    EIGS_MODEL_BUILTINS(P)
#else
    EIGS_MODEL_BUILTINS(M_MODEL)
#endif
    check(omitted + present == 40, "independent extension population pin");
    check(!eigs_is_registered_builtin("cold_unknown_name"), "ordinary unknown discovery control");
    EigsValue *v = eigs_eval_string("# line control\ncold_unknown_name\n");
    check(!v && eigs_has_error() && eigs_last_error_kind() &&
        strcmp(eigs_last_error_kind(), "undefined_name") == 0 &&
        eigs_last_error_line() == 2 &&
        strcmp(eigs_last_error_message(), "Error line 2: undefined variable 'cold_unknown_name'") == 0,
        "ordinary unknown retains exact kind/message/line");
    if (v) eigs_value_release(v);
    eigs_clear_error();
    succeeds("assert of [print != sqrt, \"builtin identity distinct\"]\n",
        "successful builtin identities remain distinct");
    eigs_close(st);
    printf("missing capability: omitted=%d present=%d checks=%d failed=%d\n",
        omitted, present, passed + failed, failed);
    return failed != 0;
}
