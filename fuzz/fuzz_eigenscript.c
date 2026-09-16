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
 */

#include "../src/eigenscript.h"
#include "../src/state.h"
#include "../src/vm.h"
#include <fcntl.h>
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
 * fuzzer exists to find. */
#if defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    include <sanitizer/lsan_interface.h>
#    define FUZZ_LSAN_DISABLE() __lsan_disable()
#    define FUZZ_LSAN_ENABLE()  __lsan_enable()
#  endif
#endif
#ifndef FUZZ_LSAN_DISABLE
#  define FUZZ_LSAN_DISABLE() ((void)0)
#  define FUZZ_LSAN_ENABLE()  ((void)0)
#endif

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    srand(0);
    FUZZ_LSAN_DISABLE();
    eigs_thread_attach(eigs_state_new());
    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;
    FUZZ_LSAN_ENABLE();

    /* libFuzzer itself writes stats to stderr, so let it through.
     * Run with `-close_fd_mask=3` to silence the fuzzed program's
     * own stdout/stderr — that's what OSS-Fuzz passes by default. */
    return 0;
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
    g_loop_backedge_count = 0;

    TokenList tl = tokenize(source);
    if (g_parse_errors == 0) {
        ASTNode *ast = parse(&tl);
        if (g_parse_errors == 0 && ast) {
            /* Execute in a fresh child env so global bindings from one
             * input don't shadow builtins on the next. */
            Env *eval_env = env_new(g_global_env);
            EigsChunk *chunk = compile_ast(ast, eval_env, source);
            if (chunk) {
                Value *result = vm_execute(chunk, eval_env);
                if (result) val_decref(result);
                chunk_free(chunk);
            }
            env_decref(eval_env);
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
    return 0;
}
