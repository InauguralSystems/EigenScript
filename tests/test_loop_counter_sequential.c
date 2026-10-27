/* Ordinary sequential compatibility for runtime-owned loop publication.
 * One attached OS thread; no worker/spawn, competing writer or race probe.
 * Selecting the state's existing MT mode covers the defensive branch only.
 */
#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"
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
    /* S9-K1 (#1758) replaces the old float-only expectation: a count is
     * an int, including boxed counts beyond the SMI range and 2^53. */
    int integer = slot_is_smi(value) ||
        (slot_is_ptr(value) && slot_as_ptr(value)->type == VAL_INT);
    int64_t actual = slot_is_smi(value) ? slot_smi_val(value) :
        (integer ? VAL_I64_RAW(slot_as_ptr(value)) : -1);
    int assignments = env_get_assign_count(env, counter, 0);
    int ok = rc == 0 && !g_has_error && found && integer &&
        actual == expected_iterations &&
        g_loop_iterations == expected_iterations &&
        assignments == expected_assignments && (!require_setter || calls == 1);
    printf("ROW %s step=%s mt=%d shared=%d value=%lld expected=%lld assignments=%d expected_assignments=%d rc=%d setter_calls=%u setter_required=%d\n",
           label, stall ? "stall" : "cap", g_vm_multithreaded,
           env->mt_shared, (long long)actual, expected_iterations, assignments,
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
        Value *value = make_float(i);
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

static void scheduler_metadata(void) {
    /* The trace reader has no script builtin; inspect its real returned
     * dicts after running an ordinary task, including fractional sleep. */
    g_task_trace_on = 1;
    Value *result = (Value *)eigs_eval_string(
        "define count_metadata_worker() as:\n"
        "    task_sleep of 0.5\n"
        "    return 7\n"
        "task_join of (task_spawn of count_metadata_worker)\n");
    check(result && !g_has_error, "ordinary task produces scheduler metadata");
    if (result) val_decref(result);
    Value *trace = task_sched_trace_read();
    int metadata_ok = trace && trace->type == VAL_LIST && trace->data.list.count > 0;
    int saw_task = 0, saw_fraction = 0;
    if (metadata_ok) {
        for (int i = 0; i < trace->data.list.count; ++i) {
            Value *row = list_get_ref(trace, i);
            if (!row || row->type != VAL_DICT) { metadata_ok = 0; break; }
            EIGS_VIEW(seq_view); EIGS_VIEW(task_view); EIGS_VIEW(tick_view);
            Value *seq = dict_get_view(row, "seq", &seq_view);
            Value *task = dict_get_view(row, "task", &task_view);
            Value *tick = dict_get_view(row, "tick", &tick_view);
            if (!seq || seq->type != VAL_INT || VAL_I64_RAW(seq) != i ||
                !task || task->type != VAL_INT || VAL_I64_RAW(task) < 0 ||
                !tick || tick->type != VAL_FLOAT) {
                metadata_ok = 0; break;
            }
            saw_task |= VAL_I64_RAW(task) > 0;
            saw_fraction |= VAL_F64_RAW(tick) == 0.5;
        }
    }
    check(metadata_ok && saw_task, "scheduler sequence and task ids publish exact ints");
    check(metadata_ok && saw_fraction, "scheduler virtual time preserves fractional float ticks");
    if (trace) val_decref(trace);
    g_task_trace_on = 0;
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
    /* Exercise cached SMI publication, the first boxed count and a count
     * binary64 cannot represent; no loop budget or convergence is involved. */
    g_loop_iterations = SLOT_SMI_MAX - 1;
    step(g_global_env, "last-smi-count", 0, SLOT_SMI_MAX, root_assignments + 2);
    step(g_global_env, "first-boxed-count", 1, SLOT_SMI_MAX + 1, root_assignments + 3);
    step(g_global_env, "next-boxed-count", 0, SLOT_SMI_MAX + 2, root_assignments + 4);
    g_loop_iterations = INT64_C(9007199254740992);
    step(g_global_env, "exact-count-above-2pow53", 0,
         INT64_C(9007199254740993), root_assignments + 5);
    g_unobserved_depth = saved_unobserved;
    scheduler_metadata();
    eigs_close(state);
    printf("SEQUENTIAL_LOOP_COUNTER checks=%d failures=%d writers=1\n", checks, failures);
    return failures ? 1 : 0;
}
