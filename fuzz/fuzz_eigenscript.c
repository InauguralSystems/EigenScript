/*
 * EigenScript fuzz harness — libFuzzer target for OSS-Fuzz.
 *
 * Runs the same pipeline main.c does (tokenize -> parse -> compile_ast
 * -> vm_execute) so the VM/compiler/JIT layers are in scope.
 *
 * Build locally (clang required):
 *   make fuzz-libfuzzer
 *
 * Run:
 *   ./fuzz/fuzz_eigenscript fuzz/corpus/ -max_len=4096 -timeout=5
 *
 * OSS-Fuzz uses this entry point with $LIB_FUZZING_ENGINE substituted
 * for libFuzzer's main(). See projects/eigenscript/build.sh in the
 * OSS-Fuzz repo.
 *
 * `make fuzz` links this same file under fuzz/fuzz_stdin.c, a one-input
 * stdin driver built with gcc, and the CI fuzz smoke runs that (#1734).
 */

#include "../src/eigenscript.h"
#include "../src/state.h"
#include "../src/vm.h"
#include "../src/trace.h"
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The state, thread and builtin table are created once and live for the
 * process lifetime (libFuzzer never exits cleanly between inputs, so there
 * is no teardown). LeakSanitizer must not count them: measured 2026-09-16
 * on a clean build, LSan reported the SAME 27,501 bytes / 282 allocations
 * (every stack = make_builtin <- register_builtins <- here) after 10 inputs
 * and after 10 seconds — a constant, not growth — and libFuzzer stops at the
 * first report, so the fuzzer never got past its seed corpus. Allocations
 * made while LSan is disabled are ignored forever; per-input allocations
 * (made with it re-enabled) are still checked, which is the leak class a
 * fuzzer exists to find. gcc (the `make fuzz` driver) names ASan with
 * __SANITIZE_ADDRESS__, clang with __has_feature; either must reach the
 * disable, or every input reports the builtin table (#1734). */
#if defined(__SANITIZE_ADDRESS__)
#  define FUZZ_HAVE_LSAN 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define FUZZ_HAVE_LSAN 1
#  endif
#endif
#ifdef FUZZ_HAVE_LSAN
#  include <sanitizer/lsan_interface.h>
#  define FUZZ_LSAN_DISABLE() __lsan_disable()
#  define FUZZ_LSAN_ENABLE()  __lsan_enable()
#else
#  define FUZZ_LSAN_DISABLE() ((void)0)
#  define FUZZ_LSAN_ENABLE()  ((void)0)
#endif

/* #1734 positive control for the CI smoke. `fuzz/run_fuzz.sh --plant-leak`
 * sets EIGS_FUZZ_LEAK_PLANT, and only then is this builtin bound. It allocates
 * a dict and drops the only pointer to it: a real per-input leak, which
 * LeakSanitizer must still report after the per-input teardown, from a stack
 * where make_dict is called by fuzz_leak_plant. A fuzzing run never binds it,
 * so no mutated input can reach it. */
static Value *fuzz_leak_plant(Value *arg) {
    (void)arg;
    (void)make_dict(4);
    return make_null();
}

/* #2097 positive control for the fuzz smoke's UBSan read-back. Volatile keeps
 * the recoverable signed overflow in the instrumented runtime. Like the leak
 * plant, this builtin is absent unless the dedicated plant switch is set. */
static Value *fuzz_ubsan_plant(Value *arg) {
    volatile int value = INT_MAX;
    (void)arg;
    value += 1;
    return make_num((double)value);
}

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    srand(0);
    FUZZ_LSAN_DISABLE();
    eigs_thread_attach(eigs_state_new());
    eigs_global_env_create();   /* + builtin layer (#1388) */
    if (getenv("EIGS_FUZZ_LEAK_PLANT"))
        env_set_local_owned(g_global_env, "fuzz_leak_plant",
                            make_builtin(fuzz_leak_plant));
    if (getenv("EIGS_FUZZ_UBSAN_PLANT"))
        env_set_local_owned(g_global_env, "fuzz_ubsan_plant",
                            make_builtin(fuzz_ubsan_plant));
    FUZZ_LSAN_ENABLE();

    /* libFuzzer itself writes stats to stderr, so let it through.
     * Run with `-close_fd_mask=3` to silence the fuzzed program's
     * own stdout/stderr — that's what OSS-Fuzz passes by default. */
    return 0;
}


/* Every per-state depth counter and the VM's stack must be back at rest when
 * an input returns. The state lives across inputs, so a counter that an error
 * path forgets to restore drifts input by input until a guard stops firing,
 * and the crash lands on some LATER input that runs clean on its own (the
 * first HF pilot, 2026-10-12: 29 crash artifacts, 0 reproducible). Aborting
 * here makes the drifting input itself the artifact. */
static void fuzz_check_invariants(void) {
    struct { const char *name; long v; } c[] = {
        {"try_depth", (long)g_try_depth}, {"unobserved_depth", (long)g_unobserved_depth},
        {"parse_depth", (long)g_parse_depth}, {"obs_gate_depth", (long)g_obs_gate_depth},
        {"tokenize_depth", (long)g_tokenize_depth}, {"vts_depth", (long)g_vts_depth},
        {"json_depth", (long)g_json_depth}, {"native_call_depth", (long)g_native_call_depth},
    };
    for (size_t i = 0; i < sizeof c / sizeof c[0]; i++)
        if (c[i].v != 0) { fprintf(stderr, "FUZZ INVARIANT: %s = %ld after input\n", c[i].name, c[i].v); abort(); }
    if (eigs_current && eigs_current->vm) {
        if (g_vm.frame_count != 0 || g_vm.sp != 0) {
            fprintf(stderr, "FUZZ INVARIANT: vm frame_count = %d, sp = %d after input\n", g_vm.frame_count, g_vm.sp);
            abort();
        }
    }
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size == 0 || size > 65536) return 0;

    char *source = (char *)malloc(size + 1);
    if (!source) return 0;
    memcpy(source, data, size);
    source[size] = '\0';

    /* Reset per-invocation state. libFuzzer reuses the process across
     * inputs, so any flag a prior input toggled must be cleared here. */
    g_parse_errors = 0;
    g_has_error = 0;
    g_returning = 0;
    g_breaking = 0;
    g_continuing = 0;

    /* Arm the sandbox loop budget for every input (the same two counters
     * sandbox_run arms, #772/#940). EigenScript is Turing-complete, so a
     * fuzzer WILL synthesise programs that never halt — the first 90-second
     * run on 2026-09-16 produced `loop while i < 5: i is i + 0` inside
     * 17,819 inputs — and libFuzzer files a -timeout as a bug. With the
     * budget armed the program trips "sandbox loop budget exceeded" and
     * returns; a genuine hang (one the budget cannot reach: a builtin that
     * spins, a lock never released) is still a timeout, which is exactly
     * the class worth filing. 200,000 back-edges is ~0.2 s under ASan. */
    g_sandbox_loop_max = 200000;
    g_sandbox_cap_hit = 0;
    g_loop_iterations = 0;
    g_sandbox_loop_iterations = 0;   /* #1906: the budget's own counter */
    g_loop_backedge_count = 0;

    TokenList tl = tokenize(source);
    if (g_parse_errors == 0) {
        ASTNode *ast = parse(&tl);
        if (g_parse_errors == 0 && ast) {
            /* Execute in a fresh child env so global bindings from one
             * input don't shadow builtins on the next. */
            Env *eval_env = env_new(g_global_env);
            EigsChunk *chunk = compile_ast(ast, eval_env, source, "<fuzz>");
            if (chunk) {
                Value *result = vm_execute(chunk, eval_env);
                if (result) val_decref(result);
                chunk_free(chunk);
            }
            env_decref(eval_env);
            /* A fuzz input can spawn workers that outlive vm_execute(). Join
             * them before touching the unguarded module cache, and restore
             * single-threaded mode so the cycle collector can run. */
            handle_table_drain(eigs_current_state());
            /* #1734: then this thread's temporal history (the `prev of` / `at`
             * table), before the collection below. That is the order of the
             * CLI's exit (main.c: the drain, then trace_shutdown, which ends
             * in this call, then gc_collect_at_exit) and of eigs_close
             * (#1608). The recorder is process-wide: once an input arms it
             * (a temporal query or `record_history`; any spawn then widens it
             * to every name), the table holds counted refs on each later
             * input's top-level values. The collector saw those values as
             * externally rooted, and LeakSanitizer cannot read the tagged
             * slots that hold them, so the first HF pilot stopped on direct
             * leaks from make_fn <- vm_run_ex and make_dict <- builtin_spawn.
             * Releasing it also keeps one input's history out of the next
             * input's `prev of`. */
            trace_thread_release();
            /* The process stays attached across inputs, unlike the CLI.  Drop
             * the cooperative scheduler here just as thread detach would;
             * otherwise its current task id can refer to a task the handle
             * drain above has reclaimed. */
            task_sched_thread_free();
            /* The CLI frees env<->closure CYCLES only at exit
             * (gc_collect_at_exit in main.c); a fuzzer never exits, so
             * without a per-input collection every input that builds a
             * closure leaves one cycle behind and LeakSanitizer stops the
             * run on the first such input (measured 2026-09-16: 8,709 B /
             * 21 allocations for `f is (x) => x * 2`, rooted at vm_run).
             * Collect after each input; a module the input imported is
             * dropped too so a pinned module env cannot mask a leak. */
            eigs_module_cache_clear();
            gc_collect_cycles();
        }
        if (ast) free_ast(ast);
    }
    free_tokenlist(&tl);
    free(source);
    fuzz_check_invariants();
    return 0;
}
