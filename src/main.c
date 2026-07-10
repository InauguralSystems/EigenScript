/*
 * EigenScript CLI — script runner and REPL entry point.
 */

#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "trace.h"
#include "repl.h"
#if EIGENSCRIPT_EXT_GFX
void register_gfx_builtins(Env *env);
#endif

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

/* ---- Main ---- */
/* The REPL (piped loop + the #392 interactive line editor) lives in repl.c. */

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
    /* `--trace <path> <script...>`: record this run's tape to <path>, the CLI
     * twin of EIGS_TRACE (which trace_init reads below). Set before trace_init
     * and strip the two tokens so the rest of arg handling sees the script at
     * argv[1]. Used by `--test --trace-on-fail` to give each test its own tape;
     * the flag is authoritative (overwrites any inherited EIGS_TRACE) so each
     * child records to its own tape, not a shared inherited one. */
    if (argc >= 3 && strcmp(argv[1], "--trace") == 0) {
        setenv("EIGS_TRACE", argv[2], 1);
        for (int i = 1; i + 2 < argc; i++) argv[i] = argv[i + 2];
        argc -= 2;
    }

    /* --version doesn't touch the runtime; handle it before any state —
     * including trace_init: a stale EIGS_REPLAY in the environment is a
     * fatal header check (#411) and must not take down pure queries. */
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
            "  eigenscript --lint [--json] [--lint-level error|warning] <file>\n"
            "                                      lint a source file (--json machine-readable; --lint-level error = warnings advisory;\n"
            "                                      '# lint: allow W001' suppresses a code inline)\n"
            "  eigenscript --test [paths...]       run test_*.eigs files (--json for machine-readable results)\n"
            "     ... --trace-on-fail              record each test; a failure prints its EIGS_REPLAY reproducer\n"
            "  eigenscript --trace <tape> <file>   run and record a replay tape (CLI twin of EIGS_TRACE)\n"
            "  eigenscript --step <tape> [file]    interactive tape-stepper: step forward/back, bindings +\n"
            "                                      trajectories, breakpoints (docs/DEBUGGING.md)\n"
            "  eigenscript --pkg <cmd> [args...]   package manager (add/install/update/verify; see docs)\n"
            "  eigenscript --version, -v           print the version and exit\n"
            "  eigenscript --help, -h              print this help and exit\n"
            "\n"
            "Docs: https://github.com/InauguralSystems/EigenScript\n",
            EIGENSCRIPT_VERSION);
        return 0;
    }

    /* --step: the #418 tape-stepper — a pure tape READER (nothing executes).
     * Handled before trace_init for the same reason as --version: a stale
     * EIGS_REPLAY in the environment is a fatal header check (#411) and must
     * not take down a viewer that never replays. It does need an attached
     * EigsState: the trajectory classifier reads the observer thresholds. */
    if (argc >= 2 && strcmp(argv[1], "--step") == 0) {
        if (argc < 3) {
            fprintf(stderr, "Usage: eigenscript --step <tape> [source.eigs]\n");
            return 1;
        }
        EigsState *step_st = eigs_state_new();
        eigs_thread_attach(step_st);
        int rc = eigenscript_step(argv[2], argc >= 4 ? argv[3] : NULL);
        eigs_thread_detach();
        eigs_state_destroy(step_st);
        return rc;
    }

    trace_init();
    atexit(trace_shutdown);

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
        int fail_on_warning = 1;   /* --lint-level warning (default) */
        const char *lint_path = NULL;
        for (int i = 2; i < argc; i++) {
            if (strcmp(argv[i], "--json") == 0) {
                json_mode = 1;
            } else if (strcmp(argv[i], "--lint-level") == 0 && i + 1 < argc) {
                const char *lvl = argv[++i];
                if (strcmp(lvl, "error") == 0) {
                    fail_on_warning = 0;   /* warnings advisory; only errors fail */
                } else if (strcmp(lvl, "warning") == 0) {
                    fail_on_warning = 1;
                } else {
                    fprintf(stderr, "Unknown --lint-level '%s' (use error|warning)\n", lvl);
                    eigs_thread_detach();
                    eigs_state_destroy(eigs_st);
                    return 1;
                }
            } else if (!lint_path) {
                lint_path = argv[i];
            }
        }
        if (!lint_path) {
            fprintf(stderr, "Usage: eigenscript --lint [--json] [--lint-level error|warning] file.eigs\n");
            eigs_thread_detach();
            eigs_state_destroy(eigs_st);
            return 1;
        }
        int rc = eigenscript_lint(lint_path, json_mode, fail_on_warning);
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
    parser_set_caret_source(source);   /* #407: excerpt+caret on col errors */
    ASTNode *ast = parse(&tl);
    parser_set_caret_source(NULL);
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
    /* #493: capture whether any worker died of an uncaught error without ever
     * being joined — must be read BEFORE handle_table_drain frees the tasks. */
    int unobserved_task_error = task_any_unobserved_error();
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
    int exit_code = g_exit_requested ? g_exit_code
                    : ((g_has_error || unobserved_task_error) ? 1 : 0);
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
