/* Ordinary source suspension and explicit session boundaries. Small fixed
 * tapes, one continuing worker, condition handshakes, no timing oracle. */
#include "eigenscript.h"
#include "eigs_embed.h"
#include "state.h"
#include "trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int passed, failed, total;
static void check(int ok, const char *name) {
    total++;
    if (ok) passed++; else failed++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
}
static double take(const char *name) {
    EigsValue *v = NULL;
    int got = eigs_replay_take(name, &v);
    double n = got && v && !eigs_has_error() ? eigs_value_as_num(v) : -999;
    eigs_value_release(v);
    return n;
}
static EigsValue *advance_callback(EigsValue *arg) {
    (void)arg;
    return eigs_value_new_num(eigs_replay_advance_session());
}

static const char file_tape[] =
    "V 5 " EIGENSCRIPT_VERSION "\n"
    "B 0 1 1 0 root -\nB 1 2 2 0 host 70656572\n"
    "N 1 peer=12\nN 0 root=11\nN 0 root=13\n"
    "V 5 " EIGENSCRIPT_VERSION "\n"
    "B 0 1 1 0 root -\nB 1 2 2 0 host 70656572\n"
    "N 0 root=21\nN 1 peer=22\n";
static const char memory_tape[] =
    "V 5 " EIGENSCRIPT_VERSION "\n"
    "B 0 101 11 0 root -\nB 1 102 12 0 host 70656572\n"
    "N 1 peer=102\nN 0 root=101\nN 0 root=103\n"
    "V 5 " EIGENSCRIPT_VERSION "\n"
    "B 0 101 11 0 root -\nN 0 root=201\n";
static const char replacement[] =
    "V 5 " EIGENSCRIPT_VERSION "\n"
    "B 0 201 21 0 root -\nB 1 202 22 0 host 70656572\n"
    "N 1 peer=302\nN 0 root=301\n";
static const char refused[] = "V 4 " EIGENSCRIPT_VERSION "\n";

static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int phase, completed, live_calls, live_bias, worker_error;
static double observed[2];
static char journal[4096];
static size_t used;
static int bad_sink;
static void sink(const char *s, size_t n, void *unused) {
    (void)unused;
    if (!n || s[n-1] != '\n' || memchr(s, '\n', n-1) || n >= sizeof(journal)-used) {
        bad_sink = 1;
        return;
    }
    memcpy(journal+used, s, n); used += n; journal[used] = 0;
}
static Value *continuing_worker(Value *arg) {
    (void)arg;
    for (int i = 0; i < 2; i++) {
        pthread_mutex_lock(&mu);
        while (phase < i) pthread_cond_wait(&cv, &mu);
        pthread_mutex_unlock(&mu);
        Value *v = NULL;
        if (!trace_replay_take("sample", &v)) {
            v = make_num(7 + i + live_bias);
            trace_nondet_value("sample", v);
            live_calls++;
        }
        observed[i] = eigs_value_as_num(v);
        val_decref(v);
        pthread_mutex_lock(&mu);
        worker_error |= g_has_error;
        completed = i + 1;
        pthread_cond_broadcast(&cv);
        pthread_mutex_unlock(&mu);
    }
    return make_num(observed[0]*10 + observed[1]);
}
static Value *start_worker(void) {
    phase = completed = worker_error = 0;
    Value *args = make_list(1), *fn = make_builtin(continuing_worker);
    list_append(args, fn); val_decref(fn);
    Value *handle = builtin_spawn(args); val_decref(args);
    if (!handle || handle->type != VAL_DICT || g_has_error) {
        fputs("trace context: ordinary worker setup failed\n", stderr);
        exit(2);
    }
    pthread_mutex_lock(&mu);
    while (completed < 1) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    return handle;
}
static double finish_worker(Value *handle) {
    pthread_mutex_lock(&mu);
    phase = 1; pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    Value *v = builtin_thread_join(handle);
    double n = eigs_value_as_num(v);
    val_decref(v); val_decref(handle);
    return n;
}

int main(void) {
    EigsState *root = eigs_open();
    if (!root) return 2;
    check(!eigs_replay_advance_session(), "advance without a source refuses");
    char path[] = "/tmp/eigs_trace_context_XXXXXX";
    int fd = mkstemp(path);
    if (fd < 0) return 2;
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); unlink(path); return 2; }
    int written = fwrite(file_tape, 1, sizeof(file_tape)-1, f) == sizeof(file_tape)-1;
    int closed = fclose(f) == 0;
    if (!written || !closed) { unlink(path); return 2; }
    setenv("EIGS_REPLAY", path, 1);
    setenv("EIGS_REPLAY_STRICT", "0", 1);
    trace_init();
    unsetenv("EIGS_REPLAY"); unsetenv("EIGS_REPLAY_STRICT"); unlink(path);
    check(take("root") == 11, "file root read queues preceding sibling value");
    EigsState *peer = eigs_state_new();
    if (!eigs_thread_switch(peer)) return 2;
    check(eigs_trace_bind_stream("peer"), "file peer binds without consuming its queued value");
    if (!eigs_thread_switch(root)) return 2;
    check(eigs_set_replay_tape(memory_tape, sizeof(memory_tape)-1, 1), "memory source suspends file");
    check(take("root") == 101, "memory uses its own namespace and pending queue");
    check(!eigs_set_replay_tape(refused, sizeof(refused)-1, 0), "refused replacement leaves memory source installed");
    check(take("root") == 103, "refusal preserves current memory cursor");
    check(!eigs_replay_advance_session(), "advance refuses queued sibling outcome");
    if (!eigs_thread_switch(peer)) return 2;
    check(take("peer") == 102, "sibling retains its queued memory outcome after refusal");
    if (!eigs_thread_switch(root)) return 2;
    eigs_register_function("advance_probe", advance_callback);
    EigsValue *probe = eigs_eval_string("advance_probe of []");
    check(probe && eigs_value_as_num(probe) == 0, "advance inside ordinary evaluation refuses");
    eigs_value_release(probe);
    check(eigs_replay_advance_session(), "quiescent host explicitly advances memory session");
    check(take("root") == 201, "continuing root resolves next-session lifetime");
    check(!eigs_replay_advance_session(), "memory EOF refuses advance");
    check(eigs_set_replay_tape(NULL, 0, 0), "clear restores suspended file context");
    /* Different name intentionally exercises restored FILE strict=0 after
     * memory strict=1; only this expected ordinary warning is emitted. */
    check(take("file_alias") == 13, "file cursor and lenient strictness both resume");
    check(!eigs_replay_advance_session(), "file's older sibling value still blocks advance");
    check(take("root") == -999 && eigs_has_error(), "ordinary take cannot borrow next V value");
    eigs_clear_error();
    if (!eigs_thread_switch(peer)) return 2;
    check(take("peer") == 12, "file's original pending sibling value survives memory source");
    if (!eigs_thread_switch(root)) return 2;
    check(eigs_replay_advance_session(), "file advances only after sibling consumption");
    check(take("root") == 21, "file root resumes at explicit next namespace");
    if (!eigs_thread_switch(peer)) return 2;
    check(take("peer") == 22, "continuing keyed peer resolves next namespace");
    if (!eigs_thread_switch(root)) return 2;
    check(!eigs_replay_advance_session(), "file EOF does not invent a session");
    check(eigs_set_replay_tape(memory_tape, sizeof(memory_tape)-1, 1), "fresh memory context installs independently");
    check(take("root") == 101, "fresh memory source restarts only its own cursor");
    check(eigs_set_replay_tape(replacement, sizeof(replacement)-1, 1), "valid replacement publishes new memory context");
    if (!eigs_thread_switch(peer)) return 2;
    check(take("peer") == 302, "replacement cannot serve discarded memory sibling value");
    if (!eigs_thread_switch(root)) return 2;
    check(take("root") == 301, "replacement root uses its own recorded namespace");
    check(eigs_set_replay_tape(NULL, 0, 0), "second clear restores same suspended file EOF");
    check(!eigs_replay_advance_session(), "resumed file remains exhausted");
    trace_shutdown();
    check(!g_replay_enabled, "shutdown releases both replay contexts");

    eigs_set_trace_sink(sink, NULL);
    Value *handle = start_worker();
    check(observed[0] == 7 && !worker_error, "recording child finishes first session before boundary");
    eigs_set_trace_sink(sink, NULL);
    check(finish_worker(handle) == 78 && !worker_error, "same child records second session after host boundary");
    eigs_set_trace_sink(NULL, NULL);
    check(live_calls == 2 && !bad_sink, "two bounded live outcomes and complete journal records");
    check(eigs_set_replay_tape(journal, used, 1), "two-session child journal installs");
    live_bias = 100;
    handle = start_worker();
    check(observed[0] == 7 && !worker_error, "replay child serves first causal lifetime");
    check(eigs_replay_advance_session(), "parked child permits explicit quiescent advance");
    check(finish_worker(handle) == 78 && !worker_error, "same causal child resolves after namespace reset");
    check(live_calls == 2, "continuing child never consults changed live source");
    check(!eigs_replay_advance_session(), "child journal ends after its declared sessions");
    check(eigs_set_replay_tape(NULL, 0, 0), "memory clear disables replay when no file remains");
    check(!g_replay_enabled, "final memory source is fully released");
    if (!eigs_thread_switch(peer)) return 2;
    eigs_thread_detach(); eigs_state_destroy(peer);
    if (!eigs_thread_switch(root)) return 2;
    eigs_close(root);
    printf("trace context: %d passed, %d failed (41 declared)\n", passed, failed);
    return failed || total != 41;
}
