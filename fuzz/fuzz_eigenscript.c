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
#include "../src/vm.h"
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

Env *g_global_env = NULL;
char g_script_dir[4096] = ".";
char g_exe_dir[4096] = ".";
__thread Env *g_load_env = NULL;

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    srand(0);
    arena_init();
    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;

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

    TokenList tl = tokenize(source);
    if (g_parse_errors == 0) {
        ASTNode *ast = parse(&tl);
        if (g_parse_errors == 0 && ast) {
            /* Execute in a fresh child env so global bindings from one
             * input don't shadow builtins on the next. */
            Env *eval_env = env_new(g_global_env);
            EigsChunk *chunk = compile_ast(ast, eval_env);
            if (chunk) {
                Value *result = vm_execute(chunk, eval_env);
                if (result) val_decref(result);
                chunk_free(chunk);
            }
            env_decref(eval_env);
        }
        if (ast) free_ast(ast);
    }
    free_tokenlist(&tl);
    free(source);
    return 0;
}
