/* Ordinary, explicitly ordered host/child correspondence. Six small native
 * threads at most; no sleeps, resource pressure or schedule-race oracle. */
#include "eigenscript.h"
#include "eigs_embed.h"
#include "state.h"
#include "trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char tape[32768];
static size_t used;
static int sink_bad, passed, failed, total;
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cv = PTHREAD_COND_INITIALIZER;
static int order[4], turn, run_children, stop_children, live_calls, live_bias;

static void check(int ok, const char *name) {
    total++;
    if (ok) passed++; else failed++;
    printf("%s: %s\n", ok ? "PASS" : "FAIL", name);
}

static void sink(const char *bytes, size_t n, void *unused) {
    (void)unused;
    if (!n || bytes[n - 1] != '\n' || memchr(bytes, '\n', n - 1)) sink_bad++;
    if (n >= sizeof(tape) - used) { sink_bad++; return; }
    memcpy(tape + used, bytes, n);
    used += n;
    tape[used] = 0;
}

static void launch(pthread_t *thread, void *(*entry)(void *), void *arg) {
    int rc = pthread_create(thread, NULL, entry, arg);
    if (rc) {
        fprintf(stderr, "trace correspondence setup: pthread_create rc=%d\n", rc);
        exit(2);                /* setup failure is never an expected red */
    }
}

static Value *sensor(Value *arg) {
    int id = (int)eigs_value_as_num(arg);
    pthread_mutex_lock(&mu);
    while (!stop_children && (!run_children || turn >= 4 || order[turn] != id))
        pthread_cond_wait(&cv, &mu);
    if (stop_children) {
        pthread_mutex_unlock(&mu);
        return make_null();
    }
    pthread_mutex_unlock(&mu);
    Value *value = NULL;
    if (!trace_replay_take("ordinary_sensor", &value)) {
        value = make_num(id + live_bias);
        trace_nondet_value("ordinary_sensor", value); /* deliberately before LINE */
        pthread_mutex_lock(&mu);
        live_calls++;
        pthread_mutex_unlock(&mu);
    }
    pthread_mutex_lock(&mu);
    turn++;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    return value;
}

typedef struct {
    EigsState *state;
    const char *key;
    int base, bound, go, spawned, bind_ok, late_ok, error;
    double result[2];
} Host;

static Value *spawn_sensor(int id) {
    Value *args = make_list(2);
    Value *fn = make_builtin(sensor);
    Value *number = make_num(id);
    list_append(args, fn);
    list_append(args, number);
    val_decref(fn);
    val_decref(number);
    Value *handle = builtin_spawn(args);
    val_decref(args);
    return handle;
}

static void *host_entry(void *data) {
    Host *host = data;
    if (!eigs_thread_attach(host->state)) exit(2);
    host->bind_ok = eigs_trace_bind_stream(host->key);
    host->late_ok = !eigs_trace_bind_stream("replacement");
    pthread_mutex_lock(&mu);
    host->bound = 1;
    pthread_cond_broadcast(&cv);
    while (!host->go) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
    Value *handles[2] = {spawn_sensor(host->base + 1), spawn_sensor(host->base + 2)};
    pthread_mutex_lock(&mu);
    if (g_has_error) stop_children = 1;
    host->spawned = 1;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    for (int i = 0; i < 2; i++) {
        Value *value = builtin_thread_join(handles[i]);
        host->result[i] = eigs_value_as_num(value);
        val_decref(value);
        val_decref(handles[i]);
    }
    host->error = g_has_error;
    eigs_thread_detach();
    return NULL;
}

typedef struct { EigsState *state; int refused; } Duplicate;
static void *duplicate_entry(void *data) {
    Duplicate *d = data;
    if (!eigs_thread_attach(d->state)) exit(2);
    d->refused = !eigs_trace_bind_stream("alpha");
    eigs_thread_detach();
    return NULL;
}

static void wait_flag(int *flag) {
    pthread_mutex_lock(&mu);
    while (!*flag) pthread_cond_wait(&cv, &mu);
    pthread_mutex_unlock(&mu);
}

static void permit(Host *host) {
    pthread_mutex_lock(&mu);
    host->go = 1;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    wait_flag(&host->spawned);
}

static void run_hosts(int reverse) {
    Host hosts[2] = {{.state=eigs_state_new(), .key="alpha", .base=10},
                     {.state=eigs_state_new(), .key="beta", .base=20}};
    pthread_t threads[2], duplicate;
    turn = run_children = stop_children = 0;
    const int forward[4] = {11, 21, 12, 22};
    const int backward[4] = {22, 12, 21, 11};
    memcpy(order, reverse ? backward : forward, sizeof(order));
    int first = reverse ? 1 : 0, second = 1 - first;
    launch(&threads[first], host_entry, &hosts[first]);
    wait_flag(&hosts[first].bound);
    launch(&threads[second], host_entry, &hosts[second]);
    wait_flag(&hosts[second].bound);
    Duplicate dup = {hosts[0].state, 0};
    launch(&duplicate, duplicate_entry, &dup);
    pthread_join(duplicate, NULL);
    check(dup.refused, "duplicate alpha key refused while original host is live");
    /* Reverse creation order independently of the child's event order. */
    permit(&hosts[first]);
    permit(&hosts[second]);
    pthread_mutex_lock(&mu);
    run_children = 1;
    pthread_cond_broadcast(&cv);
    pthread_mutex_unlock(&mu);
    pthread_join(threads[0], NULL);
    pthread_join(threads[1], NULL);
    check(hosts[0].bind_ok && hosts[1].bind_ok, "both stable host keys bind");
    check(hosts[0].late_ok && hosts[1].late_ok, "rebinding preserves both identities");
    check(hosts[0].result[0] == 11 && hosts[0].result[1] == 12,
          "alpha children keep parent-local occurrence 1 and 2");
    check(hosts[1].result[0] == 21 && hosts[1].result[1] == 22,
          "beta children keep parent-local occurrence 1 and 2");
    check(!hosts[0].error && !hosts[1].error, "both parent joins finish without runtime error");
    check(turn == 4, "all four selected child events completed");
    printf("transcript %s: %.0f %.0f %.0f %.0f\n", reverse ? "replay" : "record",
           hosts[0].result[0], hosts[0].result[1], hosts[1].result[0], hosts[1].result[1]);
    eigs_state_destroy(hosts[0].state);
    eigs_state_destroy(hosts[1].state);
}

static double script_children(void) {
    EigsValue *value = eigs_eval_string(
        "define script_worker(n) as:\n"
        "    return n + (num of (env_get of \"TRACE_CORRESPONDENCE_VALUE\"))\n"
        "left_handle is spawn of [script_worker, 1]\n"
        "right_handle is spawn of [script_worker, 2]\n"
        "(thread_join of left_handle) * 100 + (thread_join of right_handle)\n");
    double result = value ? eigs_value_as_num(value) : -1;
    eigs_value_release(value);
    return result;
}

static int declarations(void) {
    int count = 0;
    for (const char *p = tape; *p; ) {
        if (p[0] == 'B' && p[1] == ' ') count++;
        const char *nl = strchr(p, '\n');
        if (!nl) break;
        p = nl + 1;
    }
    return count;
}

int main(void) {
    EigsState *root = eigs_open();
    check(root != NULL, "root state opens");
    if (!root) return 2;
    eigs_trace_declare_kind("ordinary_sensor", EIGS_KIND(EIGS_TYPE_NUM));   /* #1637 */
    check(!eigs_trace_bind_stream(""), "empty key refused before any event");
    eigs_set_trace_sink(sink, NULL);
    check(!eigs_trace_bind_stream("late-root"), "key after opener declaration refused");
    setenv("TRACE_CORRESPONDENCE_VALUE", "7", 1);
    run_hosts(0);                /* seven checks */
    check(live_calls == 4, "recording called each ordinary source once");
    check(script_children() == 809, "bytecode spawn path records both ordinary children");
    eigs_set_trace_sink(NULL, NULL);
    check(declarations() == 9, "one root, two keyed hosts and six child declarations");
    check(strstr(tape, " host 616c706861\n") && strstr(tape, " host 62657461\n"),
          "tape preserves exact alpha/beta key bytes as metadata");
    check(!sink_bad, "every metadata/event callback is one complete bounded record");
    check(eigs_set_replay_tape(tape, used, 1), "captured tape installs for strict replay");
    live_bias = 1000;
    setenv("TRACE_CORRESPONDENCE_VALUE", "9", 1);
    run_hosts(1);                /* same seven checks, reversed ordinary ordering */
    check(live_calls == 4, "replay never consulted changed native source");
    check(script_children() == 809, "bytecode children consume tape despite changed environment");
    check(eigs_set_replay_tape(NULL, 0, 0), "replay clears at host boundary");
    check(eigs_set_replay_tape(tape, used, 1), "tape reinstalls for ordinary state-group control");
    EigsState *shared = eigs_state_new();
    if (!eigs_thread_switch(shared)) return 2;
    check(eigs_trace_bind_stream("alpha"), "first keyed attachment establishes its state group");
    eigs_thread_detach();
    if (!eigs_thread_attach(shared)) return 2;
    check(!eigs_trace_bind_stream("beta"), "one current state cannot impersonate two recorded states");
    eigs_thread_detach();
    eigs_state_destroy(shared);
    if (!eigs_thread_switch(root)) return 2;
    check(eigs_set_replay_tape(NULL, 0, 0), "state-group control clears without changing root lifetime");
    char old[64];
    const char *version = strchr(tape + 2, ' ');
    snprintf(old, sizeof(old), "V 4%s", version ? version : " invalid\n");
    char *nl = strchr(old, '\n');
    if (nl) nl[1] = 0;
    check(!eigs_set_replay_tape(old, strlen(old), 1), "prior v4 encoding is refused at install");
    eigs_close(root);
    unsetenv("TRACE_CORRESPONDENCE_VALUE");
    printf("trace correspondence: %d passed, %d failed (31 declared)\n", passed, failed);
    if (failed) fputs(tape, stderr);
    return failed || total != 31;
}
