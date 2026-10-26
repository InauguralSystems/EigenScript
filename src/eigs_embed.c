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
#include "fsutil.h"
#include "state.h"
#include "vm.h"
#include "trace.h"
#include "eigs_embed.h"
#include <stdarg.h>
#include <fenv.h>
#if defined(__x86_64__)
#include <xmmintrin.h>
#endif

/* Every public boundary owns the environment it observes.  In particular, a
 * reentrant call from a callback must not inherit a mode selected temporarily
 * by that callback. */
typedef struct {
    fenv_t env;
    int swapped;
} EmbedFenv;

static int embed_fenv_is_default(void) {
#if defined(__x86_64__)
    unsigned short cw, sw;
    __asm__ volatile ("fnstcw %0" : "=m" (cw));
    __asm__ volatile ("fnstsw %0" : "=am" (sw));
    return _mm_getcsr() == 0x1f80u && cw == 0x037fu && (sw & 0x3fu) == 0;
#elif defined(__aarch64__)
    unsigned long fpcr, fpsr;
    __asm__ volatile ("mrs %0, fpcr" : "=r" (fpcr));
    __asm__ volatile ("mrs %0, fpsr" : "=r" (fpsr));
    return fpcr == 0 && fpsr == 0;
#else
    return 0;
#endif
}

static void embed_fenv_enter(EmbedFenv *state) {
    state->swapped = !embed_fenv_is_default();
    if (state->swapped) {
        fegetenv(&state->env);
        fesetenv(FE_DFL_ENV);
    }
}

static void embed_fenv_leave(EmbedFenv *state) {
    if (state->swapped)
        fesetenv(&state->env);
    else
        /* The fast-path entry proved that every exception flag was clear. */
        feclearexcept(FE_ALL_EXCEPT);
}

/* ---- Lifecycle ---------------------------------------------------- */

int eigs_state_init_runtime(EigsState *st) {
    int result = -1;
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    if (!st) goto out;
    if (!eigs_current || eigs_current->state != st) goto out;
    if (g_global_env) { result = 0; goto out; }
    if (!eigs_global_env_create()) goto out;   /* + builtin layer (#1388) */
    /* #1038: a module compiled later cannot classify the surrounding native
     * host. Pin default embedding open; only the explicit eval opt-in may
     * renew permission for a compile verdict. CLI state setup is separate. */
    eigs_obs_enable_runtime();
    result = 0;
out:
    embed_fenv_leave(&fenv);
    return result;
}

EigsState *eigs_open(void) {
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    EigsState *st = eigs_state_new();
    if (!st) goto out;
    if (!eigs_thread_attach(st)) {
        eigs_state_destroy(st);
        st = NULL;
        goto out;
    }
    if (eigs_state_init_runtime(st) != 0) {
        eigs_thread_detach();
        eigs_state_destroy(st);
        st = NULL;
        goto out;
    }
out:
    embed_fenv_leave(&fenv);
    return st;
}

void eigs_state_set_strict(EigsState *st, int enabled) {
    if (st) st->strict = enabled != 0;
}

void eigs_close(EigsState *st) {
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    if (!st) goto out;
    /* Mirror main.c's teardown order. #301: drain the handle table FIRST — reap
     * any spawned workers (join after closing channels, #303) and free channels.
     * This is also the only place st->multithreaded is cleared back to 0; skip
     * it and gc_collect_at_exit below bails (g_vm_multithreaded), silently
     * collecting nothing, AND channels/threads leak, AND a still-running worker
     * can UAF the env/state we free next. Then: this thread's prev-table (its
     * slots hold refs whose death can touch the env), collect cycles, drop the
     * creator ref.
     *
     * #1143: the process tape is NOT this state's to shut unless this is the
     * last live EigsState. A sibling state still recording would otherwise
     * keep evaluating and emit nothing, with no error. The process owner
     * who wants the tape closed while states remain calls eigs_trace_shutdown. */
    /* Decide-and-decrement is one step under g_attached_lock: the closer
     * that takes the count to zero shuts the tape. Two concurrent closes
     * both reading count==2 used to leave the tape open with zero states. */
    int last_state = eigs_process_state_release();
    if (eigs_current && eigs_current->state == st) {
        handle_table_drain(st);
        if (g_global_env) {
            Env *global = g_global_env;
            /* trace_shutdown includes this attachment's prev-table drain, but
             * it is process-wide and therefore reserved for the last state.
             * A non-last close still has to drop its own trace-held refs
             * before cycle collection: imported module namespaces and their
             * exported functions can both be retained there, making their
             * otherwise-unreachable cycle look externally rooted (#1608). */
            if (last_state) trace_shutdown();
            else trace_thread_release();
            gc_collect_at_exit(global);
            env_decref(global);
            g_global_env = NULL;
        }
    } else if (last_state) {
        trace_shutdown();
    }
    eigs_thread_detach();
    eigs_state_destroy_released(st);
out:
    embed_fenv_leave(&fenv);
}

void eigs_trace_shutdown(void) {
    trace_shutdown();
}

/* ---- Eval --------------------------------------------------------- */

void eigs_set_eval_observer_isolated(int enabled) {
    if (eigs_current)
        eigs_current->state->eval_observer_isolated = enabled != 0;
}

/* Missing-history evidence: a unit that executed while recording was off has
 * assignments no later reader can reconstruct. The flag is sticky and the
 * store is idempotent, so it is safe to record at both the end of the unit
 * (#1114: truthful for a DIRECT host predicate read between units) and the
 * next boundary (the pre-#1114 site, kept for code that executes closed
 * outside eval_source, e.g. a host driving vm_execute itself). */
static void obs_record_closed_execution(void) {
    if (!g_obs_needed && g_obs_exec_started)
        obs_flag_store(obs_history_gap, 1);
}

static EigsValue *eval_source(const char *src, const char *file_dir) {
    if (!src || !eigs_current || !g_global_env) return NULL;
    Env *global = g_global_env;

    g_parse_errors = 0;
    g_has_error = 0;
    /* #739/#1149: a new eval owns a fresh stop scope. Existing workers keep
     * their inherited scope and its immutable exit code until they detach;
     * clearing a shared latch here could revive them or import their late
     * exit into this eval. Host calls into one attachment stay sequential. */
    if (!eigs_current->is_spawn_worker &&
        (!eigs_current->vm || g_vm.frame_count == 0)) {
        g_exit_requested = 0;
        eigs_state_begin_eval(eigs_current->state);
    }
    /* A host callback may evaluate nested source. It is part of the active
     * evaluation, so it shares that scope rather than replacing its caller's. */
    if (eigs_state_exit_requested(eigs_current->state, &g_exit_code)) {
        g_exit_requested = 1;
        g_has_error = 1;
        return NULL;
    }

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
    int host_armed = __atomic_exchange_n(
        &eigs_current->state->obs_host_arm_pending, 0, __ATOMIC_ACQ_REL);
    if (eigs_current->state->eval_observer_isolated &&
        !g_obs_eval_host_callbacks) {
        obs_record_closed_execution();
        if (!g_obs_eval_retains_code) {
            obs_flag_store(obs_exec_started, 0);
            obs_flag_store(obs_needed, 1);
            /* A public host arm applies across this boundary. The compiler's
             * own previous verdict does not carry such a one-unit request. */
            obs_flag_store(obs_compile_pending, !host_armed);
        }
    } else {
        eigs_obs_enable_runtime();
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
    /* #1114: the unit has finished. If it executed with the gate closed, its
     * assignments already have no history -- record that NOW, not at the next
     * boundary, so a host reading observer_predicate_at directly between
     * units sees a truthful flag. Stored even when the unit raised: the
     * assignments before the raise are just as unrecorded. */
    obs_record_closed_execution();
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
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    EigsValue *result = eval_source(src, NULL);
    embed_fenv_leave(&fenv);
    return result;
}

EigsValue *eigs_eval_file(const char *path) {
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    EigsValue *result = NULL;
#if EIGENSCRIPT_FREESTANDING
    (void)path;
    /* no filesystem — embed callers pass source strings */
#else
    if (!path || !eigs_current) goto out;
    long size = 0;
    char *src = read_file_util(path, &size);
    if (!src) goto out;
    char *dir = eigs_file_directory(path);
    result = eval_source(src, dir);
    free(dir);
    free(src);
#endif /* !EIGENSCRIPT_FREESTANDING */
out:
    embed_fenv_leave(&fenv);
    return result;
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

/* #1322: a reserved name (eigs_name_is_reserved) is runtime-internal; the
 * embed API refuses to bind or read it, reporting through the pending error
 * like any other bad input. Returns 1 when refused. */
static int embed_refuse_reserved(const char *api, const char *name) {
    if (!eigs_name_is_reserved(name)) return 0;
    rt_error(EK_VALUE, 0, "%s: '%s' is a reserved runtime name", api, name);
    return 1;
}

void eigs_set_global(const char *name, EigsValue *val) {
    if (!name || !val || !eigs_current || !g_global_env) return;
    if (embed_refuse_reserved("eigs_set_global", name)) return;
    /* env_set_local incref's its argument — caller's ref is undisturbed,
     * matching the documented contract. */
    env_set_local(g_global_env, name, val);
}

EigsValue *eigs_get_global(const char *name) {
    if (!name || !eigs_current || !g_global_env) return NULL;
    if (embed_refuse_reserved("eigs_get_global", name)) return NULL;
    Value *v = env_get(g_global_env, name);
    if (v) val_incref(v);
    return v;
}

/* ---- Values ------------------------------------------------------- */

EigsValue *eigs_value_new_num(double n)         { return make_num(n); }
EigsValue *eigs_value_new_string(const char *s) { return make_str(s ? s : ""); }
EigsValue *eigs_value_new_null(void)            { return make_null(); }
EigsValue *eigs_value_new_bool(int b)           { return make_bool(b != 0); }
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
        case VAL_BOOL:    return EIGS_TYPE_BOOL;   /* #1637 */
        /* No public embed-API mapping. Enumerated rather than covered by a
         * `default:` so -Werror=switch forces a new ValType to choose one. */
        case VAL_TEXT_BUILDER: return EIGS_TYPE_OTHER;
    }
    return EIGS_TYPE_OTHER;   /* unreachable for valid ValType values */
}

/* #1925/#1932: a bad value access is reported through the pending error, as
 * #1322's embed_refuse_reserved does. A thread with no attached state has no
 * error channel (eigs_has_error answers 0 there), so it gets the sentinel
 * alone rather than a write through a NULL eigs_current. */
static void embed_value_error(ErrKind kind, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
static void embed_value_error(ErrKind kind, const char *fmt, ...) {
    if (!eigs_current) return;
    char msg[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    rt_error(kind, 0, "%s", msg);
}

int eigs_value_as_bool(EigsValue *v) {
    if (!v || v->type != VAL_BOOL) {
        embed_value_error(EK_TYPE, "eigs_value_as_bool: expected a bool");
        return 0;
    }
    return v->data.boolean;
}

/* #1637: a bool answers NaN, not 0.0, so a host that reads a bool as a
 * number sees the mistake propagate (NaN poisons the arithmetic) instead of a
 * plausible false-as-zero. Other non-numbers keep the documented 0.0. Hosts
 * test eigs_value_type first, or read a bool with eigs_value_as_bool. */
double eigs_value_as_num(EigsValue *v) {
    if (!v || v->type != VAL_NUM) {
        embed_value_error(EK_TYPE, "eigs_value_as_num: expected a number");
        return (v && v->type == VAL_BOOL) ? NAN : 0.0;
    }
    return VAL_NUM_RAW(v);
}

const char *eigs_value_as_string(EigsValue *v) {
    return (v && v->type == VAL_STR) ? v->data.str : NULL;
}

int eigs_value_list_len(EigsValue *v) {
    if (!v || v->type != VAL_LIST) {
        embed_value_error(EK_TYPE, "eigs_value_list_len: expected a list");
        return 0;
    }
    return v->data.list.count;
}

EigsValue *eigs_value_list_get(EigsValue *v, int i) {
    if (!v || v->type != VAL_LIST) return NULL;
    if (i < 0 || i >= v->data.list.count) return NULL;
    return list_get_owned(v, i);
}

void eigs_value_list_append(EigsValue *v, EigsValue *item) {
    if (!v || v->type != VAL_LIST || !item) return;
    list_append(v, item);
}

EigsValue *eigs_value_dict_get(EigsValue *v, const char *k) {
    if (!v || v->type != VAL_DICT || !k) return NULL;
    int i = env_hash_find_dict(v, k, env_hash_name(k));
    return i >= 0 ? dict_value_get_owned(v, i) : NULL;
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
    if (!v || v->type != VAL_BUFFER) {
        embed_value_error(EK_TYPE, "eigs_value_buffer_len: expected a buffer");
        return 0;
    }
    return v->data.buffer.count;
}

double eigs_value_buffer_get(EigsValue *v, int i) {
    if (!v || v->type != VAL_BUFFER) {
        embed_value_error(EK_TYPE, "eigs_value_buffer_get: expected a buffer");
        return 0.0;
    }
    if (i < 0 || i >= v->data.buffer.count) {
        embed_value_error(EK_INDEX,
                           "eigs_value_buffer_get: buffer index %d out of range (length %d)",
                           i, v->data.buffer.count);
        return 0.0;
    }
    return buffer_read_num(v, i);
}

void eigs_value_buffer_set(EigsValue *v, int i, double x) {
    if (!v || v->type != VAL_BUFFER) {
        embed_value_error(EK_TYPE, "eigs_value_buffer_set: expected a buffer");
        return;
    }
    if (i < 0 || i >= v->data.buffer.count) {
        embed_value_error(EK_INDEX,
                           "eigs_value_buffer_set: buffer index %d out of range (length %d)",
                           i, v->data.buffer.count);
        return;
    }
    v->data.buffer.data[i] = x;
}

/* ---- Trace tape (record + replay) ---------------------------------- */

void eigs_set_trace_sink(EigsTraceSink cb, void *ud) {
    trace_set_sink(cb, ud);
}

int eigs_trace_bind_stream(const char *key) {
    return trace_bind_stream(key);
}

int eigs_set_replay_tape(const char *bytes, size_t len, int strict) {
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    int result = trace_set_replay_mem(bytes, len, strict);
    embed_fenv_leave(&fenv);
    return result;
}

int eigs_replay_advance_session(void) {
    return trace_replay_advance_session();
}

int eigs_replay_take(const char *name, EigsValue **out) {
    if (!out) return 0;
    return trace_replay_take(name, (Value **)out);
}

void eigs_trace_record_nondet(const char *name, EigsValue *v) {
    EmbedFenv fenv;
    embed_fenv_enter(&fenv);
    if (g_trace_enabled) trace_nondet_value(name, (Value *)v);
    embed_fenv_leave(&fenv);
}

/* #1637: EIGS_KIND(EIGS_TYPE_X) bits -> the runtime's ValType bits. */
int eigs_trace_declare_kind(const char *name, unsigned kinds) {
    static const struct { EigsValueType e; ValType v; } map[] = {
        {EIGS_TYPE_NULL, VAL_NULL}, {EIGS_TYPE_NUM, VAL_NUM}, {EIGS_TYPE_STR, VAL_STR},
        {EIGS_TYPE_LIST, VAL_LIST}, {EIGS_TYPE_DICT, VAL_DICT},
        {EIGS_TYPE_BUFFER, VAL_BUFFER}, {EIGS_TYPE_BOOL, VAL_BOOL},
    };
    unsigned vk = 0, seen = 0;
    for (size_t i = 0; i < sizeof map / sizeof map[0]; i++)
        if (kinds & EIGS_KIND(map[i].e)) { vk |= 1u << map[i].v; seen |= EIGS_KIND(map[i].e); }
    if (kinds & ~seen) return 0;   /* FN / OTHER cannot be on a tape */
    return trace_declare_kind(name, vk);
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
    if (embed_refuse_reserved("eigs_register_function", name)) return;
    /* #1028: a C callback can observe its own assignments, but has no source
     * the compile verdict can inspect. This pin survives enabling isolation
     * after registration. Late registration records the gap; eval's guard
     * refuses to enter opaque host code with incomplete history. */
    obs_flag_store(eval_host_callbacks, 1);
    eigs_obs_enable_runtime();
    eigs_bool_gate_exempt((BuiltinFn)fn);   /* #1637: host functions are not bool-gated */
    Value *bv = make_builtin((BuiltinFn)fn);
    /* #1388: a registered function joins the builtin layer too, so module
     * code sees it (and the host's own rebinding of the name stays out of
     * modules, as for any builtin). eigs_set_global values stay host
     * globals: module code reaches them only through the layer's parent
     * link, so they can never shadow a builtin there. */
    if (g_builtin_env) env_set_local(g_builtin_env, name, bv);
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
