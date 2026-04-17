/*
 * EigenScript CLI — script runner and REPL entry point.
 */

#include "eigenscript.h"
#if EIGENSCRIPT_EXT_HTTP
#include "ext_http_internal.h"
#endif
#if EIGENSCRIPT_EXT_GFX
void register_gfx_builtins(Env *env);
#endif

Env *g_global_env = NULL;
char g_script_dir[4096] = ".";

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

/* ---- REPL ---- */

static void eigenscript_repl(Env *env) {
    printf("EigenScript %s\n", EIGENSCRIPT_VERSION);
    printf("Type 'exit' or Ctrl-D to quit.\n\n");

    char line_buf[4096];
    strbuf input;
    strbuf_init(&input);
    int continuation = 0;

    while (1) {
        printf(continuation ? "...   " : "eigs> ");
        fflush(stdout);

        if (!fgets(line_buf, sizeof(line_buf), stdin)) {
            printf("\n");
            break;
        }

        /* Exit commands */
        if (!continuation) {
            char *trimmed = line_buf;
            while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
            if (strcmp(trimmed, "exit\n") == 0 || strcmp(trimmed, "quit\n") == 0 ||
                strcmp(trimmed, "exit\r\n") == 0 || strcmp(trimmed, "quit\r\n") == 0) {
                break;
            }
        }

        int len = strlen(line_buf);
        strbuf_append_n(&input, line_buf, (size_t)len);

        /* Multi-line detection */
        if (!continuation) {
            /* Check if line ends with colon (block opener) */
            char *end = line_buf + len - 1;
            while (end > line_buf && (*end == '\n' || *end == '\r' || *end == ' ')) end--;
            if (*end == ':') {
                continuation = 1;
                continue;
            }
        } else {
            /* In continuation: blank line or unindented line ends block */
            char *trimmed = line_buf;
            while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
            if (*trimmed == '\n' || *trimmed == '\r' || *trimmed == '\0') {
                continuation = 0;
                /* fall through to execute */
            } else if (line_buf[0] == ' ' || line_buf[0] == '\t') {
                continue; /* still indented, keep accumulating */
            } else {
                continuation = 0;
                /* unindented non-blank: end of block */
            }
        }

        /* Skip empty input */
        {
            char *check = input.data;
            while (*check == ' ' || *check == '\t' || *check == '\n' || *check == '\r') check++;
            if (*check == '\0') {
                input.len = 0;
                input.data[0] = '\0';
                continue;
            }
        }

        /* Tokenize, parse, eval with error recovery */
        g_parse_errors = 0;
        TokenList tl = tokenize(input.data);
        if (g_parse_errors > 0) {
            free_tokenlist(&tl);
            input.len = 0;
            input.data[0] = '\0';
            continue;
        }

        ASTNode *ast = parse(&tl);
        if (g_parse_errors > 0) {
            free_tokenlist(&tl);
            input.len = 0;
            input.data[0] = '\0';
            continue;
        }

        g_returning = 0;
        g_return_val = NULL;
        Value *result = eval_node(ast, env);

        /* Print non-null results */
        if (result && result->type != VAL_NULL) {
            char *s = value_to_string(result);
            printf("=> %s\n", s);
            free(s);
        }

        free_tokenlist(&tl);
        /* Don't free AST — function defs hold pointers into it */
        input.len = 0;
        input.data[0] = '\0';
    }
    strbuf_free(&input);
}

/* ---- Main ---- */

int main(int argc, char **argv) {
    if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
        printf("%s\n", EIGENSCRIPT_VERSION);
        return 0;
    }

    /* No arguments: enter REPL */
    if (argc < 2) {
        srand(time(NULL));
        eigenscript_set_args(argc, argv);
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
#if EIGENSCRIPT_EXT_GFX
        register_gfx_builtins(global);
#endif

        eigenscript_repl(global);
        return 0;
    }

    /* Extract script directory for load_file resolution */
    {
        const char *last_slash = strrchr(argv[1], '/');
        if (last_slash) {
            int dir_len = (int)(last_slash - argv[1]);
            if (dir_len >= (int)sizeof(g_script_dir)) dir_len = sizeof(g_script_dir) - 1;
            memcpy(g_script_dir, argv[1], dir_len);
            g_script_dir[dir_len] = '\0';
        } else {
            strcpy(g_script_dir, ".");
        }
    }

    long src_size = 0;
    char *source = read_file_util(argv[1], &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", argv[1]);
        return 1;
    }

    srand(time(NULL));
    eigenscript_set_args(argc, argv);
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
#if EIGENSCRIPT_EXT_GFX
    register_gfx_builtins(global);
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
