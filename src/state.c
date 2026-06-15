/*
 * EigsState / EigsThread implementation — see state.h.
 */
#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "jit.h"

__thread EigsThread *eigs_current = NULL;

EigsState *eigs_state_new(void) {
    EigsState *st = xcalloc(1, sizeof(*st));
    pthread_mutex_init(&st->threads_lock, NULL);
    pthread_mutex_init(&st->handle_mutex, NULL);
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
    /* Module-cache refs were dropped at gc_collect_at_exit; the array
     * itself may still be allocated (capacity bumped past zero). */
    free(st->module_cache);
    pthread_mutex_destroy(&st->threads_lock);
    pthread_mutex_destroy(&st->handle_mutex);
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
