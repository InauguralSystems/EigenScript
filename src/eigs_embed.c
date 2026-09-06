/*
 * eigs_embed.c — Phase 10 embedding API implementation.
 *
 * Thin wrappers over the internal runtime: most calls forward to
 * make_*, env_*, tokenize/parse/compile/vm_execute already exposed by
 * eigenscript.h / vm.h / state.h. The point is the *contract* — opaque
 * types, ref-count-clean ownership rules, error retrieval that matches
 * the multi-state model — not new behavior.
 */
#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "trace.h"
#include "eigs_embed.h"

/* ---- Lifecycle ---------------------------------------------------- */

int eigs_state_init_runtime(EigsState *st) {
    if (!st) return -1;
    if (!eigs_current || eigs_current->state != st) return -1;
    if (g_global_env) return 0;
    Env *global = env_new(NULL);
    if (!global) return -1;
    register_builtins(global);   /* one seam: store/gfx ride inside (#742) */
    g_global_env = global;
    /* #1038: a module compiled later cannot classify the surrounding native
     * host. Pin default embedding open; only the explicit eval opt-in may
     * renew permission for a compile verdict. CLI state setup is separate. */
    eigs_obs_enable();
    return 0;
}

EigsState *eigs_open(void) {
    EigsState *st = eigs_state_new();
    if (!st) return NULL;
    if (!eigs_thread_attach(st)) {
        eigs_state_destroy(st);
        return NULL;
    }
    if (eigs_state_init_runtime(st) != 0) {
        eigs_thread_detach();
        eigs_state_destroy(st);
        return NULL;
    }
    return st;
}

void eigs_close(EigsState *st) {
    if (!st) return;
    /* Mirror main.c's teardown order. #301: drain the handle table FIRST — reap
     * any spawned workers (join after closing channels, #303) and free channels.
     * This is also the only place st->multithreaded is cleared back to 0; skip
     * it and gc_collect_at_exit below bails (g_vm_multithreaded), silently
     * collecting nothing, AND channels/threads leak, AND a still-running worker
     * can UAF the env/state we free next. Then: trace tape (its prev-table holds
     * refs whose death can touch the env), collect cycles, drop the creator ref. */
    if (eigs_current && eigs_current->state == st) {
        handle_table_drain(st);
        if (g_global_env) {
            Env *global = g_global_env;
            trace_shutdown();
            gc_collect_at_exit(global);
            env_decref(global);
            g_global_env = NULL;
        }
    }
    eigs_thread_detach();
    eigs_state_destroy(st);
}

/* ---- Eval --------------------------------------------------------- */

void eigs_set_eval_observer_isolated(int enabled) {
    if (eigs_current)
        eigs_current->state->eval_observer_isolated = enabled != 0;
}

static EigsValue *eval_source(const char *src, const char *file_dir) {
    if (!src || !eigs_current || !g_global_env) return NULL;
    Env *global = g_global_env;

    g_parse_errors = 0;
    g_has_error = 0;
    /* #739: don't carry a prior eval's `exit` into this one. CHECK_ERROR makes
     * an exit unwind uncatchable — correct — but the request was never
     * cleared, so after any script called `exit of N` every later eval in this
     * process ran with exception handling silently disabled: a raise inside
     * `try` went to vm_error_halt instead of the catch handler. One line of
     * script permanently corrupted the semantics for a long-lived host running
     * untrusted snippets. g_exit_code needs no reset — builtin_exit always
     * writes it before setting the flag, so it can never be read stale. */
    g_exit_requested = 0;

    TokenList tl = tokenize(src);
    if (g_parse_errors > 0) {
        free_tokenlist(&tl);
        return NULL;
    }

    ASTNode *ast = parse(&tl);
    if (g_parse_errors > 0) {
        free_ast(ast);
        free_tokenlist(&tl);
        return NULL;
    }

    g_returning = 0;
    g_return_val = NULL;

    /* REPL-style compilation: top-level names land in the global env
     * (not module-export slots), so the host can read them back through
     * eigs_get_global and successive eigs_eval_string calls accumulate. */
    /* #1028: only an explicit host promise permits a new compile verdict.
     * Snapshot missing history before resetting this unit's execution latch.
     * A retained function may be invoked without a reader in the new source,
     * so in that case keep the accumulated verdict instead. All boundary
     * resets require exclusive state access; worker arming stays atomic. */
    if (eigs_current->state->eval_observer_isolated &&
        !g_obs_eval_host_callbacks) {
        if (!g_obs_needed && g_obs_exec_started)
            obs_flag_store(obs_history_gap, 1);
        if (!g_obs_eval_retains_code) {
            obs_flag_store(obs_exec_started, 0);
            obs_flag_store(obs_needed, 1);
            obs_flag_store(obs_compile_pending, 1);
        }
    } else {
        eigs_obs_enable();
    }
    /* A file's explicit base must beat a caller frame while compiling, but
     * must never outlive compilation: runtime eval belongs to its own frame.
     * Keep this pair at the compile boundary for both embed entry points. */
    char *saved_dir = file_dir ? xstrdup(g_import_resolve_dir) : NULL;
    if (file_dir)
        snprintf(g_import_resolve_dir, sizeof(g_import_resolve_dir), "%s", file_dir);
    EigsChunk *chunk = compile_ast(ast, global, src);
    if (saved_dir) {
        snprintf(g_import_resolve_dir, sizeof(g_import_resolve_dir), "%s", saved_dir);
        free(saved_dir);
    }

    /* Like load_file, reject conservatively at the compile boundary. The
     * source scan cannot prove which binding a future read will reach. Keep
     * this guard after opt-out as well: arming does not repair past history. */
    int obs_after_compile = obs_flag_load_acquire(obs_needed);
    if (chunk && (chunk_reads_observer(chunk) ||
                  g_obs_eval_host_callbacks) &&
        (!obs_after_compile || g_obs_history_gap)) {
        rt_error(EK_VALUE, 1,
            "embed eval reads observer state, but the observer gate was closed "
            "during an earlier unit; its assignments have no recorded history. "
            "Restart the state with EIGS_OBS_FORCE=1 before the first eval.");
    }
    Value *result = g_has_error || g_parse_errors ? NULL : vm_execute(chunk, global);
    chunk_free(chunk);
    free_ast(ast);
    free_tokenlist(&tl);

    if (g_has_error) {
        if (result) val_decref(result);
        return NULL;
    }
    return result;
}

EigsValue *eigs_eval_string(const char *src) {
    return eval_source(src, NULL);
}

EigsValue *eigs_eval_file(const char *path) {
#if EIGENSCRIPT_FREESTANDING
    (void)path;
    return NULL;   /* no filesystem — embed callers pass source strings */
#else
    if (!path || !eigs_current) return NULL;
    long size = 0;
    char *src = read_file_util(path, &size);
    if (!src) return NULL;
    char *dir = eigs_file_directory(path);
    EigsValue *r = eval_source(src, dir);
    free(dir);
    free(src);
    return r;
#endif /* !EIGENSCRIPT_FREESTANDING */
}

/* ---- Errors ------------------------------------------------------- */

const char *eigs_last_error_message(void) {
    if (!eigs_current) return NULL;
    return g_has_error ? g_error_msg : NULL;
}

int eigs_has_error(void) {
    return (eigs_current && g_has_error) ? 1 : 0;
}

const char *eigs_last_error_kind(void) {
    if (!eigs_current || !g_has_error) return NULL;
    return err_kind_name((ErrKind)g_error_kind);
}

int eigs_last_error_line(void) {
    if (!eigs_current || !g_has_error) return 0;
    return g_error_line;
}

void eigs_clear_error(void) {
    if (!eigs_current) return;
    g_has_error = 0;
    g_error_msg[0] = '\0';
    g_error_raw[0] = '\0';
    g_error_kind = 0;
    g_error_line = 0;
    g_first_error_msg[0] = '\0';
    g_first_error_line = 0;
    eigs_clear_error_value();
}

/* ---- Globals ------------------------------------------------------ */

void eigs_set_global(const char *name, EigsValue *val) {
    if (!name || !val || !eigs_current || !g_global_env) return;
    /* env_set_local incref's its argument — caller's ref is undisturbed,
     * matching the documented contract. */
    env_set_local(g_global_env, name, val);
}

EigsValue *eigs_get_global(const char *name) {
    if (!name || !eigs_current || !g_global_env) return NULL;
    Value *v = env_get(g_global_env, name);
    if (v) val_incref(v);
    return v;
}

/* ---- Values ------------------------------------------------------- */

EigsValue *eigs_value_new_num(double n)         { return make_num(n); }
EigsValue *eigs_value_new_string(const char *s) { return make_str(s ? s : ""); }
EigsValue *eigs_value_new_null(void)            { return make_null(); }
EigsValue *eigs_value_new_list(int capacity)    { return make_list(capacity > 0 ? capacity : 0); }
EigsValue *eigs_value_new_dict(int capacity)    { return make_dict(capacity > 0 ? capacity : 0); }

void eigs_value_retain(EigsValue *v)  { if (v) val_incref(v); }
void eigs_value_release(EigsValue *v) { if (v) val_decref(v); }

EigsValueType eigs_value_type(EigsValue *v) {
    if (!v) return EIGS_TYPE_NULL;
    switch (v->type) {
        case VAL_NUM:     return EIGS_TYPE_NUM;
        case VAL_STR:     return EIGS_TYPE_STR;
        case VAL_LIST:    return EIGS_TYPE_LIST;
        case VAL_DICT:    return EIGS_TYPE_DICT;
        case VAL_NULL:    return EIGS_TYPE_NULL;
        case VAL_FN:
        case VAL_BUILTIN: return EIGS_TYPE_FN;
        case VAL_BUFFER:  return EIGS_TYPE_BUFFER;
        /* No public embed-API mapping. Enumerated rather than covered by a
         * `default:` so -Werror=switch forces a new ValType to choose one. */
        case VAL_JSON_RAW:
        case VAL_TEXT_BUILDER: return EIGS_TYPE_OTHER;
    }
    return EIGS_TYPE_OTHER;   /* unreachable for valid ValType values */
}

double eigs_value_as_num(EigsValue *v) {
    return (v && v->type == VAL_NUM) ? v->data.num : 0.0;
}

const char *eigs_value_as_string(EigsValue *v) {
    return (v && v->type == VAL_STR) ? v->data.str : NULL;
}

int eigs_value_list_len(EigsValue *v) {
    return (v && v->type == VAL_LIST) ? v->data.list.count : 0;
}

EigsValue *eigs_value_list_get(EigsValue *v, int i) {
    if (!v || v->type != VAL_LIST) return NULL;
    if (i < 0 || i >= v->data.list.count) return NULL;
    Value *r = v->data.list.items[i];
    if (r) val_incref(r);
    return r;
}

void eigs_value_list_append(EigsValue *v, EigsValue *item) {
    if (!v || v->type != VAL_LIST || !item) return;
    list_append(v, item);
}

EigsValue *eigs_value_dict_get(EigsValue *v, const char *k) {
    if (!v || v->type != VAL_DICT || !k) return NULL;
    Value *r = dict_get(v, k);
    if (r) val_incref(r);
    return r;
}

void eigs_value_dict_set(EigsValue *v, const char *k, EigsValue *val) {
    if (!v || v->type != VAL_DICT || !k || !val) return;
    dict_set(v, k, val);
}

/* ---- Buffers ------------------------------------------------------- */

EigsValue *eigs_value_new_buffer(int count) {
    if (count < 0) count = 0;
    if (count > 10000000) count = 10000000;  /* same cap as `buffer of n` */
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = count;            /* rows/cols stay 0: unshaped 1-D */
    v->data.buffer.data = xcalloc(count > 0 ? (size_t)count : 1, sizeof(double));
    v->refcount = 1;
    return v;
}

int eigs_value_buffer_len(EigsValue *v) {
    return (v && v->type == VAL_BUFFER) ? v->data.buffer.count : 0;
}

double eigs_value_buffer_get(EigsValue *v, int i) {
    if (!v || v->type != VAL_BUFFER) return 0.0;
    if (i < 0 || i >= v->data.buffer.count) return 0.0;
    return v->data.buffer.data[i];
}

void eigs_value_buffer_set(EigsValue *v, int i, double x) {
    if (!v || v->type != VAL_BUFFER) return;
    if (i < 0 || i >= v->data.buffer.count) return;
    v->data.buffer.data[i] = x;
}

/* ---- Trace tape (record + replay) ---------------------------------- */

void eigs_set_trace_sink(EigsTraceSink cb, void *ud) {
    trace_set_sink(cb, ud);
}

int eigs_set_replay_tape(const char *bytes, size_t len, int strict) {
    return trace_set_replay_mem(bytes, len, strict);
}

int eigs_replay_take(const char *name, EigsValue **out) {
    if (!g_replay_enabled || !out) return 0;
    return trace_replay_take(name, (Value **)out);
}

void eigs_trace_record_nondet(const char *name, EigsValue *v) {
    if (g_trace_enabled) trace_nondet_value(name, (Value *)v);
}

/* ---- Async abort (see eigs_embed.h) -------------------------------- */

void eigs_set_abort_flag(volatile int *flag) {
    /* #410: NULL (unregister) maps to the always-zero sentinel so the
     * pointer is never NULL — both tiers poll with a single deref. */
    g_vm_abort_flag = flag ? flag : &g_vm_abort_never;
}

/* ---- FFI ---------------------------------------------------------- */

void eigs_register_function(const char *name, EigsHostFn fn) {
    if (!name || !fn || !eigs_current || !g_global_env) return;
    /* #1028: a C callback can observe its own assignments, but has no source
     * the compile verdict can inspect. This pin survives enabling isolation
     * after registration. Late registration records the gap; eval's guard
     * refuses to enter opaque host code with incomplete history. */
    obs_flag_store(eval_host_callbacks, 1);
    eigs_obs_enable();
    Value *bv = make_builtin((BuiltinFn)fn);
    env_set_local_owned(g_global_env, name, bv);
}

/* ---- Source provider (the module seam; see eigs_embed.h) ---------- */

static EigsSourceProvider g_source_provider    = 0;
static void              *g_source_provider_ud = 0;

void eigs_set_source_provider(EigsSourceProvider fn, void *userdata) {
    g_source_provider    = fn;
    g_source_provider_ud = userdata;
}

/* Internal: vm.c's IMPORT calls this before (hosted) or instead of
 * (freestanding) the filesystem resolution chain. */
const char *eigs_source_lookup(const char *name) {
    if (!g_source_provider || !name) return 0;
    return g_source_provider(name, g_source_provider_ud);
}
