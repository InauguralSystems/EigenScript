/*
 * EigenScript WASM entry — replaces main.c for the browser playground build.
 *
 * Exposes a single function, eigs_run_source(const char *src), that
 * tokenizes/parses/compiles/executes a script in-process and returns the
 * exit status. Output goes through printf, which emcc routes to the
 * Module.print / Module.printErr callbacks provided by the JS host.
 *
 * The JIT is arch-gated in src/jit.c (`#if defined(__x86_64__)`), so the
 * WASM build is interpreter-only at compile time — no runtime guard
 * needed. POSIX builtins that touch fork/exec/sockets/threads (proc_*,
 * exec_capture, spawn, http server, raw socket) will compile under
 * emscripten but fail at runtime; the playground doesn't expose those
 * surfaces.
 */

#include <emscripten.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/eigenscript.h"
#include "../src/state.h"
#include "../src/vm.h"
#include "../src/trace.h"

static int g_initialized = 0;

static void ensure_init(void) {
    if (g_initialized) return;
    /* One EigsState/Thread for the lifetime of the playground module.
     * arena_init runs inside eigs_thread_attach. g_script_dir / g_exe_dir
     * are EigsState bridge macros — write the playground defaults after
     * attach. */
    EigsState *st = eigs_state_new();
    eigs_thread_attach(st);
    memcpy(g_exe_dir, "/eigs", 6);
    trace_init();
    g_initialized = 1;
}

EMSCRIPTEN_KEEPALIVE
int eigs_run_source(const char *source) {
    if (!source) return 1;
    ensure_init();

    /* Fresh global env per run — the playground treats each execution as
     * a clean session. The previous run's closures, globals, and trace
     * tape are reclaimed below. */
    Env *global = env_new(NULL);
    register_builtins(global);
    register_store_builtins(global);
    g_global_env = global;

    /* Minimal argv so eigenscript_set_args doesn't see a NULL pointer.
     * The playground has no real argv; expose a single virtual arg so
     * any builtin that reads `args` gets a defined list. */
    char *argv[] = { (char *)"eigs-playground", NULL };
    eigenscript_set_args(1, argv);

    g_parse_errors = 0;
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0) {
        fprintf(stderr, "%d parse error(s) — aborting\n", g_parse_errors);
        free_ast(ast);
        free_tokenlist(&tl);
        gc_collect_at_exit(global);
        env_decref(global);
        g_global_env = NULL;
        return 1;
    }

    g_compile_module_slots = 1;
    EigsChunk *script_chunk = compile_ast(ast, global, source);
    g_compile_module_slots = 0;

    Value *result = vm_execute(script_chunk, global);
    if (result) val_decref(result);
    int exit_code = g_has_error ? 1 : 0;
    eigs_clear_error_value();
    chunk_free(script_chunk);

    free_ast(ast);
    free_tokenlist(&tl);
    gc_collect_at_exit(global);
    env_decref(global);
    g_global_env = NULL;

    /* Force the printf buffer to JS console before returning. */
    fflush(stdout);
    fflush(stderr);

    return exit_code;
}

EMSCRIPTEN_KEEPALIVE
const char *eigs_version(void) {
    return EIGENSCRIPT_VERSION;
}
