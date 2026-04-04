/*
 * EigenScript CLI — script runner entry point.
 */

#include "eigenscript.h"
#if EIGENSCRIPT_EXT_HTTP
#include "ext_http_internal.h"
#endif

Env *g_global_env = NULL;

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "0.5.0"
#endif

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
        printf("%s\n", EIGENSCRIPT_VERSION);
        return 0;
    }
    if (argc < 2) {
        fprintf(stderr, "Usage: eigenscript <file.eigs>\n");
        fprintf(stderr, "       eigenscript --version\n");
        return 1;
    }

    long src_size = 0;
    char *source = read_file_util(argv[1], &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", argv[1]);
        return 1;
    }

    srand(time(NULL));
    arena_init();

    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;

#if EIGENSCRIPT_EXT_HTTP
    g_server.global_env = global;
    g_server.route_count = 0;
    g_server.static_prefix = NULL;
    g_server.static_dir = NULL;
    g_server.request_body = NULL;
    g_server.session_id = NULL;
    g_server.request_headers = NULL;
#endif

    g_parse_errors = 0;
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0) {
        fprintf(stderr, "%d parse error(s) — aborting\n", g_parse_errors);
        free(source);
        return 1;
    }
    eval_node(ast, global);

    free(source);
    return 0;
}
