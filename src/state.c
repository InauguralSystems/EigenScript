/*
 * EigsState / EigsThread implementation — see state.h.
 */
#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "jit.h"

#if EIGENSCRIPT_EXT_HTTP
/* Forward-declared here to avoid pulling ext_http_internal.h (and its
 * pthread/socket includes) into core runtime TUs. Defined in ext_http.c. */
extern void ext_http_state_destroy(EigsState *st);
#endif

__thread EigsThread *eigs_current = NULL;

EigsState *eigs_state_new(void) {
    EigsState *st = xcalloc(1, sizeof(*st));
    pthread_mutex_init(&st->threads_lock, NULL);
    pthread_mutex_init(&st->handle_mutex, NULL);
    pthread_mutex_init(&st->gc_lock, NULL);   /* cycle-collector registry */
    st->handle_next = 1;  /* 0 reserved as invalid */
    /* Observer thresholds — same defaults as the legacy TLS globals. */
    st->obs_dh_zero  = 0.001;
    st->obs_dh_small = 0.01;
    st->obs_h_low    = 0.1;
    /* Filesystem anchor defaults; main/eigenlsp overwrite after attach. */
    st->script_dir[0] = '.'; st->script_dir[1] = '\0';
    st->exe_dir[0]    = '.'; st->exe_dir[1]    = '\0';
    /* Phase 9: JIT tuning per state, read once from env at creation. */
    jit_state_init_thresholds(st);
    return st;
}

void eigs_state_destroy(EigsState *st) {
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
    /* Module-cache refs were dropped at gc_collect_at_exit; the array
     * itself may still be allocated (capacity bumped past zero). */
    free(st->module_cache);
    /* #307: value-candidate buffer pins were drained at gc_collect_at_exit;
     * free the (now-empty) backing array. NULL if no cycle ever parked. */
    free(st->gc_val_buf);
    pthread_mutex_destroy(&st->threads_lock);
    pthread_mutex_destroy(&st->handle_mutex);
    pthread_mutex_destroy(&st->gc_lock);
    free(st);
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

    /* Phase 8: release freelist + intern memory before the EigsThread
     * struct itself goes. Must run while eigs_current still points at th
     * so the bridge macros inside free_value/env destructors resolve. */
    eigs_thread_drain_caches(th);

    arena_destroy();
    eigs_current = NULL;

    pthread_mutex_lock(&st->threads_lock);
    EigsThread **slot = &st->threads;
    while (*slot && *slot != th) slot = &(*slot)->next;
    if (*slot == th) *slot = th->next;
    pthread_mutex_unlock(&st->threads_lock);

    free(th);
}
