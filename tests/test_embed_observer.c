/* #1038/#1028: the host observer contract. --direct is intentionally usable
 * with origin/main's runtime: compile with -DEIGS_OBS_BASELINE_ONLY to omit
 * tests of the additive API. No compile_ast/eigs_obs_enable in the direct arm.
 * --raw-host also bypasses init_runtime, independently pinning state creation. */
#include <stdio.h>
#include <pthread.h>
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
/* Pin state.c's default independently of the eigs_open/init_runtime pin.
 * No runtime initialization, compilation or explicit arming on this path. */
static void raw_host(void) {
    EigsState *st = eigs_state_new();
    if (!st || !eigs_thread_attach(st)) {
        check(0, "raw host: attach state");
        eigs_state_destroy(st);
        return;
    }
    Env *env = env_new(NULL);
    env_set_local_owned(env, "raw_x", make_num(100));
    double x = 100;
    for (int i = 0; i < 12; i++) {
        x *= 0.5;
        env_set_local_owned(env, "raw_x", make_num(x));
        observer_slot_update_num(env, 0, x);
    }
    int answer = observer_predicate_at(env, 0, 2 /* improving */, 1);
    printf("raw host: obs_needed=%d improving=%d\n", g_obs_needed, answer);
    check(g_obs_needed && answer == 1,
          "raw host: state creation records without init_runtime");
    env_decref(env);
    eigs_thread_detach();
    eigs_state_destroy(st);
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
static void *arm_from_worker(void *arg) {
    EigsState *st = arg;
    if (!eigs_thread_attach(st)) return NULL;
    for (int i = 0; i < 10000; i++) eigs_obs_enable();
    eigs_thread_detach();
    return st;
}
/* The first compile is serialized BEFORE a worker can arm. Atomic flag
 * accesses then allow concurrent arming/readers; they do not make a whole
 * compile-and-clear transaction safe against arbitrary concurrent host code. */
static void raw_compile_then_arm(void) {
    EigsState *st = eigs_state_new();
    if (!st || !eigs_thread_attach(st)) {
        check(0, "raw compile: attach state");
        eigs_state_destroy(st);
        return;
    }
    Env *env = env_new(NULL);
    const char *source = "42\n";
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    EigsChunk *chunk = compile_ast(ast, env, source);
    check(chunk && !g_parse_errors && !g_has_error && !g_obs_needed,
          "raw compile: first read-free verdict closes before workers");
    pthread_t worker;
    int rc = pthread_create(&worker, NULL, arm_from_worker, st);
    void *result = NULL;
    if (rc == 0) {
        for (int i = 0; i < 10000; i++) {
            (void)g_obs_needed;
            (void)g_obs_compile_pending;
            (void)g_obs_host_arm_pending;
        }
        rc = pthread_join(worker, &result);
    }
    check(rc == 0 && result == st && g_obs_needed &&
          !g_obs_compile_pending && g_obs_host_arm_pending && !g_obs_history_gap,
          "raw compile: worker arming preserves the open verdict");
    chunk_free(chunk);
    free_ast(ast);
    free_tokenlist(&tl);
    env_decref(env);
    eigs_thread_detach();
    eigs_state_destroy(st);
}
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
/* Execute the documented explicit-host-arm recipe. No compiled predicate
 * may rescue the read-free unit: interrogate its slot directly from C. */
static void isolated_host(void) {
    EigsState *st = eigs_open();
    if (!st) { check(0, "isolated host: open state"); return; }
    eigs_set_eval_observer_isolated(1);
    eigs_obs_enable();
    eigs_obs_enable();  /* idempotent, including the next-boundary pin */
    eval_ok(series, "isolated host: explicitly armed read-free unit executes");
    int slot = -1;
    for (int i = 0; i < g_global_env->count; i++)
        if (!strcmp(g_global_env->names[i], "x")) { slot = i; break; }
    int answer = slot < 0 ? -1 : observer_predicate_at(g_global_env, slot, 2, 1);
    printf("isolated host: DIRECT improving=%d obs_needed=%d gap=%d\n",
           answer, g_obs_needed, g_obs_history_gap);
    check(answer == 1 && g_obs_needed && !g_obs_history_gap && !eigs_has_error(),
          "isolated host: explicit arming survives the eval boundary");
    eval_ok("fresh is 42\nfresh\n", "isolated host: following unit executes");
    check(!g_obs_needed, "isolated host: explicit pin is consumed by one unit");
    eigs_close(st);
}
/* #1114: the gap flag must be truthful the moment a closed unit finishes,
 * not one eval boundary later. Armed unit, then an UN-armed read-free unit
 * that reassigns x (runs closed), then a DIRECT predicate read from C. The
 * answer itself is computed from the stale window (documented: direct reads
 * bypass the eval guard); the flag is what tells the host not to trust it. */
static void isolated_gap_truth(void) {
    EigsState *st = eigs_open();
    if (!st) { check(0, "isolated gap: open state"); return; }
    eigs_set_eval_observer_isolated(1);
    eigs_obs_enable();
    eval_ok(series, "isolated gap: armed unit executes");
    check(g_obs_needed && !g_obs_history_gap,
          "isolated gap: armed unit leaves no gap");
    eval_ok("x is 1000\nx is 2000\nx\n",
            "isolated gap: un-armed reassigning unit executes");
    check(!g_obs_needed, "isolated gap: un-armed unit ran closed");
    int slot = -1;
    for (int i = 0; i < g_global_env->count; i++)
        if (!strcmp(g_global_env->names[i], "x")) { slot = i; break; }
    int answer = slot < 0 ? -1 : observer_predicate_at(g_global_env, slot, 2, 1);
    printf("isolated gap: DIRECT improving=%d obs_needed=%d gap=%d\n",
           answer, g_obs_needed, g_obs_history_gap);
    check(g_obs_history_gap,
          "isolated gap: flag is set before the next eval boundary");
    gap("improving of x", "isolated gap: eval-unit read after the direct read still raises");
    eigs_close(st);
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
    int raw_only = argc == 2 && strcmp(argv[1], "--raw-host") == 0;
    int direct_only = argc == 2 && strcmp(argv[1], "--direct") == 0;
    int isolated_only = argc == 2 && strcmp(argv[1], "--isolated-host") == 0;
    if (!direct_only && !isolated_only) raw_host();
    if (!raw_only && !isolated_only) direct();
#ifndef EIGS_OBS_BASELINE_ONLY
    if (isolated_only) { isolated_host(); isolated_gap_truth(); }
    else if (!raw_only && !direct_only) {
        raw_compile_then_arm();
        eval_contract();
        isolated_host();
        isolated_gap_truth();
    }
#endif
    printf("embed observer: %d passed, %d failed\n", passed, failed);
    return failed ? 1 : 0;
}
