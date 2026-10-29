/* #1162: state-owned names survive the attachment that interned them. */
#include "eigs_embed.h"

#include <pthread.h>
#include <stdio.h>

typedef struct {
    EigsState *state;
    const char *source;
    int failed;
} AttachEval;

static void *attach_eval_detach(void *opaque) {
    AttachEval *job = opaque;
    if (!eigs_thread_attach(job->state)) {
        job->failed = 1;
        return NULL;
    }

    EigsValue *result = eigs_eval_string(job->source);
    if (!result || eigs_has_error()) job->failed = 1;
    if (result) eigs_value_release(result);
    eigs_thread_detach();
    return NULL;
}

static int run_attachment(AttachEval *job) {
    pthread_t thread;
    if (pthread_create(&thread, NULL, attach_eval_detach, job) != 0)
        return 0;
    return pthread_join(thread, NULL) == 0 && !job->failed;
}

int main(void) {
    EigsState *state = eigs_open();
    if (!state) return 2;
    eigs_thread_detach();

    AttachEval writer = {
        state,
        "shared_dict is {\"first\": 17, \"second\": 29}\n"
        "shared_binding is \"thread-a\"\n",
        0
    };
    AttachEval reader = {
        state,
        "print of shared_dict.first\n"
        "print of shared_dict.second\n"
        "print of shared_binding\n"
        "print of (abs of -3)\n",
        0
    };

    int ok = run_attachment(&writer) && run_attachment(&reader);
    if (!eigs_thread_attach(state)) return 2;
    eigs_close(state);
    return ok ? 0 : 1;
}
