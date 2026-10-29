/*
 * EigenScript CLI — script runner and REPL entry point.
 */

#include "eigenscript.h"
#include "env_flag.h"
#include "fsutil.h"
#include "state.h"
#include "vm.h"
#include "trace.h"
#include "repl.h"

#ifdef EIGS_TSAN_TEST_SEAM
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>

/* #2052: planted weak-memory positive control.  This intentionally omits the
 * release/acquire edge that must publish tsan_probe_payload.  It exists only
 * in TSan variants and is reachable only through the private test switch. */
static atomic_int tsan_probe_published;
static int tsan_probe_payload;

static void *tsan_probe_publish(void *unused) {
    (void)unused;
    tsan_probe_payload = 2052;
    atomic_store_explicit(&tsan_probe_published, 1, memory_order_relaxed);
    return NULL;
}

static void *tsan_probe_consume(void *unused) {
    (void)unused;
    while (!atomic_load_explicit(&tsan_probe_published,
                                 memory_order_relaxed)) { }
    return (void *)(uintptr_t)tsan_probe_payload;
}

static int tsan_misordered_publish_control(void) {
    pthread_t publisher, consumer;
    void *observed = NULL;
    atomic_store_explicit(&tsan_probe_published, 0, memory_order_relaxed);
    tsan_probe_payload = 0;
    if (pthread_create(&consumer, NULL, tsan_probe_consume, NULL) != 0)
        return 2;
    if (pthread_create(&publisher, NULL, tsan_probe_publish, NULL) != 0) {
        atomic_store_explicit(&tsan_probe_published, 1, memory_order_relaxed);
        (void)pthread_join(consumer, NULL);
        return 2;
    }
    if (pthread_join(publisher, NULL) != 0 ||
        pthread_join(consumer, &observed) != 0)
        return 2;
    return (uintptr_t)observed == 2052 ? 0 : 1;
}

/* #2071: gate-liveness control. Both workers exist before either is joined,
 * so pthread lifecycle edges do not order these writes. Unlike the former
 * language-level control, captured-binding lookup cannot add a runtime lock
 * (and an accidental happens-before edge) around this location. */
static volatile int tsan_seeded_race_word;

static void *tsan_seeded_race_write(void *value) {
    tsan_seeded_race_word = (int)(uintptr_t)value;
    return NULL;
}

static int tsan_seeded_race_control(void) {
    pthread_t first, second;
    tsan_seeded_race_word = 0;
    if (pthread_create(&first, NULL, tsan_seeded_race_write,
                       (void *)(uintptr_t)1) != 0)
        return 2;
    if (pthread_create(&second, NULL, tsan_seeded_race_write,
                       (void *)(uintptr_t)2) != 0) {
        (void)pthread_join(first, NULL);
        return 2;
    }
    if (pthread_join(first, NULL) != 0 || pthread_join(second, NULL) != 0)
        return 2;
    return 0;
}

/* #2129: deterministic positive/clean control for #2090's env-count read.
 * The relaxed rendezvous guarantees that the reader has accessed count before
 * the writer appends, but deliberately gives TSan no happens-before edge. */
typedef struct {
    EigsState *state;
    Env *env;
    atomic_int reader_started;
    atomic_int writer_done;
} TSanEnvCountControl;

static void *tsan_env_count_reader(void *opaque) {
    TSanEnvCountControl *control = opaque;
    eigs_thread_attach(control->state);
    (void)env_count_shared(control->env);
    atomic_store_explicit(&control->reader_started, 1, memory_order_relaxed);
    while (!atomic_load_explicit(&control->writer_done,
                                 memory_order_relaxed))
        (void)env_count_shared(control->env);
    eigs_thread_detach();
    return NULL;
}

static void *tsan_env_count_writer(void *opaque) {
    TSanEnvCountControl *control = opaque;
    eigs_thread_attach(control->state);
    while (!atomic_load_explicit(&control->reader_started,
                                 memory_order_relaxed)) { }
    Value *value = make_num(2129);
    env_set_local_hashed(control->env, "issue_2129", 0, value);
    val_decref(value);
    atomic_store_explicit(&control->writer_done, 1, memory_order_relaxed);
    eigs_thread_detach();
    return NULL;
}

static int tsan_compiler_env_count_control(void) {
    EigsState *state = eigs_state_new();
    eigs_thread_attach(state);
    state->multithreaded = 1;
    TSanEnvCountControl control = {
        .state = state,
        .env = env_new(NULL),
        .reader_started = ATOMIC_VAR_INIT(0),
        .writer_done = ATOMIC_VAR_INIT(0),
    };
    pthread_t reader, writer;
    int rc = 0;
    if (pthread_create(&reader, NULL, tsan_env_count_reader, &control) != 0) {
        rc = 2;
    } else if (pthread_create(&writer, NULL, tsan_env_count_writer,
                              &control) != 0) {
        atomic_store_explicit(&control.writer_done, 1, memory_order_relaxed);
        (void)pthread_join(reader, NULL);
        rc = 2;
    } else if (pthread_join(reader, NULL) != 0 ||
               pthread_join(writer, NULL) != 0) {
        rc = 2;
    }
    env_decref(control.env);
    eigs_thread_detach();
    eigs_state_destroy(state);
    return rc;
}
#endif

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

/* #413 bundle entry points (src/bundle.c, CLI-only) — declared at file
 * scope; block-scope function declarations trip cpp/function-in-block. */
extern int eigs_bundle_selfexec(int *argc, char ***argv);
extern int eigs_bundle_create(const char *argv0, const char *script,
                              const char *outpath, const char *tape);

/* ---- Main ---- */
/* The REPL (piped loop + the #392 interactive line editor) lives in repl.c. */

static void set_exe_dir(const char *argv0) {
    if (!g_exe_path) g_exe_path = eigs_executable_path(argv0);
    if (!g_exe_path) return;
    const char *last_slash = strrchr(g_exe_path, '/');
    if (!last_slash) return;
    size_t dir_len = last_slash == g_exe_path ? 1 : (size_t)(last_slash - g_exe_path);
    /* Never turn an overlong anchor into a different, truncated directory. */
    if (dir_len >= sizeof(g_exe_dir)) return;
    memcpy(g_exe_dir, g_exe_path, dir_len);
    g_exe_dir[dir_len] = '\0';
}

int main(int argc, char **argv) {
#ifdef EIGS_TSAN_TEST_SEAM
    if (getenv("EIGS_TSAN_SEEDED_RACE_CONTROL"))
        return tsan_seeded_race_control();
    if (getenv("EIGS_TSAN_MISORDERED_PUBLISH_CONTROL"))
        return tsan_misordered_publish_control();
    if (getenv("EIGS_TSAN_COMPILER_ENV_COUNT_CONTROL"))
        return tsan_compiler_env_count_control();
#endif
    /* EIGS_SEED_RANDOM=<integer> (#2120): seed the shared random stream before
     * any program code runs, through seed_random's own path, so every run with
     * one value draws one sequence (differential testing, reproduction). A
     * malformed value is a startup error here: never a silent fallback to the
     * clock, and never an exit from inside the runtime, which embedders share. */
    {
        const char *seed_env = getenv("EIGS_SEED_RANDOM");
        if (seed_env && *seed_env) {   /* empty means unset, as for EIGS_* flags */
            char *end = NULL;
            errno = 0;
            long seed = strtol(seed_env, &end, 10);
            if (errno == ERANGE || end == seed_env || *end != '\0') {
                fprintf(stderr, "EIGS_SEED_RANDOM: invalid integer: %s\n", seed_env);
                return 2;
            }
            eigs_seed_random(seed);
        }
    }
    /* #413: a bundled binary (appended archive, trailer magic) extracts
     * itself and rewrites argv to run the extracted script — before ANY
     * flag handling, because in bundle mode the arguments belong to the
     * bundled script (only `--replay` is ours). */
    eigs_bundle_selfexec(&argc, &argv);

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

    /* Machine-readable build capabilities.  Keep the JIT value on the same
     * compile-time gate as jit.c's emitter; callers must not infer a binary's
     * capabilities from the machine on which it happens to run. */
    if (argc >= 2 && strcmp(argv[1], "--build-info") == 0) {
#if EIGS_JIT_ENABLED
        printf("jit-backend=x86-64\n");
#else
        printf("jit-backend=none\n");
#endif
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
            "  eigenscript --json <file.eigs>      run with one JSON object on stderr for an uncaught error\n"
            "  eigenscript -e <source> [args...]   run a source string\n"
            "  eigenscript                         start the REPL\n"
            "  eigenscript --fmt [--write] <file>  format a source file (stdout, or rewrite with --write)\n"
            "  eigenscript --dump-tokens <file>    dump lexer type, value and source line (no execution)\n"
            "  eigenscript --lint [--json] [--lint-level error|warning] <file>\n"
            "                                      lint a source file (--json machine-readable; --lint-level error = warnings advisory;\n"
            "                                      '# lint: allow W001' suppresses a code inline)\n"
            "  eigenscript --api [--json]          surface index: every builtin, extension (by group), and\n"
            "                                      lib function with params — 'does X exist' in one call\n"
            "  eigenscript --test [paths...]       run test_*.eigs files (--json for machine-readable results)\n"
            "     ... --trace-on-fail              record each test; a failure prints its EIGS_REPLAY reproducer\n"
            "  eigenscript --trace <tape> <file>   run and record a replay tape (CLI twin of EIGS_TRACE)\n"
            "  eigenscript --step <tape> [file]    interactive tape-stepper: step forward/back, bindings +\n"
            "                                      trajectories, breakpoints (docs/DEBUGGING.md)\n"
            "  eigenscript --pkg <cmd> [args...]   package manager (add/install/update/verify; see docs)\n"
            "  eigenscript --bundle <file> <out> [--with-tape <tape>]\n"
            "                                      single-file executable: runtime + script + eigs_modules +\n"
            "                                      stdlib (+ optional tape: `out --replay` re-runs it exactly)\n"
            "  eigenscript --version, -v           print the version and exit\n"
            "  eigenscript --build-info            print machine-readable build capabilities\n"
            "  eigenscript --help, -h              print this help and exit\n"
            "\n"
            "Docs: https://github.com/InauguralSystems/EigenScript\n",
            EIGENSCRIPT_VERSION);
        return 0;
    }

    /* #413 --bundle: pure file I/O — copies our own binary and appends
     * the archive; nothing executes. Needs g_exe_dir for the stdlib dir. */
    if (argc >= 2 && strcmp(argv[1], "--bundle") == 0) {
        if (argc < 4) {
            fprintf(stderr, "Usage: eigenscript --bundle <file.eigs> <out> "
                            "[--with-tape <tape>]\n");
            return 1;
        }
        const char *bundle_tape = NULL;
        if (argc >= 6 && strcmp(argv[4], "--with-tape") == 0)
            bundle_tape = argv[5];
        return eigs_bundle_create(argv[0], argv[2], argv[3], bundle_tape);
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

    /* --fmt is a pure source transformer; no VM and no state.
     * Handled before trace_init like --step: nothing executes, so an
     * inherited EIGS_REPLAY must not fail it and an inherited EIGS_TRACE
     * must not truncate that tape file (#1238). */
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

    /* Machine-readable lexer fingerprint used by the formatter safety gate.
     * Values are hex bytes, so quotes, newlines and CR are unambiguous. */
    if (argc >= 2 && strcmp(argv[1], "--dump-tokens") == 0) {
        if (argc != 3) {
            fprintf(stderr, "Usage: eigenscript --dump-tokens file.eigs\n");
            return 1;
        }
        long size = 0;
        char *source = read_file_util(argv[2], &size);
        if (!source) {
            fprintf(stderr, "Error: cannot read file '%s'\n", argv[2]);
            return 1;
        }
        EigsState *dump_st = eigs_state_new();
        eigs_thread_attach(dump_st);
        g_parse_errors = 0;
        TokenList tl = tokenize(source);
        int rc = g_parse_errors ? 1 : 0;
        if (!rc) for (int i = 0; i < tl.count; i++) {
            Token *t = &tl.tokens[i];
            printf("%d\t", (int)t->type);
            if (t->type == TOK_NUM) printf("%a", t->num_val);
            else if (t->str_val) {
                const unsigned char *p = (const unsigned char *)t->str_val;
                while (*p) printf("%02x", *p++);
            }
            printf("\t%d\n", t->line);
        }
        free_tokenlist(&tl);
        free(source);
        eigs_thread_detach();
        eigs_state_destroy(dump_st);
        return rc;
    }

    /* #972: EIGS_OBS_GATE_STATS=1 also tallies observe-helper entries (the
     * per-unit verdict lines come from compile_ast); reported at exit so a
     * read-free program can be checked for `observe-calls 0`. */
    if (eigs_env_flag("EIGS_OBS_GATE_STATS")) {
        g_obs_count_observe_calls = 1;
        atexit(eigs_obs_gate_stats_report);
    }

    /* Everything below uses g_script_dir / g_exe_dir / g_global_env,
     * which are EigsState bridge macros — attach before computing. */
    EigsState *eigs_st = eigs_state_new();
    eigs_thread_attach(eigs_st);

    /* Ordinary runs follow `--lint --json`: opt in with the same flag and
     * remove it before script argument handling. Modes above own their own
     * --json contracts and have already returned. */
    if (argc >= 2 && strcmp(argv[1], "--json") == 0) {
        g_json_diagnostics = 1;
        for (int i = 1; i + 1 < argc; i++) argv[i] = argv[i + 1];
        argc--;
        argv[argc] = NULL;
    }
    /* The CLI's main attachment is the tape opener. Native embedders that
     * deliberately open a tape before attaching retain their separate zero. */
    trace_init();
    atexit(trace_shutdown);
    set_exe_dir(argc > 0 ? argv[0] : NULL);

    /* #660: SIGUSR1 live observer dump — an outside process can ask a
     * long-running program whether it is progressing. SA_RESTART so an
     * interrupted blocking syscall (channel recv, proc read) resumes; the
     * handler only raises a flag consumed at the next loop safepoint. */
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = eigs_sigusr1_handler;
        sigemptyset(&sa.sa_mask);
        sa.sa_flags = SA_RESTART;
        sigaction(SIGUSR1, &sa, NULL);
    }

    /* #1121: every `--<mode>` return below happens BEFORE the run path's
     * global Env exists, so none of them can call gc_collect_at_exit(global)
     * the way the two returns at the bottom of this function do — and all of
     * them were therefore skipping the cycle-collector drain entirely.
     * That drain is not optional bookkeeping: val_decref on a LIST or DICT
     * does not free it, it registers a candidate that only the exit sweep
     * reclaims. So anything a mode allocated as a container leaked, and
     * `--lint` leaked the parsed eigs.json on every run inside a project whose
     * manifest has any nested value -- `"deps": {}` is enough, and that is in
     * the manifest every repo in the fleet ships.
     *
     * gc_collect_at_exit tolerates a NULL global: it guards every deref of it,
     * and the module-cache clear plus the gc_collect_cycles drain -- the half
     * these paths need -- run unconditionally.
     *
     * Route EVERY pre-global return through here rather than patching the one
     * that leaks today, so the next mode that allocates a container cannot
     * reintroduce this by forgetting a line. */
    #define MODE_EXIT(rc_) do { \
        gc_collect_at_exit(NULL); \
        eigs_thread_detach(); \
        eigs_state_destroy(eigs_st); \
        return (rc_); \
    } while (0)

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
                    MODE_EXIT(1);
                }
            } else if (!lint_path) {
                lint_path = argv[i];
            }
        }
        if (!lint_path) {
            fprintf(stderr, "Usage: eigenscript --lint [--json] [--lint-level error|warning] file.eigs\n");
            MODE_EXIT(1);
        }
        int rc = eigenscript_lint(lint_path, json_mode, fail_on_warning);
        MODE_EXIT(rc);
    }

    /* #734 --api: the machine-readable surface index. Answers "does X
     * exist, and is it builtin / extension / lib" in one call instead of
     * a text search across BUILTINS.md + STDLIB.md. Same shape as --lint:
     * --json for machines, plain lines (greppable) otherwise. */
    if (argc >= 2 && strcmp(argv[1], "--api") == 0) {
        int api_json = (argc >= 3 && strcmp(argv[2], "--json") == 0);
        int rc = eigs_api_dump(stdout, api_json);
        MODE_EXIT(rc);
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
            MODE_EXIT(1);
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
            MODE_EXIT(1);
        }
        argv[1] = test_path;
        /* fall through to script execution */
    }

    /* No arguments: enter REPL */
    if (argc < 2) {
        eigenscript_set_args(argc, argv);

        Env *global = eigs_global_env_create();   /* + builtin layer (#1388) */

        eigenscript_repl(global);
        /* #1811: every way out of eigenscript_repl (plain/editor EOF,
         * `exit`/`quit`, requested `exit of N`, including an eventual exit
         * after a recoverable evaluation error) joins here. Match file
         * execution while the value world is still alive; workers may also
         * publish an exit code before the join completes. */
        handle_table_drain(eigs_st);
        /* #739: take the exit code BEFORE teardown. It is a bridge macro now
         * (state latch, reached through eigs_current), so eigs_thread_detach
         * below leaves nothing to read it through — the script path at the
         * bottom of main already captures it first, for the same reason. */
        int repl_exit_code = eigs_state_graceful_exit_code(eigs_st);
        (void)eigs_state_exit_requested(eigs_st, &repl_exit_code);
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
        return repl_exit_code;
    }

    /* Source strings use the same parse/compile/execute path as files.
     * Keep argv[1] as the source identity and strip only the source argument
     * from the script-visible args; relative loads start at the caller cwd. */
    int source_string = strcmp(argv[1], "-e") == 0;
    if (source_string && argc < 3) {
        fprintf(stderr, "Usage: eigenscript -e <source> [args...]\n");
        MODE_EXIT(1);
    }

    /* Private verdict-calibration side channel (#2059).  lib/test.eigs owns
     * the ledger write; give that seam the actual program operand rather than
     * making every suite invocation remember to repeat it. */
    if (!source_string && getenv("EIGS_TEST_FORCE_SUMMARY_LEDGER"))
        setenv("EIGS_TEST_SCRIPT_PATH", argv[1], 1);

    /* Extract script directory for load_file resolution. g_script_dir
     * is an EigsState bridge macro — state is already attached above. */
    {
        char *dir = eigs_file_directory(argv[1]);
        snprintf(g_script_dir, sizeof(g_script_dir), "%s", dir);
        free(dir);
    }

    long src_size = 0;
    char *source = source_string ? xstrdup(argv[2])
                                 : read_file_util(argv[1], &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", argv[1]);
        MODE_EXIT(1);
    }

    /* Past this point the run path owns a global Env, so a teardown must
     * collect against IT (gc_collect_at_exit(global)) rather than the NULL
     * form. Undefining the macro makes that a compile error rather than a
     * silently weaker drain. */
    #undef MODE_EXIT

    if (source_string) {
        for (int i = 2; i + 1 < argc; i++) argv[i] = argv[i + 1];
        argv[--argc] = NULL;
    }
    eigenscript_set_args(argc, argv);

    Env *global = eigs_global_env_create();   /* + builtin layer (#1388) */

    g_parse_errors = 0;
    /* Parser diagnostics predate the structured recorder and are emitted at
     * their discovery sites. In JSON mode mute only this parse pass; the
     * recorder below supplies its single canonical diagnostic. */
    int parse_stderr = -1;
    FILE *parse_sink = NULL;
    if (g_json_diagnostics) {
        fflush(stderr);
        parse_stderr = dup(STDERR_FILENO);
        parse_sink = tmpfile();
        if (parse_stderr >= 0 && parse_sink)
            (void)dup2(fileno(parse_sink), STDERR_FILENO);
    }
    TokenList tl = tokenize(source);
    parser_set_caret_source(source);   /* #407: excerpt+caret on col errors */
    ASTNode *ast = parse(&tl);
    parser_set_caret_source(NULL);
    if (g_json_diagnostics) {
        fflush(stderr);
        if (parse_stderr >= 0) {
            (void)dup2(parse_stderr, STDERR_FILENO);
            close(parse_stderr);
        }
        if (parse_sink) fclose(parse_sink);
    }
    if (g_parse_errors > 0) {
        if (g_json_diagnostics) {
            strbuf js;
            strbuf_init(&js);
            strbuf_append(&js, "{\"version\":1,\"code\":\"");
            eigs_json_escape_append(&js, g_first_error_code ? g_first_error_code : "E002", SIZE_MAX);
            strbuf_append(&js, "\",\"kind\":\"parse\",\"message\":\"");
            eigs_json_escape_append(&js, g_first_error_msg[0] ? g_first_error_msg : "parse error", SIZE_MAX);
            strbuf_append(&js, "\",\"file\":\"");
            eigs_json_escape_append(&js, source_string ? "<eval>" : argv[1], SIZE_MAX);
            strbuf_append_fmt(&js, "\",\"line\":%d,\"column\":%d,\"span\":%d,\"frames\":[]}\n",
                              g_first_error_line,
                              g_first_error_col_known ? g_first_error_col + 1 : 0,
                              g_first_error_col_known ? g_first_error_len : 0);
            fputs(js.data, stderr);
            strbuf_free(&js);
        } else {
            fprintf(stderr, "%d parse error(s) — aborting\n", g_parse_errors);
        }
        free_ast(ast);  /* parse returns a partial tree on error; free it (cf. #214) */
        free(source);
        free_tokenlist(&tl);
        /* #1121: the success returns below collect before releasing the
         * global; these error returns did not. Nothing container-shaped is
         * rooted here today (measured clean under ASan), so this is a no-op
         * now and the class stays closed if that changes. */
        gc_collect_at_exit(global);
        env_decref(global);
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return 1;
    }
    g_compile_module_slots = 1;
    EigsChunk *script_chunk = compile_ast(ast, global, source, source_string ? "<eval>" : argv[1]);
    g_compile_module_slots = 0;
    if (g_parse_errors > 0) {   /* compile-stage error, e.g. un-encodable jump */
        fprintf(stderr, "%d compile error(s) — aborting\n", g_parse_errors);
        chunk_free(script_chunk);
        free_ast(ast);
        free(source);
        free_tokenlist(&tl);
        /* #1121: the success returns below collect before releasing the
         * global; these error returns did not. Nothing container-shaped is
         * rooted here today (measured clean under ASan), so this is a no-op
         * now and the class stays closed if that changes. */
        gc_collect_at_exit(global);
        env_decref(global);
        eigs_thread_detach();
        eigs_state_destroy(eigs_st);
        return 1;
    }
    if (eigs_env_flag("EIGS_DUMP_BC")) chunk_disassemble(script_chunk, "<module>");
    Value *result = vm_execute(script_chunk, global);
    if (result) val_decref(result);
    /* #493: capture whether any worker died of an uncaught error without ever
     * being joined — must be read BEFORE handle_table_drain frees the tasks. */
    int unobserved_task_error = task_any_unobserved_error();
    /* Program done: deterministically reap workers and free channels while the
     * value world is still alive (channels/threads live in the handle table,
     * not on a GC'd Value, so nothing else reclaims them). */
    handle_table_drain(eigs_st);
    /* #1112: spawn()ed workers that died of an uncaught error — read AFTER
     * the drain above has joined every worker (pthread_join is the
     * happens-before edge for the worker's increment). */
    int spawn_worker_error = __atomic_load_n(&eigs_st->spawn_err_count, __ATOMIC_RELAXED) > 0;
    /* An uncaught runtime error leaves g_has_error set (vm_run unwinds to
     * here rather than continuing with null). Report it as a non-zero exit
     * so scripts fail loudly for callers, Makefiles, and CI. */
    /* `exit of N` requests a specific code (and unwound via g_has_error); it
     * takes precedence over the generic uncaught-error code. Clear the unwind
     * flag so the teardown below sees a clean state. */
    /* #739/#1149: the CODE comes from the state latch, so `exit of N` inside
     * a worker stops main and decides the process status. The unwind flag is
     * cleared only for an exit request observed on THIS thread. */
    int exit_code = 0;
    if (!eigs_state_exit_requested(eigs_st, &exit_code))
        exit_code = (g_has_error || unobserved_task_error || spawn_worker_error)
                  ? 1 : eigs_state_graceful_exit_code(eigs_st);
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
