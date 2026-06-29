/*
 * EigenScript CLI — script runner and REPL entry point.
 */

#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "trace.h"
#if EIGENSCRIPT_EXT_GFX
void register_gfx_builtins(Env *env);
#endif

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
        g_has_error = 0;   /* don't carry a prior line's error into this one */
        EigsChunk *repl_chunk = compile_ast(ast, env);
        if (g_parse_errors > 0) {   /* e.g. an un-encodable jump/loop offset */
            fprintf(stderr, "%d compile error(s) — line not run\n", g_parse_errors);
            chunk_free(repl_chunk);
            free_tokenlist(&tl);
            free_ast(ast);
            input.len = 0;
            input.data[0] = '\0';
            continue;
        }
        Value *result = vm_execute(repl_chunk, env);
        if (g_exit_requested) {                 /* `exit of N` typed at the REPL */
            g_has_error = 0;
            chunk_free(repl_chunk);
            if (result) val_decref(result);
            free_tokenlist(&tl);
            free_ast(ast);
            break;
        }
        /* Chunks are refcounted: drop the creator ref. Functions defined
         * on this line hold their own refs on their nested chunks. */
        chunk_free(repl_chunk);

        /* Print non-null results */
        if (result && result->type != VAL_NULL) {
            char *s = value_to_string(result);
            printf("=> %s\n", s);
            free(s);
        }
        if (result) val_decref(result);

        free_tokenlist(&tl);
        /* Function bodies are cloned (AST fns) or compiled into chunks
         * (bytecode fns), so the per-line AST is safe to free. */
        free_ast(ast);
        input.len = 0;
        input.data[0] = '\0';
    }
    strbuf_free(&input);
}

/* ---- Main ---- */

static void set_exe_dir(const char *argv0) {
    char exe_path[4096];
    ssize_t n = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (n > 0 && n < (ssize_t)sizeof(exe_path)) {
        exe_path[n] = '\0';
    } else if (argv0 && strchr(argv0, '/')) {
        strncpy(exe_path, argv0, sizeof(exe_path) - 1);
        exe_path[sizeof(exe_path) - 1] = '\0';
    } else {
        memcpy(g_exe_dir, ".", 2);
        return;
    }

    const char *last_slash = strrchr(exe_path, '/');
    if (!last_slash) {
        memcpy(g_exe_dir, ".", 2);
        return;
    }
    int dir_len = (int)(last_slash - exe_path);
    if (dir_len <= 0) {
        memcpy(g_exe_dir, "/", 2);
        return;
    }
    if (dir_len >= (int)sizeof(g_exe_dir)) dir_len = sizeof(g_exe_dir) - 1;
    memcpy(g_exe_dir, exe_path, dir_len);
    g_exe_dir[dir_len] = '\0';
}

int main(int argc, char **argv) {
    trace_init();
    atexit(trace_shutdown);

    /* --version doesn't touch the runtime; handle it before any state. */
    if (argc >= 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
        printf("%s\n", EIGENSCRIPT_VERSION);
        return 0;
    }

    /* --help is likewise pure; print usage and exit before touching state.
     * Without this, `--help` falls through to the file path below and the
     * runtime tries to read a file literally named "--help". */
    if (argc >= 2 && (strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0)) {
        printf(
            "EigenScript %s — a bytecode VM language with observers and temporal queries\n"
            "\n"
            "Usage:\n"
            "  eigenscript <file.eigs> [args...]   run a script (args readable via `args of null`)\n"
            "  eigenscript                         start the REPL\n"
            "  eigenscript --fmt [--write] <file>  format a source file (stdout, or rewrite with --write)\n"
            "  eigenscript --lint [--json] <file>  lint a source file (--json for machine-readable diagnostics)\n"
            "  eigenscript --test [paths...]       run test_*.eigs files (--json for machine-readable results)\n"
            "  eigenscript --pkg <cmd> [args...]   package manager (add/install/update/verify; see docs)\n"
            "  eigenscript --version, -v           print the version and exit\n"
            "  eigenscript --help, -h              print this help and exit\n"
            "\n"
            "Docs: https://github.com/InauguralSystems/EigenScript\n",
            EIGENSCRIPT_VERSION);
        return 0;
    }

    /* --fmt is a pure source transformer; no VM, no arena, no state. */
    if (argc >= 2 && strcmp(argv[1], "--fmt") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: eigenscript --fmt [--write] file.eigs\n");
            return 1;
        }
        int write_mode = 0;
        const char *path;
        if (argc >= 4 && strcmp(argv[2], "--write") == 0) {
            write_mode = 1;
            path = argv[3];
        } else {
            path = argv[2];
        }
        return eigenscript_fmt(path, write_mode);
    }

    /* Everything below uses g_script_dir / g_exe_dir / g_global_env,
     * which are EigsState bridge macros — attach before computing. */
    EigsState *eigs_st = eigs_state_new();
    eigs_thread_attach(eigs_st);
    set_exe_dir(argc > 0 ? argv[0] : NULL);

    /* --lint flag (optionally --lint --json for machine-readable output;
     * --json may appear before or after the path). */
    if (argc >= 2 && strcmp(argv[1], "--lint") == 0) {
        int json_mode = 0;
        const char *lint_path = NULL;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--json") == 0) json_mode = 1;
            else if (!lint_path) lint_path = argv[i];
        }
        if (!lint_path) {
            fprintf(stderr, "Usage: eigenscript --lint [--json] file.eigs\n");
            eigs_thread_detach();
            eigs_state_destroy(eigs_st);
            return 1;
        }
        int rc = eigenscript_lint(lint_path, json_mode);
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return rc;
    }

    /* --pkg flag: dispatch to lib/pkg.eigs with the rest of the argv as
     * its args. `args of null` returns argv[2:], so the EigenScript
     * side sees [subcommand, ...rest]. The script reads ./eigs.json and
     * writes ./eigs_modules/ via cwd-relative file I/O — g_script_dir
     * only affects import resolution, not those builtins. */
    static char pkg_path[8192];
    if (argc >= 2 && strcmp(argv[1], "--pkg") == 0) {
        if (!resolve_eigenscript_file("lib/pkg.eigs", pkg_path, sizeof(pkg_path))) {
            fprintf(stderr, "Error: cannot locate lib/pkg.eigs (stdlib not installed?)\n");
            eigs_thread_detach();
            eigs_state_destroy(eigs_st);
            return 1;
        }
        argv[1] = pkg_path;
        /* fall through to script execution */
    }

    /* --test flag: dispatch to lib/test_runner.eigs, same mechanism as
     * --pkg. `args of null` gives the runner argv[2:] (the paths + --json).
     * The runner re-invokes this interpreter (via exe_path) on each
     * discovered test_*.eigs file. */
    static char test_path[8192];
    if (argc >= 2 && strcmp(argv[1], "--test") == 0) {
        if (!resolve_eigenscript_file("lib/test_runner.eigs", test_path, sizeof(test_path))) {
            fprintf(stderr, "Error: cannot locate lib/test_runner.eigs (stdlib not installed?)\n");
            eigs_thread_detach();
            eigs_state_destroy(eigs_st);
            return 1;
        }
        argv[1] = test_path;
        /* fall through to script execution */
    }

    /* No arguments: enter REPL */
    if (argc < 2) {
        srand(time(NULL));
        eigenscript_set_args(argc, argv);

        Env *global = env_new(NULL);
        register_builtins(global);
        g_global_env = global;

#if EIGENSCRIPT_EXT_GFX
        register_gfx_builtins(global);
#endif
        register_store_builtins(global);

        eigenscript_repl(global);
        trace_shutdown();
        /* Drop the global scope's bindings (closures defined at top level
         * die here), then collect the env<->fn cycles those closures left
         * behind, then release the creator ref — with honest env
         * refcounts this reclaims the whole graph (docs/CLOSURE_CYCLE_GC.md).
         * Spawned-thread leftovers keep the tolerated-leak behavior. */
        gc_collect_at_exit(global);
        env_decref(global);
        g_global_env = NULL;
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return g_exit_requested ? g_exit_code : 0;
    }

    /* Extract script directory for load_file resolution. g_script_dir
     * is an EigsState bridge macro — state is already attached above. */
    {
        const char *last_slash = strrchr(argv[1], '/');
        if (last_slash) {
            int dir_len = (int)(last_slash - argv[1]);
            if (dir_len >= (int)sizeof(g_script_dir)) dir_len = sizeof(g_script_dir) - 1;
            memcpy(g_script_dir, argv[1], dir_len);
            g_script_dir[dir_len] = '\0';
        } else {
            memcpy(g_script_dir, ".", 2);
        }
    }

    long src_size = 0;
    char *source = read_file_util(argv[1], &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", argv[1]);
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return 1;
    }

    srand(time(NULL));
    eigenscript_set_args(argc, argv);

    Env *global = env_new(NULL);
    register_builtins(global);
    g_global_env = global;

#if EIGENSCRIPT_EXT_GFX
    register_gfx_builtins(global);
#endif
    register_store_builtins(global);

    g_parse_errors = 0;
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0) {
        fprintf(stderr, "%d parse error(s) — aborting\n", g_parse_errors);
        free_ast(ast);  /* parse returns a partial tree on error; free it (cf. #214) */
        free(source);
        free_tokenlist(&tl);
        env_decref(global);
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return 1;
    }
    g_compile_module_slots = 1;
    EigsChunk *script_chunk = compile_ast(ast, global);
    g_compile_module_slots = 0;
    if (g_parse_errors > 0) {   /* compile-stage error, e.g. un-encodable jump */
        fprintf(stderr, "%d compile error(s) — aborting\n", g_parse_errors);
        chunk_free(script_chunk);
        free_ast(ast);
        free(source);
        free_tokenlist(&tl);
        env_decref(global);
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return 1;
    }
    if (getenv("EIGS_DUMP_BC")) chunk_disassemble(script_chunk, "<module>");
    Value *result = vm_execute(script_chunk, global);
    if (result) val_decref(result);
    /* Program done: deterministically reap workers and free channels while the
     * value world is still alive (channels/threads live in the handle table,
     * not on a GC'd Value, so nothing else reclaims them). */
    handle_table_drain(eigs_st);
    /* An uncaught runtime error leaves g_has_error set (vm_run unwinds to
     * here rather than continuing with null). Report it as a non-zero exit
     * so scripts fail loudly for callers, Makefiles, and CI. */
    /* `exit of N` requests a specific code (and unwound via g_has_error); it
     * takes precedence over the generic uncaught-error code. Clear the unwind
     * flag so the teardown below sees a clean state. */
    int exit_code = g_exit_requested ? g_exit_code : (g_has_error ? 1 : 0);
    if (g_exit_requested) g_has_error = 0;
    /* An uncaught `throw` leaves its structured payload stashed; release
     * it so exit is leak-clean. */
    eigs_clear_error_value();
    /* Chunks are refcounted: this drops the creator ref. Nested fn chunks
     * referenced by live closures survive until those values die (during
     * env_destroy_final below). */
    chunk_free(script_chunk);

    free_ast(ast);
    free_tokenlist(&tl);
    free(source);
    /* Teardown order matters: the trace prev-table holds refs to values
     * whose death can touch their closure env, so it must drain before
     * the global env is destroyed. The atexit-registered trace_shutdown
     * then no-ops. Then: drop the global scope's bindings, collect the
     * env<->fn cycles left behind by escaped closures, and release the
     * creator ref (docs/CLOSURE_CYCLE_GC.md). Spawned-thread leftovers
     * keep the tolerated-leak behavior. */
    trace_shutdown();
    gc_collect_at_exit(global);
    env_decref(global);
    g_global_env = NULL;
    eigs_thread_detach();
    eigs_state_destroy(eigs_st);
    return exit_code;
}
