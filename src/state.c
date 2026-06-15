/*
 * EigsState / EigsThread implementation — see state.h.
 */
#include "eigenscript.h"
#include "state.h"
#include <pthread.h>

__thread EigsThread *eigs_current    = NULL;
__thread Arena      *eigs_arena_ptr  = NULL;  /* declared in eigenscript.h */

struct EigsThread {
    EigsState  *state;
    Arena       arena;
    EigsThread *next;
};

struct EigsState {
    pthread_mutex_t threads_lock;
    EigsThread     *threads;
};

EigsState *eigs_state_new(void) {
    EigsState *st = xcalloc(1, sizeof(*st));
    pthread_mutex_init(&st->threads_lock, NULL);
    return st;
}

void eigs_state_destroy(EigsState *st) {
    if (!st) return;
    if (st->threads) {
        fprintf(stderr,
                "eigs_state_destroy: %s\n",
                "thread(s) still attached on destroy");
    }
    pthread_mutex_destroy(&st->threads_lock);
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

    /* Wire TLS before arena_init so its writes land in th->arena. */
    eigs_current   = th;
    eigs_arena_ptr = &th->arena;
    arena_init();

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

    arena_destroy();
    eigs_current   = NULL;
    eigs_arena_ptr = NULL;

    pthread_mutex_lock(&st->threads_lock);
    EigsThread **slot = &st->threads;
    while (*slot && *slot != th) slot = &(*slot)->next;
    if (*slot == th) *slot = th->next;
    pthread_mutex_unlock(&st->threads_lock);

    free(th);
}
