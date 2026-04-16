/*
 * EigenScript fuzz harness — stdin-based.
 * Reads EigenScript source from stdin, runs tokenize → parse → eval.
 * Use with AFL, honggfuzz, or manual crash testing.
 *
 * Build:
 *   gcc -g -fsanitize=address,undefined -o fuzz/fuzz_stdin \
 *     fuzz/fuzz_stdin.c src/eigenscript.c src/lexer.c src/parser.c \
 *     src/eval.c src/builtins.c src/arena.c \
 *     -DEIGENSCRIPT_EXT_HTTP=0 -DEIGENSCRIPT_EXT_MODEL=0 -DEIGENSCRIPT_EXT_DB=0 \
 *     -DEIGENSCRIPT_VERSION='"fuzz"' -lm -lpthread
 *
 * Run manually:
 *   echo 'x is 1 / 0' | ./fuzz/fuzz_stdin
 *
 * Run with AFL:
 *   afl-fuzz -i fuzz/corpus -o fuzz/findings -- ./fuzz/fuzz_stdin
 */

#include "../src/eigenscript.h"
#include <string.h>
#include <stdlib.h>

Env *g_global_env = NULL;
char g_script_dir[4096] = ".";

int main(void) {
    /* Read all of stdin */
    char buf[65536];
    size_t total = 0;
    size_t n;
    while ((n = fread(buf + total, 1, sizeof(buf) - total - 1, stdin)) > 0) {
        total += n;
        if (total >= sizeof(buf) - 1) break;
    }
    buf[total] = '\0';
    if (total == 0) return 0;

    /* Init runtime */
    srand(0);
    arena_init();
    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;

    /* Suppress output */
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull >= 0) {
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        close(devnull);
    }

    /* Reset state */
    g_parse_errors = 0;
    g_has_error = 0;
    g_returning = 0;
    g_breaking = 0;
    g_continuing = 0;

    /* Run pipeline */
    TokenList tl = tokenize(buf);
    if (g_parse_errors == 0) {
        ASTNode *ast = parse(&tl);
        if (g_parse_errors == 0 && ast) {
            Env *eval_env = env_new(global);
            eval_node(ast, eval_env);
        }
    }
    free_tokenlist(&tl);

    return 0;
}
