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
    register_builtins(global);
    register_store_builtins(global);
    g_global_env = global;
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

EigsValue *eigs_eval_string(const char *src) {
    if (!src || !eigs_current || !g_global_env) return NULL;
    Env *global = g_global_env;

    g_parse_errors = 0;
    g_has_error = 0;

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
    EigsChunk *chunk = compile_ast(ast, global);

    Value *result = vm_execute(chunk, global);
    chunk_free(chunk);
    free_ast(ast);
    free_tokenlist(&tl);

    if (g_has_error) {
        if (result) val_decref(result);
        return NULL;
    }
    return result;
}

EigsValue *eigs_eval_file(const char *path) {
#if EIGENSCRIPT_FREESTANDING
    (void)path;
    return NULL;   /* no filesystem — embed callers pass source strings */
#else
    if (!path || !eigs_current) return NULL;
    /* Update script_dir so `import` / `load_file` inside the source can
     * resolve relative paths the same way the CLI does. */
    const char *last_slash = strrchr(path, '/');
    if (last_slash) {
        size_t dir_len = (size_t)(last_slash - path);
        if (dir_len >= sizeof(g_script_dir)) dir_len = sizeof(g_script_dir) - 1;
        memcpy(g_script_dir, path, dir_len);
        g_script_dir[dir_len] = '\0';
    } else {
        memcpy(g_script_dir, ".", 2);
    }

    long size = 0;
    char *src = read_file_util(path, &size);
    if (!src) return NULL;
    EigsValue *r = eigs_eval_string(src);
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

void eigs_clear_error(void) {
    if (!eigs_current) return;
    g_has_error = 0;
    g_error_msg[0] = '\0';
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
        default:          return EIGS_TYPE_OTHER;
    }
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
