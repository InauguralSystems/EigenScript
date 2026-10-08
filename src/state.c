/*
 * EigsState / EigsThread implementation — see state.h.
 */
#include "eigenscript.h"
#include "env_flag.h"
#include "state.h"
#include "fsutil.h"
#include "vm.h"
#include "jit.h"
#include "trace.h"   /* #739: trace_thread_release on detach */

/* #915 (compiler.c): thread-local eager-pass memo + budget release. Declared
 * here at file scope — the block-scoped extern it replaces was CodeQL
 * cpp/function-in-block, and the header owning it is not visible to this TU. */
void eigs_obs_memo_release(void);

/* #739/#744: per-state extension teardown. The two hand-written externs that
 * used to sit here (one per extension, to avoid pulling ext_http_internal.h's
 * pthread/socket includes and ext_db_internal.h's libpq) are now one shared
 * seam — declarations only, no extension types. */
#include "ext_register.h"

__thread EigsThread *eigs_current = NULL;

/* Process-wide attached-thread and live-state counts. The eager pre-pass
 * (#915) keys off thread count; eigs_close (#1143) keys off state count
 * to decide whether it is shutting the last interpreter (and the tape). */
static pthread_mutex_t g_attached_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_attached_cond = PTHREAD_COND_INITIALIZER;
static int g_attached_threads_storage = 0;
static int g_single_thread_reserved = 0;
static int g_live_states = 0;
#define g_attached_threads_load() __atomic_load_n(&g_attached_threads_storage, __ATOMIC_ACQUIRE)
#define g_attached_threads_add(d) __atomic_fetch_add(&g_attached_threads_storage, (d), __ATOMIC_RELEASE)

EigsState *eigs_state_new(void) {
    EigsState *st = xcalloc(1, sizeof(*st));
    trace_state_init(st);
    pthread_mutex_init(&st->threads_lock, NULL);
    pthread_mutex_init(&st->intern_owner_lock, NULL);
    pthread_mutex_init(&st->handle_mutex, NULL);
    pthread_mutex_init(&st->exit_mutex, NULL);
    pthread_cond_init(&st->exit_cond, NULL);
    pthread_mutex_init(&st->gc_lock, NULL);   /* cycle-collector registry */
    pthread_mutex_init(&st->module_lock, NULL);   /* #1144: import cache */
    st->handle_next = 1;  /* 0 reserved as invalid */
    st->exit_scope = xcalloc(1, sizeof(*st->exit_scope));
    st->exit_scope->refs = 1; /* state owner */
    /* #1038: absence of a compiler verdict means record, not discard. */
    st->obs_needed = 1;
    st->obs_compile_pending = 1;
    /* Observer thresholds — same defaults as the legacy TLS globals. */
    st->obs_dh_zero  = OBSERVER_DH_ZERO_DEFAULT;
    st->obs_dh_small = OBSERVER_DH_SMALL_DEFAULT;
    st->obs_h_low    = OBSERVER_H_LOW_DEFAULT;
    st->obs_window   = OBSERVER_WINDOW_N;        /* #1044 */
    st->obs_scale    = OBSERVER_SCALE_DEFAULT;   /* #1045 */
    /* #971/#1361: strict mode, read once from env at creation (like the JIT
     * thresholds below). ON BY DEFAULT: unset or empty is strict, and so is
     * any value other than "0"; EIGS_STRICT=0 is the per-run opt-out that
     * restores the finite stand-ins. */
    st->strict = eigs_env_flag_default("EIGS_STRICT", 1);
    /* Filesystem anchor defaults; main/eigenlsp overwrite after attach. */
    st->script_dir[0] = '.'; st->script_dir[1] = '\0';
    st->exe_dir[0]    = '.'; st->exe_dir[1]    = '\0';
#if !EIGENSCRIPT_FREESTANDING
    st->exe_path = eigs_executable_path(NULL);
#endif
    /* Phase 9: JIT tuning per state, read once from env at creation. */
    jit_state_init_thresholds(st);
    pthread_mutex_lock(&g_attached_lock);
    g_live_states++;
    pthread_mutex_unlock(&g_attached_lock);
    return st;
}

static void state_destroy_body(EigsState *st, int already_released) {
    if (!st) return;
    if (st->threads) {
        fprintf(stderr,
                "eigs_state_destroy: %s\n",
                "thread(s) still attached on destroy");
    }
#if EIGENSCRIPT_EXT_HTTP
    /* No-op if the state never registered http builtins. */
    ext_http_state_destroy(st);
#endif
#if EIGENSCRIPT_EXT_DB
    ext_db_state_destroy(st);   /* #739: close this state's libpq connection */
#endif
    /* Module-cache refs were dropped at gc_collect_at_exit; the array
     * itself may still be allocated (capacity bumped past zero). */
    free(st->module_cache);
    /* #1144: the in-flight load stack moved to EigsThread — it is freed by
     * eigs_thread_detach, which runs before the state is destroyed. */
    free(st->exe_path);
    /* #307: value-candidate buffer pins were drained at gc_collect_at_exit;
     * free the (now-empty) backing array. NULL if no cycle ever parked. */
    free(st->gc_val_buf);
    /* Values/envs/chunks have already been drained by normal close. */
    env_intern_release_all_values(st);
    pthread_mutex_destroy(&st->intern_owner_lock);
    pthread_mutex_destroy(&st->module_lock);
    pthread_mutex_destroy(&st->threads_lock);
    pthread_mutex_destroy(&st->handle_mutex);
    eigs_exit_scope_release(st->exit_scope);
    pthread_cond_destroy(&st->exit_cond);
    pthread_mutex_destroy(&st->exit_mutex);
    pthread_mutex_destroy(&st->gc_lock);
    if (!already_released) {
        pthread_mutex_lock(&g_attached_lock);
        if (g_live_states > 0) g_live_states--;
        pthread_mutex_unlock(&g_attached_lock);
    }
    free(st);
}

void eigs_exit_scope_retain(EigsExitScope *scope) {
    if (scope) __atomic_add_fetch(&scope->refs, 1, __ATOMIC_RELAXED);
}

void eigs_exit_scope_release(EigsExitScope *scope) {
    if (scope && __atomic_sub_fetch(&scope->refs, 1, __ATOMIC_ACQ_REL) == 0)
        free(scope);
}

/* Only the attached thread replaces its own pointer. Native polling loads it
 * from VM.owner at execution time; no worker ever borrows the state's mutable
 * default without acquiring its own reference under exit_mutex. */
void eigs_thread_set_exit_scope(EigsExitScope *scope) {
    EigsExitScope *old = eigs_current->exit_scope;
    eigs_exit_scope_retain(scope);
    eigs_current->exit_scope = scope;
    eigs_exit_scope_release(old);
}

void eigs_state_request_exit(EigsState *st, int code) {
    if (!st) return;
    pthread_mutex_lock(&st->exit_mutex);
    EigsExitScope *scope = eigs_current && eigs_current->state == st
                         ? eigs_current->exit_scope : st->exit_scope;
    if (!__atomic_load_n(&scope->latched_storage, __ATOMIC_RELAXED)) {
        scope->code = code;
        __atomic_store_n(&scope->latched_storage, 1, __ATOMIC_RELEASE);
    }
    pthread_cond_broadcast(&st->exit_cond);
    pthread_mutex_unlock(&st->exit_mutex);
}

int eigs_state_exit_requested(EigsState *st, int *code) {
    if (!st) return 0;
    /* All execution/wait paths own an attached scope. The fallback is for a
     * host inspecting the state's newest scope without an attachment. */
    int attached = eigs_current && eigs_current->state == st;
    if (!attached) pthread_mutex_lock(&st->exit_mutex);
    EigsExitScope *scope = attached ? eigs_current->exit_scope : st->exit_scope;
    int requested = __atomic_load_n(&scope->latched_storage, __ATOMIC_ACQUIRE);
    if (requested && code) *code = scope->code;
    if (!attached) pthread_mutex_unlock(&st->exit_mutex);
    return requested;
}

void eigs_state_begin_eval(EigsState *st) {
    if (!st || !eigs_current || eigs_current->state != st) return;
    EigsExitScope *scope = xcalloc(1, sizeof(*scope));
    scope->refs = 1; /* transferred to the state */
    pthread_mutex_lock(&st->exit_mutex);
    EigsExitScope *old = st->exit_scope;
    st->exit_scope = scope;
    eigs_thread_set_exit_scope(scope);
    pthread_mutex_unlock(&st->exit_mutex);
    eigs_exit_scope_release(old);
}

void eigs_state_destroy(EigsState *st) {
    state_destroy_body(st, 0);
}

void eigs_state_destroy_released(EigsState *st) {
    state_destroy_body(st, 1);
}

/* #915: PROCESS-GLOBAL count of attached threads.
 *
 * The observer gate's eager pre-pass mutates two things that are NOT per-state:
 * fd 2 (it mutes stderr around a speculative compile) and trace.c's arming sets
 * (g_arm_names / g_occ_names / g_trace_hist, plain file-scope globals). It
 * guarded that with `g_vm_multithreaded`, which is eigs_current->state->
 * multithreaded — a PER-STATE flag. A per-state flag cannot see a sibling
 * state, and src/ext_http.c runs a fresh EigsState per connection on its own OS
 * thread, so that flag is 0 on every worker.
 *
 * Executed by a blind critic under `make asan-http`, two concurrent `code`
 * routes each containing a literal load_file:
 *
 *   heap-use-after-free READ in arm_set_has (trace.c) <- trace_arm_history_name
 *   <- compile_ast <- builtin_load_file <- handle_request <- http_conn_thread,
 *   freed by another connection thread in trace_arm_restore.
 *
 * And the fd-2 mute is likewise process-wide: ten /ping requests issued while
 * one long eager compile held the muted window produced ZERO stderr lines, and
 * two staggered overlapping compiles left the server's real stderr replaced by
 * /dev/null for the life of the process — every later runtime error, OOM and
 * sanitizer report discarded.
 *
 * So the precondition is not "this state is single-threaded", it is "this
 * PROCESS has one thread". */

int eigs_process_thread_count(void) {
    return g_attached_threads_load();
}

int eigs_process_single_thread_begin(void) {
    pthread_mutex_lock(&g_attached_lock);
    if (g_single_thread_reserved || g_attached_threads_load() != 1) {
        pthread_mutex_unlock(&g_attached_lock);
        return 0;
    }
    g_single_thread_reserved = 1;
    pthread_mutex_unlock(&g_attached_lock);
    return 1;
}

void eigs_process_single_thread_end(void) {
    pthread_mutex_lock(&g_attached_lock);
    g_single_thread_reserved = 0;
    pthread_cond_broadcast(&g_attached_cond);
    pthread_mutex_unlock(&g_attached_lock);
}

/* A bare snapshot of the live-state count. NOT a close decision: by the time
 * a closer asks, its own state is already released and a sibling may close
 * between the read and any action taken on it. trace_shutdown is its ONE
 * caller (it frees the process-wide arm-name table only when no sibling
 * state can still read it), and tests/test_trace_mt.sh's `close-count-toctou`
 * check pins that: exactly one caller, and never inside eigs_close. */
int eigs_process_state_count(void) {
    pthread_mutex_lock(&g_attached_lock);
    int n = g_live_states;
    pthread_mutex_unlock(&g_attached_lock);
    return n;
}

/* #1142/#1143: the ONLY way to ask "am I closing the LAST state?" — decide
 * and decrement are one step under g_attached_lock and the answer exists
 * only as this call's RETURN VALUE. A close path that instead reads the
 * count and then decrements is the round-2 TOCTOU: two concurrent
 * eigs_close calls both read 2, neither shuts, and the process tape
 * outlives every state. That window is ~100 ns and no harness on this box
 * could observe it (0 kills in 2000 barrier'd double-closes on BOTH the
 * fixed tree and the planted bug), so the class is closed STRUCTURALLY and
 * gated structurally — see the `close-count-toctou` check. */
int eigs_process_state_release(void) {
    pthread_mutex_lock(&g_attached_lock);
    int last = 0;
    if (g_live_states > 0) {
        g_live_states--;
        last = (g_live_states == 0);
    }
    pthread_mutex_unlock(&g_attached_lock);
    return last;
}

EigsThread *eigs_thread_attach(EigsState *st) {
    if (!st) return NULL;
    if (eigs_current) {
        fprintf(stderr,
                "eigs_thread_attach: this OS thread is already attached\n");
        return NULL;
    }
    EigsThread *th = xcalloc(1, sizeof(*th));
    th->state = st;
    trace_attachment_init(th);
    pthread_mutex_lock(&st->exit_mutex);
    th->exit_scope = st->exit_scope;
    eigs_exit_scope_retain(th->exit_scope);
    pthread_mutex_unlock(&st->exit_mutex);
    th->intern_tbl = env_intern_table_new();   /* #1065: thread's ref */
    pthread_mutex_lock(&g_attached_lock);
    while (g_single_thread_reserved) pthread_cond_wait(&g_attached_cond, &g_attached_lock);
    g_attached_threads_add(1);
    pthread_mutex_unlock(&g_attached_lock);
    /* #915: xcalloc zeroes, and 0 here would mean "never scan", silently
     * disabling the observer gate's eager pass on every thread. Default ON;
     * only --lint and the LSP clear it. */
    th->obs_gate_scan_enabled = 1;
    /* #846: EIGS_TASK_TRACE=1 arms the cooperative-scheduler trace for this
     * thread from the first resume (a program that cannot be edited can
     * still be traced); `task_sched_trace of 1` arms it from a program. */
    th->task_trace_on = eigs_env_flag("EIGS_TASK_TRACE");
    th->env_freelist_off = eigs_env_flag("EIGS_ENV_FREELIST_OFF");   /* #1674 test seam */
    th->loop_exit_reason = "normal";
    th->last_obs_slot_idx = -1;   /* #262 Phase-2: no observed slot yet */

    /* Cycle collector defaults — matches the old TLS initializers. */
    th->gc_enabled = 1;
    th->gc_threshold = GC_THRESHOLD_MIN;

    /* Wire TLS before arena_init so its writes land in th->arena. */
    eigs_current = th;
    arena_init();

    /* Phase 9: zero the hot __thread caches in vm.c so an attach on an
     * OS thread that previously served another state doesn't see stale
     * dict/env pointers. No-op on a fresh thread (the static __thread
     * storage is already zero-initialized). */
    vm_thread_reset_caches();

    pthread_mutex_lock(&st->threads_lock);
    th->next = st->threads;
    st->threads = th;
    pthread_mutex_unlock(&st->threads_lock);

    return th;
}

EigsState *eigs_current_state(void) {
    return eigs_current ? eigs_current->state : NULL;
}

/* Single-thread multi-state switching (the M9 scheduler seam): PARK the
 * calling thread's current attachment (no teardown — the arena,
 * freelists, VM and error state all live on the EigsThread and stay
 * intact) and activate this thread's attachment to `st`, creating one on
 * first switch. The only per-OS-thread state that is NOT on the
 * EigsThread is vm.c's __thread hot-pointer caches — reset on every
 * switch, exactly as attach does.
 *
 * This is for ONE OS thread juggling many states (a task = a state; the
 * cooperative scheduler). Each such state therefore has exactly one
 * attachment, so its parked EigsThread is `st->threads` — we identify it
 * by state, NOT by taking the address of the `eigs_current` __thread
 * variable (that miscompiles under a hand-rolled local-exec TLS such as
 * EigenOS's: attach and switch disagreed on the address, every switch
 * re-attached, and each fresh attach leaked a 16 MiB arena — the M9 OOM).
 * Attaching more than one OS thread to a state (eigs_thread_attach) and
 * then switching it is out of scope by contract. Cross-state rule stays
 * the caller's job: values belong to the state that made them; move
 * numbers (copy), never Value pointers. */
EigsThread *eigs_thread_switch(EigsState *st) {
    if (!st) return NULL;
    if (eigs_current && eigs_current->state == st) return eigs_current;

    eigs_current = NULL;                       /* park (no teardown) */

    pthread_mutex_lock(&st->threads_lock);
    EigsThread *th = st->threads;              /* sole attachment, if any */
    pthread_mutex_unlock(&st->threads_lock);

    if (th) {
        eigs_current = th;
        vm_thread_reset_caches();              /* stale cross-state pointers */
        return th;
    }
    return eigs_thread_attach(st);             /* first switch: fresh attach */
}

void eigs_thread_detach(void) {
    EigsThread *th = eigs_current;
    if (!th) return;
    EigsState *st = th->state;

    /* Phase 5 cleanups (must run while eigs_current still points at th
     * so any bridge-macro reads inside the destructors stay valid). */
    jit_thread_destroy(th);
    vm_thread_destroy(th);
    task_sched_thread_free();   /* #408: release the cooperative task scheduler */
    trace_thread_release();     /* #739: this thread's prev-table (NOT the tape) */
#if !EIGENSCRIPT_FREESTANDING
    /* #739: an unclosed stream_open belongs to this thread; close it here so
     * it is neither leaked nor left for another thread to inherit. Carved out
     * of the freestanding profile with the stream_* builtins themselves —
     * fclose is not in the allowlist and there is no stream to close there. */
    if (th->stream_file) { fclose((FILE *)th->stream_file); th->stream_file = NULL; }
#endif

    /* Phase 8: release freelist + intern memory before the EigsThread
     * struct itself goes. Must run while eigs_current still points at th
     * so the bridge macros inside free_value/env destructors resolve. */
    /* #496/#1144: any load still on this thread's in-flight stack is a
     * strdup'd path (shouldn't happen in a clean run — every enter is paired
     * with a leave — but free defensively). */
    for (size_t i = 0; i < th->loading_count; i++) free(th->loading_stack[i]);
    free(th->loading_stack);
    th->loading_stack = NULL;
    th->loading_count = th->loading_cap = 0;

    eigs_thread_drain_caches(th);
    eigs_obs_memo_release();  /* #915: memo + speculative budget, thread-local */
    pthread_mutex_lock(&g_attached_lock); g_attached_threads_add(-1); pthread_mutex_unlock(&g_attached_lock);

    arena_destroy();
    eigs_exit_scope_release(th->exit_scope);
    trace_attachment_destroy(th);
    eigs_current = NULL;

    pthread_mutex_lock(&st->threads_lock);
    EigsThread **slot = &st->threads;
    while (*slot && *slot != th) slot = &(*slot)->next;
    if (*slot == th) *slot = th->next;
    pthread_mutex_unlock(&st->threads_lock);

    free(th);
}
