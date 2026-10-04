/* Ordinary sequential compatibility for runtime-owned loop publication.
 * One attached OS thread; no worker/spawn, competing writer or race probe.
 * Selecting the state's existing MT mode covers the defensive branch only.
 */
#include "eigs_embed.h"
#include "eigenscript.h"
#include <stdio.h>
#include <string.h>

static int failures;
static int checks;
static const char *counter = "__loop_iterations__";
static Env *watched_env;
static unsigned setter_calls;

/* GNU linker wrapping observes the real cross-object vm.c setter call.
 * It neither alters the argument nor substitutes the runtime operation. */
void __real_env_set_local(Env *env, const char *name, Value *value);
void __wrap_env_set_local(Env *env, const char *name, Value *value) {
    if (env == watched_env && strcmp(name, counter) == 0) ++setter_calls;
    __real_env_set_local(env, name, value);
}

static void check(int ok, const char *label) {
    ++checks;
    if (!ok) ++failures;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", label);
}

static void step(Env *env, const char *label, int stall,
                 long long expected_iterations, int expected_assignments) {
    unsigned before = setter_calls;
    int require_setter = g_vm_multithreaded && env->mt_shared;
    watched_env = env;
    int rc = stall ? eigs_loop_stall_step(env) : eigs_loop_cap_step(env);
    watched_env = NULL;
    unsigned calls = setter_calls - before;
    int found = 0;
    /* The slot getter reads without boxing/replacing the stored immediate,
     * so sequential reads do not defeat the ordinary warm-cache path.
     * This getter returns a borrowed slot: do not decrement its ownership. */
    EigsSlot value = env_get_hashed_slot(env, counter, 0, &found);
    int numeric = slot_is_num(value) ||
        (slot_is_ptr(value) && slot_as_ptr(value)->type == VAL_NUM);
    double actual = slot_is_num(value) ? value.d :
        (numeric ? slot_as_ptr(value)->data.num : -1);
    int assignments = env_get_assign_count(env, counter, 0);
    int ok = rc == 0 && !g_has_error && found && numeric &&
        actual == (double)expected_iterations &&
        g_loop_iterations == expected_iterations &&
        assignments == expected_assignments && (!require_setter || calls == 1);
    printf("ROW %s step=%s mt=%d shared=%d value=%.0f expected=%lld assignments=%d expected_assignments=%d rc=%d setter_calls=%u setter_required=%d\n",
           label, stall ? "stall" : "cap", g_vm_multithreaded,
           env->mt_shared, actual, expected_iterations, assignments,
           expected_assignments, rc, calls, require_setter);
    check(ok, label);
}

static void grow_env(Env *env, const char *label) {
    int before = env->capacity;
    if (before > 4096) {
        check(0, "unexpected initial Env capacity; bounded growth not attempted");
        return;
    }
    for (int i = 0; i <= before; ++i) {
        char name[64];
        snprintf(name, sizeof(name), "sequential_growth_%d", i);
        Value *value = make_num(i);
        env_set_local(env, name, value);
        val_decref(value);
    }
    printf("GROW %s capacity_before=%d capacity_after=%d\n", label, before, env->capacity);
    check(env->capacity > before, "ordinary new bindings grow Env storage");
}

static int exercise(Env *env, const char *label, long long *iterations) {
    int assignments = 0;
    check(env_get_local_hashed(env, counter, 0) == NULL,
          "counter initially absent in selected local Env");
    g_vm_multithreaded = 0;
    step(env, label, 0, ++*iterations, ++assignments);
    step(env, label, 1, ++*iterations, ++assignments);
    g_vm_multithreaded = 1; /* no second writer is created */
    step(env, label, 0, ++*iterations, ++assignments);
    grow_env(env, label);
    step(env, label, 1, ++*iterations, ++assignments);
    Value *replacement = make_str("ordinary sequential replacement");
    env_set_local(env, counter, replacement);
    val_decref(replacement);
    ++assignments;
    check(env_get_assign_count(env, counter, 0) == assignments,
          "defined replacement increments assignment count once");
    step(env, label, 0, ++*iterations, ++assignments);
    g_vm_multithreaded = 0;
    step(env, label, 0, ++*iterations, ++assignments);
    step(env, label, 1, ++*iterations, ++assignments);
    return assignments;
}

int main(void) {
    EigsState *state = eigs_open();
    if (!state) return 2;
    int saved_mt = g_vm_multithreaded;
    int saved_unobserved = g_unobserved_depth;
    check(saved_mt == 0, "fresh state has no competing writers");
    check(g_sandbox_loop_max == 0 && g_loop_iterations == 0,
          "ordinary fresh counters and no sandbox budget");
    /* Isolate publication from trajectory convergence. Neither API is asked
     * to stop a loop, and no observer or sandbox configuration is altered. */
    g_unobserved_depth = 1;
    Env *root = g_global_env;
    Env *module = env_new(root);
    env_mark_shared(module);
    Env *private_env = env_new(root);
    check(root->mt_shared && module->mt_shared && !private_env->mt_shared,
          "root/shared-child/private Env selection");
    long long iterations = 0;
    int root_assignments = exercise(root, "root", &iterations);
    exercise(module, "shared-child", &iterations);
    exercise(private_env, "private", &iterations);
    g_vm_multithreaded = saved_mt;
    g_unobserved_depth = saved_unobserved;
    env_decref(private_env);
    env_decref(module);

    eigs_thread_detach();
    if (!eigs_thread_attach(state)) {
        fprintf(stderr, "FAIL: sequential reattach\n");
        eigs_state_destroy(state);
        return 2;
    }
    check(g_loop_iterations == 0 && g_vm_multithreaded == saved_mt,
          "reattach resets thread counter and preserves restored state mode");
    g_unobserved_depth = 1;
    step(g_global_env, "reattached-root", 0, 1, root_assignments + 1);
    g_unobserved_depth = saved_unobserved;
    eigs_close(state);
    printf("SEQUENTIAL_LOOP_COUNTER checks=%d failures=%d writers=1\n", checks, failures);
    return failures ? 1 : 0;
}
