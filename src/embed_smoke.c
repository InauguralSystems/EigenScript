/*
 * embed_smoke.c — standalone test of the Phase 10 embedding API.
 *
 * Links against the runtime sources (minus main.c) and exercises every
 * function in eigs_embed.h: open/close, eval, error retrieval, globals,
 * value handles, and FFI.
 *
 * Run via `make embed-smoke`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/time.h>

#include "eigs_embed.h"

static int failures = 0;

/* Async abort seam: the flag a signal handler (standing in for an OS
 * keyboard IRQ / ctrl-c) sets while an eval is running. */
static volatile int g_abort = 0;
static void abort_alarm(int sig) { (void)sig; g_abort = 1; }
static void arm_abort_timer_ms(long ms) {
    struct itimerval it = {{0, 0}, {ms / 1000, (ms % 1000) * 1000}};
    signal(SIGALRM, abort_alarm);
    setitimer(ITIMER_REAL, &it, NULL);
}

#define CHECK(cond, msg) do {                                              \
    if (!(cond)) {                                                         \
        fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (msg));    \
        failures++;                                                        \
    }                                                                      \
} while (0)

/* Source provider for the M7.5 module seam: serves one module. */
static const char *smoke_provider(const char *name, void *ud) {
    (void)ud;
    if (strcmp(name, "smokemod") == 0)
        return "answer is 42\ndefine twice(k) as:\n    return k * 2\n";
    return 0;
}

/* Host NONDET function for the tape seam: the live source advances on
 * every call, so a replayed value is distinguishable from a live one. */
static double g_sensor_reading = 100.0;
static EigsValue *host_sensor(EigsValue *arg) {
    (void)arg;
    EigsValue *v;
    if (eigs_replay_take("host_sensor", &v)) return v;   /* from the tape */
    v = eigs_value_new_num(g_sensor_reading);
    g_sensor_reading += 1.0;
    eigs_trace_record_nondet("host_sensor", v);          /* onto the tape */
    return v;
}

/* Trace sink: append tape bytes into a growing C buffer. */
static char   g_tape[8192];
static size_t g_tape_len = 0;
static void tape_sink(const char *bytes, size_t len, void *ud) {
    (void)ud;
    if (g_tape_len + len > sizeof g_tape) len = sizeof g_tape - g_tape_len;
    memcpy(g_tape + g_tape_len, bytes, len);
    g_tape_len += len;
}

/* Host function: adds two numbers. Multi-arg calls receive a VAL_LIST. */
static EigsValue *host_add(EigsValue *arg) {
    if (eigs_value_type(arg) != EIGS_TYPE_LIST) return eigs_value_new_null();
    if (eigs_value_list_len(arg) != 2)          return eigs_value_new_null();
    EigsValue *a = eigs_value_list_get(arg, 0);
    EigsValue *b = eigs_value_list_get(arg, 1);
    double sum = eigs_value_as_num(a) + eigs_value_as_num(b);
    eigs_value_release(a);
    eigs_value_release(b);
    return eigs_value_new_num(sum);
}

int main(void) {
    EigsState *st = eigs_open();
    CHECK(st != NULL, "eigs_open");

    /* --- Eval a script that defines a global. ------------------------ */
    EigsValue *r = eigs_eval_string("x is 5\ny is x * 7\ny");
    CHECK(r != NULL, "eval returns a value");
    CHECK(eigs_value_type(r) == EIGS_TYPE_NUM, "eval result is num");
    CHECK(eigs_value_as_num(r) == 35.0, "5 * 7 == 35");
    eigs_value_release(r);

    /* --- Read it back through the globals API. ----------------------- */
    EigsValue *y = eigs_get_global("y");
    CHECK(y != NULL, "get_global y");
    CHECK(eigs_value_as_num(y) == 35.0, "y == 35");
    eigs_value_release(y);

    /* --- Write a global from C, read it from the script. ------------- */
    EigsValue *forty = eigs_value_new_num(40.0);
    eigs_set_global("z", forty);
    eigs_value_release(forty);   /* set_global retained its own ref */
    r = eigs_eval_string("z + 2");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0, "host-set global visible to script");
    eigs_value_release(r);

    /* --- String round-trip. ------------------------------------------ */
    EigsValue *hello = eigs_value_new_string("hello");
    eigs_set_global("greeting", hello);
    eigs_value_release(hello);
    r = eigs_eval_string("greeting");
    CHECK(r != NULL && eigs_value_type(r) == EIGS_TYPE_STR, "string round-trip type");
    CHECK(r && strcmp(eigs_value_as_string(r), "hello") == 0, "string round-trip value");
    eigs_value_release(r);

    /* --- Error retrieval. -------------------------------------------- *
     * Reading an undefined name is a real runtime error (divide-by-zero
     * is num_guard'd to 0, so it doesn't qualify). */
    eigs_clear_error();
    r = eigs_eval_string("definitely_not_defined");
    CHECK(r == NULL, "undefined name returns NULL");
    CHECK(eigs_has_error(), "has_error after undefined name");
    CHECK(eigs_last_error_message() != NULL, "error message non-NULL");
    eigs_clear_error();
    CHECK(!eigs_has_error(), "clear_error clears flag");

    /* --- Recover after error and keep evaluating. -------------------- */
    r = eigs_eval_string("100");
    CHECK(r != NULL && eigs_value_as_num(r) == 100.0, "eval still works after error");
    eigs_value_release(r);

    /* --- FFI: register a C function, call from script. --------------- */
    eigs_register_function("host_add", host_add);
    r = eigs_eval_string("host_add of [3, 4]");
    CHECK(r != NULL, "FFI eval returns value");
    CHECK(r && eigs_value_type(r) == EIGS_TYPE_NUM, "FFI result is num");
    CHECK(r && eigs_value_as_num(r) == 7.0, "host_add(3,4) == 7");
    eigs_value_release(r);

    /* --- List + dict construction. ----------------------------------- */
    EigsValue *lst = eigs_value_new_list(3);
    EigsValue *e0 = eigs_value_new_num(10.0);
    EigsValue *e1 = eigs_value_new_num(20.0);
    eigs_value_list_append(lst, e0);
    eigs_value_list_append(lst, e1);
    eigs_value_release(e0);
    eigs_value_release(e1);
    CHECK(eigs_value_list_len(lst) == 2, "list len after append");
    EigsValue *g0 = eigs_value_list_get(lst, 0);
    CHECK(g0 && eigs_value_as_num(g0) == 10.0, "list get [0]");
    eigs_value_release(g0);
    eigs_value_release(lst);

    EigsValue *d = eigs_value_new_dict(2);
    EigsValue *v = eigs_value_new_num(99.0);
    eigs_value_dict_set(d, "answer", v);
    eigs_value_release(v);
    EigsValue *got = eigs_value_dict_get(d, "answer");
    CHECK(got && eigs_value_as_num(got) == 99.0, "dict get hit");
    eigs_value_release(got);
    CHECK(eigs_value_dict_get(d, "missing") == NULL, "dict get miss returns NULL");
    eigs_value_release(d);

    /* --- Buffers: the binary carrier across the host boundary. ------- */
    EigsValue *buf = eigs_value_new_buffer(4);
    CHECK(eigs_value_type(buf) == EIGS_TYPE_BUFFER, "new buffer type");
    CHECK(eigs_value_buffer_len(buf) == 4, "buffer len");
    eigs_value_buffer_set(buf, 0, 7.0);
    eigs_value_buffer_set(buf, 3, 255.0);
    eigs_value_buffer_set(buf, 4, 999.0);            /* OOB: must be a no-op */
    eigs_value_buffer_set(buf, -1, 999.0);
    CHECK(eigs_value_buffer_get(buf, 0) == 7.0,   "buffer get [0]");
    CHECK(eigs_value_buffer_get(buf, 1) == 0.0,   "buffer zero-filled");
    CHECK(eigs_value_buffer_get(buf, 3) == 255.0, "buffer get [3]");
    CHECK(eigs_value_buffer_get(buf, 4) == 0.0,   "buffer OOB get is 0");
    CHECK(eigs_value_buffer_get(buf, -1) == 0.0,  "buffer negative get is 0");

    /* Host buffer visible to script — SAME object, no copy at the
     * boundary: the script's buf_set is visible back in C. */
    eigs_set_global("hbuf", buf);
    r = eigs_eval_string("buf_set of [hbuf, 1, (buf_get of [hbuf, 0]) + 10]\n"
                         "buf_len of hbuf");
    CHECK(r != NULL && eigs_value_as_num(r) == 4.0, "script sees host buffer len");
    if (r) eigs_value_release(r);
    CHECK(eigs_value_buffer_get(buf, 1) == 17.0,
          "script buf_set visible to host (shared object)");
    eigs_value_release(buf);

    /* Script-created buffer read from the host. */
    r = eigs_eval_string("sb is buffer of 3\nbuf_set of [sb, 2, 42]\nsb");
    CHECK(r != NULL && eigs_value_type(r) == EIGS_TYPE_BUFFER,
          "script buffer arrives as EIGS_TYPE_BUFFER");
    CHECK(eigs_value_buffer_len(r) == 3, "script buffer len via embed");
    CHECK(eigs_value_buffer_get(r, 2) == 42.0, "script buffer element via embed");
    if (r) eigs_value_release(r);

    /* Degenerate constructions stay safe. */
    EigsValue *zb = eigs_value_new_buffer(-5);
    CHECK(eigs_value_buffer_len(zb) == 0, "negative count clamps to empty");
    CHECK(eigs_value_buffer_get(zb, 0) == 0.0, "empty buffer get is 0");
    eigs_value_release(zb);
    CHECK(eigs_value_buffer_len(NULL) == 0, "NULL buffer len is 0");
    EigsValue *notbuf = eigs_value_new_num(1.0);
    CHECK(eigs_value_buffer_len(notbuf) == 0, "non-buffer len is 0");
    eigs_value_buffer_set(notbuf, 0, 5.0);           /* wrong type: no-op */
    CHECK(eigs_value_as_num(notbuf) == 1.0, "non-buffer set is a no-op");
    eigs_value_release(notbuf);

    /* --- Trace tape seam: record via the sink, replay from memory. --- */
    eigs_register_function("host_sensor", host_sensor);
    eigs_set_trace_sink(tape_sink, NULL);
    r = eigs_eval_string("s1 is host_sensor of []\n"
                         "s2 is host_sensor of []\n"
                         "s1 * 1000 + s2");
    CHECK(r != NULL && eigs_value_as_num(r) == 100101.0,
          "live sensor reads 100 then 101");
    if (r) eigs_value_release(r);
    eigs_set_trace_sink(NULL, NULL);
    CHECK(g_tape_len > 0, "sink captured tape bytes");
    g_tape[g_tape_len < sizeof g_tape ? g_tape_len : sizeof g_tape - 1] = 0;
    CHECK(strstr(g_tape, "N host_sensor=100") != NULL, "tape has N record 100");
    CHECK(strstr(g_tape, "N host_sensor=101") != NULL, "tape has N record 101");
    CHECK(strstr(g_tape, "A s1=100") != NULL, "tape has assignment record");

    /* recording stopped: another live read advances but adds no bytes */
    size_t tape_frozen = g_tape_len;
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 102.0, "sink off: live 102");
    if (r) eigs_value_release(r);
    CHECK(g_tape_len == tape_frozen, "sink off: no new tape bytes");

    /* replay: the tape's recorded values are served instead of the live
     * source (which would read 103/104 by now) */
    CHECK(eigs_set_replay_tape(g_tape, g_tape_len, 0) == 1, "replay tape set");
    r = eigs_eval_string("r1 is host_sensor of []\n"
                         "r2 is host_sensor of []\n"
                         "r1 * 1000 + r2");
    CHECK(r != NULL && eigs_value_as_num(r) == 100101.0,
          "replay serves recorded 100 then 101");
    if (r) eigs_value_release(r);
    /* tape exhausted: the builtin falls back to its live source */
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 103.0,
          "tape exhausted: live source resumes");
    if (r) eigs_value_release(r);
    CHECK(eigs_set_replay_tape(NULL, 0, 0) == 1, "replay cleared");
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 104.0, "clear: live again");
    if (r) eigs_value_release(r);

    /* --- #411 refusal contract: install-time, atomic, return 0. ------ */
    /* Headerless tape: refused, nothing installed, live source intact. */
    static const char noh[] = "N host_sensor=999\n";
    CHECK(eigs_set_replay_tape(noh, sizeof noh - 1, 0) == 0,
          "headerless tape refused (return 0)");
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 105.0,
          "refused install: live source untouched");
    if (r) eigs_value_release(r);

    /* Mixed-version concatenated journal: a later session's mismatched
     * header refuses the WHOLE install up front — never a mid-eval abort. */
    static char mixed[sizeof g_tape + 64];
    size_t ml = g_tape_len;
    memcpy(mixed, g_tape, ml);
    ml += (size_t)snprintf(mixed + ml, sizeof mixed - ml,
                           "V 1 0.0.0-elsewhere\nN host_sensor=888\n");
    CHECK(eigs_set_replay_tape(mixed, ml, 0) == 0,
          "mixed-version journal refused at install");

    /* Atomic swap: a refused install leaves the ACTIVE tape serving. */
    CHECK(eigs_set_replay_tape(g_tape, g_tape_len, 0) == 1, "good tape re-set");
    CHECK(eigs_set_replay_tape(noh, sizeof noh - 1, 0) == 0, "swap refused");
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 100.0,
          "refused swap: previous tape still serves");
    if (r) eigs_value_release(r);
    CHECK(eigs_set_replay_tape(NULL, 0, 0) == 1, "replay cleared (411 block)");

    /* --- Source provider: import resolves from the embedder. --------- */
    eigs_set_source_provider(smoke_provider, NULL);
    r = eigs_eval_string("import smokemod\nsmokemod[\"answer\"]");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0,
          "provider-served module: import + binding");
    if (r) eigs_value_release(r);
    r = eigs_eval_string("import smokemod\nsmokemod.twice of 21");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0,
          "provider-served module: cache hit + fn call");
    if (r) eigs_value_release(r);
    /* Provider miss falls back to the filesystem chain (hosted). */
    r = eigs_eval_string("import math\nmath.abs of -7");
    CHECK(r != NULL && eigs_value_as_num(r) == 7.0,
          "provider miss falls back to filesystem import");
    if (r) eigs_value_release(r);
    eigs_set_source_provider(NULL, NULL);

    /* --- Multi-state switching on one thread (the M9 scheduler seam). */
    EigsState *st2 = eigs_state_new();
    CHECK(st2 != NULL, "second state created");
    CHECK(eigs_thread_switch(st2) != NULL, "switch to st2");
    eigs_state_init_runtime(st2);
    r = eigs_eval_string("mstate is 11\nmstate");
    CHECK(r != NULL && eigs_value_as_num(r) == 11.0, "eval on st2");
    if (r) eigs_value_release(r);
    /* The source provider is process-global: it serves every state. */
    eigs_set_source_provider(smoke_provider, NULL);
    r = eigs_eval_string("import smokemod\nsmokemod[\"answer\"]");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0, "provider serves st2 too");
    if (r) eigs_value_release(r);
    eigs_set_source_provider(NULL, NULL);
    CHECK(eigs_thread_switch(st) != NULL, "switch back to st1 (parked, no teardown)");
    eigs_clear_error();
    r = eigs_eval_string("mstate");
    CHECK(r == NULL && eigs_has_error(), "st1 does not see st2's binding");
    eigs_clear_error();
    r = eigs_eval_string("z + 2");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0,
          "st1 bindings preserved across switches");
    if (r) eigs_value_release(r);
    CHECK(eigs_thread_switch(st2) != NULL, "switch to st2 for close");
    eigs_close(st2);                 /* full teardown; thread left detached */
    CHECK(eigs_thread_switch(st) != NULL, "re-activate st1 after st2 close");

    /* --- #301: spawn + channel through the embed path. eigs_close() must
     * drain the handle table (reap workers, free channels, clear multithreaded)
     * just like main.c — otherwise embedders leak channels/threads, the exit
     * collector silently no-ops, and a live worker can UAF the freed state. */
    /* #410: a hard timeout must hold at FULL SPEED. The gap was the
     * FROM-ZERO thunk: a call-hot function's loop closes natively via the
     * backward patch and never touches an interpreted back-edge (the OSR
     * tier exits at its own back-edge each iteration, so it always polled
     * via CASE(JUMP_BACK)). Warm the function past the call threshold with
     * tiny bounds, then run one long call: pre-#410 the timer was ignored
     * and the loop ran to the 100M iteration cap (r == 1e8, no error); now
     * the native back-edge polls. Bounded body so a regression fails
     * loudly, not as a hang. MUST run before the spawn test below —
     * g_vm_multithreaded permanently gates JIT compilation off for the
     * process, so a later placement would test the interpreter twice. */
    eigs_set_abort_flag(&g_abort);
    arm_abort_timer_ms(150);
    r = eigs_eval_string(
        "define hot(n) as:\n"
        "    k is 0.0\n"
        "    loop while k < n:\n"
        "        k is k + 1.0\n"
        "    return k\n"
        "w is 0\n"
        "loop while w < 300:\n"
        "    z is hot of 50.0\n"
        "    w is w + 1\n"
        "hot of 200000000.0");
    CHECK(r == NULL && eigs_has_error(),
          "mid-eval abort stops a JIT'd hot loop (#410)");
    CHECK(eigs_last_error_message() &&
          strstr(eigs_last_error_message(), "aborted") != NULL,
          "JIT'd abort raises the 'aborted' error");
    eigs_clear_error();
    eigs_set_abort_flag(NULL);

    r = eigs_eval_string(
        "ch is channel of 1\n"
        "define producer(c) as:\n"
        "    send of [c, 42]\n"
        "h is spawn of [producer, ch]\n"
        "got is recv of ch\n"
        "thread_join of h\n"
        "got");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0, "embed spawn+channel roundtrip");
    eigs_value_release(r);

    /* Async abort seam: a pre-set flag kills the eval at its first
     * back-edge (proves the plumbing), and an interval timer firing
     * MID-eval kills an otherwise-unbounded loop (the real ctrl-c /
     * timeout shape). Both must consume the flag and leave the state
     * usable for the next eval. */
    eigs_set_abort_flag(&g_abort);
    g_abort = 1;
    r = eigs_eval_string("i is 0\nloop while 1:\n    i is i + 1\ni");
    CHECK(r == NULL && eigs_has_error(), "pre-set abort flag stops the loop");
    CHECK(eigs_last_error_message() &&
          strstr(eigs_last_error_message(), "aborted") != NULL,
          "abort raises the 'aborted' error");
    CHECK(g_abort == 0, "abort flag is consumed when honored");
    eigs_clear_error();

    arm_abort_timer_ms(150);
    r = eigs_eval_string("j is 0\nloop while 1:\n    j is j + 1\nj");
    CHECK(r == NULL && eigs_has_error(), "mid-eval abort stops an unbounded loop");
    eigs_clear_error();

    r = eigs_eval_string("6 * 7");
    CHECK(r != NULL && eigs_value_as_num(r) == 42.0, "state usable after aborts");
    eigs_value_release(r);
    eigs_set_abort_flag(NULL);

    /* Leave a recv-blocked, never-joined worker for eigs_close to reap — this
     * hangs (or leaks/UAFs) unless eigs_close drains (close+wake+join, #303). */
    r = eigs_eval_string(
        "ch2 is channel of 1\n"
        "w is spawn of [recv, ch2]\n"
        "1");
    CHECK(r != NULL, "embed leaves a recv-blocked worker for eigs_close to reap");
    eigs_value_release(r);

    eigs_close(st);

    if (failures == 0) {
        printf("embed_smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "embed_smoke: %d failure(s)\n", failures);
    return 1;
}
