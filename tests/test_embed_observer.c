/* #1038/#1028: the host observer contract. --direct is intentionally usable
 * with origin/main's runtime: compile with -DEIGS_OBS_BASELINE_ONLY to omit
 * tests of the additive API. No compile_ast/eigs_obs_enable in the direct arm. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"

static int passed, failed;
static void check(int ok, const char *name) {
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
    if (ok) passed++; else failed++;
}
static void emit(EigsChunk *c, uint8_t op, uint16_t arg) {
    chunk_emit(c, op, 1);
    chunk_emit_u16(c, arg, 1);
}
static int constant(EigsChunk *c, Value *v) {
    int idx = chunk_add_constant(c, v);
    val_decref(v);
    return idx;
}
static void direct(void) {
    EigsState *st = eigs_open();
    if (!st) { check(0, "open direct state"); return; }
    Env *env = g_global_env;
    env_set_local_owned(env, "native_x", make_num(100));
    int idx = env->count - 1;
    double x = 100;
    for (int i = 0; i < 12; i++) {
        x *= 0.5;
        env_set_local_owned(env, "native_x", make_num(x));
        observer_slot_update_num(env, idx, x);
    }
    int answer = observer_predicate_at(env, idx, 2 /* improving opcode operand */, 1);
    printf("native improving=%d\n", answer);
    check(answer == 1, "native slot updates observe without compile_ast");

    EigsChunk *c = chunk_new("<assembled-observer>");
    int name = constant(c, make_str("assembled_x"));
    x = 100;
    for (int i = 0; i < 12; i++) {
        x *= 0.5;
        emit(c, OP_CONST, (uint16_t)constant(c, make_num(x)));
        emit(c, OP_SET_NAME, (uint16_t)name);
        emit(c, OP_OBSERVE_NAME_POST, (uint16_t)name);
        chunk_emit(c, OP_POP, 1);
    }
    emit(c, OP_PREDICATE_NAME, 2 /* improving opcode operand */);
    chunk_emit_u16(c, (uint16_t)name, 1);
    chunk_emit(c, OP_RETURN, 1);
    Value *r = vm_execute(c, env);
    printf("assembled improving=%g\n", eigs_value_as_num(r));
    check(r && !eigs_has_error() && eigs_value_as_num(r) == 1,
          "assembled writes and predicate match native improving=1");
    eigs_value_release(r);
    chunk_free(c);
    eigs_close(st);
}

#ifndef EIGS_OBS_BASELINE_ONLY
/* Each assignment changes x last, so both named and bare predicates can be
 * compared with the VM. The final step is still well outside the deadband. */
static const char *series =
    "x is 100\ni is 0\nloop while i < 10:\n"
    "    i is i + 1\n    x is x * 0.5\nx\n";
static void eval_ok(const char *source, const char *name) {
    EigsValue *r = eigs_eval_string(source);
    check(r && !eigs_has_error(), name);
    eigs_value_release(r);
}
static void eval_num(const char *source, double want, const char *name) {
    EigsValue *r = eigs_eval_string(source);
    check(r && !eigs_has_error() && eigs_value_type(r) == EIGS_TYPE_NUM &&
          eigs_value_as_num(r) == want, name);
    eigs_value_release(r);
}
static void gap(const char *source, const char *name) {
    EigsValue *r = eigs_eval_string(source);
    const char *msg = eigs_last_error_message();
    check(!r && eigs_has_error() && msg && strstr(msg, "observer gate") &&
          strstr(msg, "EIGS_OBS_FORCE=1"), name);
    if (msg) printf("diagnostic: %s\n", msg);
    eigs_value_release(r);
}
/* A callback observes bindings created during this very call: it satisfies
 * the isolation promise, but the calling unit has no compiled observer op. */
static EigsValue *host_reader(EigsValue *arg) {
    (void)arg;
    Env *env = env_new(NULL);
    env_set_local_owned(env, "x", make_num(100));
    double x = 100;
    for (int i = 0; i < 12; i++) {
        x *= 0.5;
        env_set_local_owned(env, "x", make_num(x));
        observer_slot_update_num(env, 0, x);
    }
    int answer = observer_predicate_at(env, 0, 2 /* improving */, 1);
    env_decref(env);
    return make_num(answer);
}
static void eval_contract(void) {
    /* A native host can load/compile a module without routing through the
     * eval API. That module's verdict says nothing about the C caller. */
    EigsState *native = eigs_open();
    const char *source = "noise is 42\nnoise\n";
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    EigsChunk *chunk = compile_ast(ast, g_global_env, source);
    EigsValue *value = vm_execute(chunk, g_global_env);
    check(value && !eigs_has_error() && eigs_value_as_num(value) == 42,
          "native host: low-level compiled module executes");
    eigs_value_release(value);
    chunk_free(chunk);
    free_ast(ast);
    free_tokenlist(&tl);
    check(g_obs_needed, "native host: module verdict cannot close recording");
    value = host_reader(NULL);
    check(value && eigs_value_as_num(value) == 1,
          "native host: observations after module compilation remain live");
    eigs_value_release(value);
    eigs_close(native);
    EigsState *st = eigs_open();
    eval_ok(series, "default: first unit records assignments");
    check(g_obs_needed, "default: read-free unit is observed");
    eval_num("improving of x", 1, "default: later unit reads correct history");
    eigs_close(st);

    st = eigs_open();
    eigs_set_eval_observer_isolated(1);
    eval_num("z is 8\nz is 4\nz is 2\nz is 1\nz is 0.5\nimproving of z", 1,
             "opt-in: observer-reading first unit is observed");
    eval_ok(series, "opt-in: read-free unit executes");
    printf("embed obs-gate: %s\n", g_obs_needed ? "observed" : "unobserved");
    check(!g_obs_needed, "opt-in: read-free unit ran unobserved");
    eval_num("independent is 42\nindependent", 42,
             "opt-in: independent read-free next unit executes");
    check(!g_obs_needed, "opt-in: next read-free unit also unobserved");
    gap("improving of x", "opt-in: cross-unit read raises instead of zero");
    gap("report of x", "opt-in: repeated read cannot clear history gap");
    eigs_set_eval_observer_isolated(0);
    gap("improving of x", "disabling opt-in cannot repair lost history");
    eigs_close(st);

    st = eigs_open();
    eigs_set_eval_observer_isolated(1);
    eval_ok("define local_reader(a) as:\n"
            "    local y is 16\n    y is 8\n    y is 4\n"
            "    y is 2\n    y is 1\n    return improving of y\n",
            "retained function: compile reader in first unit");
    eval_num("local_reader of 0", 1,
             "retained function: later read-free call site preserves recording");
    check(g_obs_needed, "retained function: conservative observed verdict");
    eigs_close(st);

    st = eigs_open();
    eigs_register_function("host_reader", host_reader);
    eigs_set_eval_observer_isolated(1);
    eval_num("host_reader of 0", 1,
             "host callback: unseen observer work is recorded");
    check(g_obs_needed, "host callback: registration pins evals observed");
    eigs_close(st);

    st = eigs_open();
    eigs_set_eval_observer_isolated(1);
    eval_ok(series, "late callback: earlier unit ran without a reader");
    eigs_register_function("host_reader", host_reader);
    gap("host_reader of 0", "late callback: registration cannot hide missing history");
    eigs_close(st);

    setenv("EIGS_OBS_FORCE", "1", 1);
    st = eigs_open();
    eigs_set_eval_observer_isolated(1);
    eval_ok(series, "FORCE: first isolated unit records history");
    check(g_obs_needed, "FORCE: read-free unit is observed");
    eval_num("improving of x", 1, "FORCE: cross-unit read has complete history");
    eigs_close(st);
    unsetenv("EIGS_OBS_FORCE");

    st = eigs_open();
    eval_ok(series, "fresh state: opt-in does not leak between states");
    eval_num("improving of x", 1, "fresh state: complete history still available");
    eigs_close(st);
}
#endif
int main(int argc, char **argv) {
    direct();
#ifndef EIGS_OBS_BASELINE_ONLY
    if (!(argc == 2 && strcmp(argv[1], "--direct") == 0)) eval_contract();
#else
    (void)argc; (void)argv;
#endif
    printf("embed observer: %d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}
