/*
 * EigenScript fuzz harness — libFuzzer target.
 *
 * Fuzzes the full pipeline: tokenize → parse → eval.
 * Catches: crashes, buffer overflows, hangs, assertion failures.
 *
 * Build:
 *   clang -g -fsanitize=fuzzer,address -o fuzz/fuzz_eigenscript \
 *     fuzz/fuzz_eigenscript.c src/eigenscript.c src/lexer.c src/parser.c \
 *     src/eval.c src/builtins.c src/arena.c \
 *     -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
 *     -DEIGENSCRIPT_VERSION='"fuzz"' -lm -lpthread
 *
 * Run:
 *   ./fuzz/fuzz_eigenscript fuzz/corpus/ -max_len=4096 -timeout=5
 */

#include "../src/eigenscript.h"
#include <string.h>
#include <stdlib.h>

/* Globals required by the runtime */
Env *g_global_env = NULL;
char g_script_dir[4096] = ".";

int LLVMFuzzerInitialize(int *argc, char ***argv) {
    (void)argc; (void)argv;
    srand(0);
    arena_init();
    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;
    return 0;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    /* Skip empty inputs */
    if (size == 0) return 0;

    /* Null-terminate the input */
    char *source = malloc(size + 1);
    if (!source) return 0;
    memcpy(source, data, size);
    source[size] = '\0';

    /* Suppress stderr and stdout during fuzzing */
    int saved_stderr = dup(STDERR_FILENO);
    int saved_stdout = dup(STDOUT_FILENO);
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        dup2(devnull, STDERR_FILENO);
        dup2(devnull, STDOUT_FILENO);
        close(devnull);
    }

    /* Reset error state */
    g_parse_errors = 0;
    g_has_error = 0;
    g_returning = 0;
    g_breaking = 0;
    g_continuing = 0;

    /* Tokenize */
    TokenList tl = tokenize(source);

    /* Parse (only if tokenize succeeded) */
    if (g_parse_errors == 0) {
        ASTNode *ast = parse(&tl);

        /* Eval (only if parse succeeded) */
        if (g_parse_errors == 0 && ast) {
            /* Run in a fresh env to avoid state leakage */
            Env *eval_env = env_new(g_global_env);
            eval_node(ast, eval_env);
            /* Don't free eval_env — closures may reference it */
        }
    }

    free_tokenlist(&tl);
    free(source);

    /* Restore stderr/stdout */
    if (saved_stderr >= 0) { dup2(saved_stderr, STDERR_FILENO); close(saved_stderr); }
    if (saved_stdout >= 0) { dup2(saved_stdout, STDOUT_FILENO); close(saved_stdout); }

    return 0;
}
