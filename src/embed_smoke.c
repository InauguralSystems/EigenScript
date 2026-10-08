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
#include <math.h>
#include <signal.h>
#include <sys/time.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>

#include "eigs_embed.h"
/* #830: the trace seam an ALTERNATIVE PRODUCER uses. The AOT (sibling
 * `ouroboros` repo) emits C that includes this same header off the runtime's
 * src/ and drives the history directly — no bytecode compiler anywhere in the
 * process. Reached here by quoted include, exactly as an out-of-tree producer
 * reaches it. */
#include "trace.h"
/* #797: the lint + raw-JSON-parse symbols. The full internal header
 * coexists with eigs_embed.h here exactly as it does for an in-process
 * embedder that links the runtime and lints project files itself. */
#include "eigenscript.h"

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

/* #1149: host I/O deliberately outlives an exited eval. One byte releases
 * it; the five-second poll is a failure bound, never the success oracle.
 * All worker-owned state stays live until eigs_close has joined it. */
typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int pipefd[2], entered, released, io_done, timed_out;
    int scope_case, seen_code, late_code, nested_calls, nested_refused, continued;
    EigsState *state;
    int handle_id, requested;
    uint32_t handle_gen;
} ExitFixture;
static ExitFixture *exit_fixture;

static EigsValue *exit_nested(EigsValue *arg) {
    (void)arg;
    __atomic_add_fetch(&exit_fixture->nested_calls, 1, __ATOMIC_RELAXED);
    return make_null();
}

static EigsValue *exit_io(EigsValue *arg) {
    (void)arg;
    ExitFixture *f = exit_fixture;
    pthread_mutex_lock(&f->mutex);
    f->entered = 1;
    pthread_cond_broadcast(&f->cond);
    pthread_mutex_unlock(&f->mutex);
    struct pollfd pfd = {.fd = f->pipefd[0], .events = POLLIN};
    char byte = 0;
    int ready = poll(&pfd, 1, 5000);
    if (ready != 1 || read(f->pipefd[0], &byte, 1) != 1 || byte != 'x')
        __atomic_store_n(&f->timed_out, 1, __ATOMIC_RELAXED);
    if (f->scope_case) {
        /* This callback was spawned directly, so it has no VM frame. Its
         * nested eval must still inherit the worker's stopped scope. */
        EigsValue *nested = eigs_eval_string("host_nested of null");
        f->nested_refused = nested == NULL && g_exit_requested;
        eigs_value_release(nested);
        f->seen_code = -1;
        (void)eigs_state_exit_requested(f->state, &f->seen_code);
        /* This nested spawn happens AFTER the next eval started. It must
         * inherit this worker's stopped scope, and never call exit_nested. */
        Value *fn = make_builtin(exit_nested);
        Value *child = builtin_spawn(fn);
        val_decref(fn);
        Value *result = builtin_thread_join(child);
        val_decref(result);
        val_decref(child);
        eigs_state_request_exit(f->state, 99);
        f->late_code = -1;
        (void)eigs_state_exit_requested(f->state, &f->late_code);
    }
    __atomic_store_n(&f->io_done, 1, __ATOMIC_RELEASE);
    return make_null();
}

static EigsValue *exit_entered(EigsValue *arg) {
    (void)arg;
    ExitFixture *f = exit_fixture;
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += 5;
    pthread_mutex_lock(&f->mutex);
    while (!f->entered) {
        if (pthread_cond_timedwait(&f->cond, &f->mutex, &until) == ETIMEDOUT) {
            __atomic_store_n(&f->timed_out, 1, __ATOMIC_RELAXED);
            break;
        }
    }
    pthread_mutex_unlock(&f->mutex);
    return make_null();
}

static EigsValue *exit_release(EigsValue *arg) {
    (void)arg;
    exit_fixture->released = 1;
    CHECK(write(exit_fixture->pipefd[1], "x", 1) == 1, "exit fixture releases one byte");
    return make_null();
}

static EigsValue *exit_continued(EigsValue *arg) {
    (void)arg;
    __atomic_add_fetch(&exit_fixture->continued, 1, __ATOMIC_RELAXED);
    return make_null();
}

/* Drive the stop only AFTER the real generation-checked join claimed its
 * target. A worker exiting immediately after spawn could stop main before it
 * reaches thread_join, which would not test interruptibility of that wait. */
static void *exit_after_join_claim(void *arg) {
    ExitFixture *f = arg;
    for (int i = 0; i < 5000; i++) {
        pthread_mutex_lock(&f->state->handle_mutex);
        EigsHandleSlot *slot = &f->state->handle_table[f->handle_id];
        int claimed = slot->gen == f->handle_gen && slot->ptr == NULL;
        pthread_mutex_unlock(&f->state->handle_mutex);
        if (claimed) {
            eigs_state_request_exit(f->state, 5);
            f->requested = 1;
            return NULL;
        }
        usleep(1000);
    }
    return NULL;
}

static void test_worker_exit_lifecycle(void) {
    for (int scope_case = 0; scope_case < 2; scope_case++) {
        ExitFixture f = {.mutex = PTHREAD_MUTEX_INITIALIZER,
                         .cond = PTHREAD_COND_INITIALIZER,
                         .scope_case = scope_case};
        if (pipe(f.pipefd) != 0) { CHECK(0, "exit fixture pipe"); return; }
        exit_fixture = &f;
        f.state = eigs_open();
        CHECK(f.state != NULL, "exit fixture opens state");
        if (!f.state) { close(f.pipefd[0]); close(f.pipefd[1]); return; }
        eigs_register_function("host_io", exit_io);
        eigs_register_function("host_entered", exit_entered);
        eigs_register_function("host_release", exit_release);
        eigs_register_function("host_continued", exit_continued);
        eigs_register_function("host_nested", exit_nested);
        char source[320];
        snprintf(source, sizeof source,
            "define old_worker() as:\n"
            "    host_io of null\n"
            "    host_continued of null\n"
            "worker is spawn of %s\n"
            "host_entered of null\n%s", scope_case ? "host_io" : "old_worker",
            scope_case ? "exit of 5" : "0");
        EigsValue *r = eigs_eval_string(source);
        CHECK(f.entered && (scope_case ? r == NULL && g_exit_requested : r != NULL),
              "exit fixture target entered native I/O before eval returned");
        eigs_value_release(r);
        if (scope_case) {
            eigs_clear_error();
            r = eigs_eval_string(
                "host_release of null\nthread_join of worker\n"
                "i is 0\nloop while i < 2:\n    i is i + 1\n"
                "try:\n    throw of 7\ncatch e:\n    i + 40");
            CHECK(r != NULL && eigs_value_as_num(r) == 42,
                  "new eval runs while old worker retains its stop");
            eigs_value_release(r);
        } else {
            EigsValue *handle = eigs_get_global("worker");
            CHECK(handle && handle->type == VAL_DICT, "exit fixture owns join handle");
            if (handle && handle->type == VAL_DICT) {
                f.handle_id = (int)VAL_NUM_RAW(dict_get(handle, "_handle_id"));
                f.handle_gen = (uint32_t)VAL_NUM_RAW(dict_get(handle, "_handle_gen"));
                pthread_t requester;
                int made = pthread_create(&requester, NULL, exit_after_join_claim, &f) == 0;
                CHECK(made, "exit fixture starts request coordinator");
                if (made) {
                    r = builtin_thread_join(handle);
                    eigs_value_release(r);
                    pthread_join(requester, NULL);
                    CHECK(f.requested && !__atomic_load_n(&f.io_done, __ATOMIC_ACQUIRE),
                          "thread_join returns on exit before target I/O completes");
                    CHECK(f.state->deferred_threads != NULL &&
                          __atomic_load_n(&f.state->live_workers, __ATOMIC_ACQUIRE) == 1,
                          "interrupted join keeps one worker owned for deferred reaping");
                    r = eigs_eval_string("6 * 7");
                    CHECK(r && eigs_value_as_num(r) == 42,
                          "new eval runs with old joined target still in native I/O");
                    eigs_value_release(r);
                }
            }
            eigs_value_release(handle);
            r = exit_release(NULL);
            eigs_value_release(r);
        }
        eigs_close(f.state); /* reap normal and interrupted claims before free */
        CHECK(f.entered && f.released && f.io_done && !f.timed_out,
              "exit lifecycle fixture completed every I/O handshake without timeout");
        CHECK(f.continued == 0, "stopped old worker executes no later script statement");
        if (scope_case) {
            CHECK(f.seen_code == 5 && f.late_code == 5,
                  "old worker retains immutable first-exit status across new eval");
            CHECK(f.nested_refused && f.nested_calls == 0,
                  "nested eval and late nested spawn inherit stopped old scope");
        }
        close(f.pipefd[0]); close(f.pipefd[1]);
        pthread_cond_destroy(&f.cond);
        pthread_mutex_destroy(&f.mutex);
        exit_fixture = NULL;
    }
}

/* Source provider for the M7.5 module seam: serves one module. */
static const char *smoke_provider(const char *name, void *ud) {
    (void)ud;
    if (strcmp(name, "smokemod") == 0)
        return "answer is 42\ndefine twice(k) as:\n    return k * 2\n";
    /* #1388: module code calling a builtin, a registered function, a
     * builtin name the host set as a global, and a plain host global. */
    if (strcmp(name, "isomod") == 0)
        return "define m_len(xs) as:\n    return len of xs\n"
               "define m_add() as:\n    return host_add of [3, 4]\n"
               "define m_str() as:\n    return str of 5\n"
               "define m_glob() as:\n    return iso_g\n";
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
    /* Check the types: eigs_value_as_num answers NaN for a bool and 0.0 for
     * other non-numbers, so an unchecked read turns `host_add of [true, 1]`
     * into a wrong number. */
    EigsValue *r = (eigs_value_type(a) == EIGS_TYPE_NUM && eigs_value_type(b) == EIGS_TYPE_NUM)
        ? eigs_value_new_num(eigs_value_as_num(a) + eigs_value_as_num(b))
        : eigs_value_new_null();
    eigs_value_release(a);
    eigs_value_release(b);
    return r;
}

/* #1434: runs an eval that raises on its line 5, swallows that error, then
 * raises its own (a refused bind) with the caller's frame live. */
static EigsValue *host_swallow(EigsValue *arg) {
    (void)arg;
    EigsValue *v = eigs_eval_string("a is 1\nb is 2\nc is 3\nd is 4\ne is a / 0\n");
    if (v) eigs_value_release(v);
    eigs_clear_error();
    EigsValue *one = eigs_value_new_num(1.0);
    eigs_set_global("_#fstr", one);
    eigs_value_release(one);
    return eigs_value_new_null();
}

int main(void) {
    EigsState *st = eigs_open();
    CHECK(st != NULL, "eigs_open");

    /* --- #830: temporal reads from a NON-COMPILER PRODUCER. -----------
     * This is the AOT's exact shape, and it runs FIRST on purpose: not one
     * line of EigenScript source has been compiled yet, so nothing has armed
     * a history name — which is precisely the state an AOT-compiled binary
     * (and any embedder driving the trace seam) lives in for its whole run.
     * #827 filtered the history on that armed-name set, so v0.35.1 dropped
     * every assignment here and answered `null` to every `prev of` /
     * `at`-qualified read in an AOT binary. It shipped, and the suite stayed
     * green, because nothing tested a producer other than the compiler.
     *
     * Must stay ahead of the spawn tests below: `spawn` widens the armed set
     * to the wildcard (trace_arm_history_all_mt), which would mask the bug.
     *
     * The name is one pointer used for both the record and the query — the
     * prev-table is keyed by pointer identity, which is what "interned name"
     * means at this seam, and what the AOT gets from C literal pooling. */
    {
        static const char *const NM = "aot_x";
        EigsSlot s, out;
        int line_save = g_trace_current_line;

        g_trace_current_line = 10;
        SLOT_NUM_RAW(s) = 11.0; trace_assign(NM, s);
        g_trace_current_line = 20;
        SLOT_NUM_RAW(s) = 22.0; trace_assign(NM, s);

        CHECK(trace_query_prev(NM, &out) && SLOT_NUM_RAW(out) == 11.0,
              "#830: prev of a name recorded by a non-compiler producer");
        /* TEMPORAL-BACKWARD: at 15 the answer is the line-10 assignment. */
        CHECK(trace_query_at(0, NM, 15, &out) && SLOT_NUM_RAW(out) == 11.0,
              "#830: what-at from a non-compiler producer (line-10 value)");
        CHECK(trace_query_at(0, NM, 99, &out) && SLOT_NUM_RAW(out) == 22.0,
              "#830: what-at past the last non-compiler assignment");
        CHECK(trace_query_at(2, NM, 99, &out) && SLOT_NUM_RAW(out) == 2.0,
              "#830: when-at counts non-compiler assignments");

        g_trace_current_line = line_save;
    }

    /* #1394: strictness is state-local embedder configuration. Reuse the
     * one-shot state already keeping the process alive, then create a staged
     * sibling. Closing that sibling must not perform process-wide trace
     * shutdown and accidentally arm all history names. */
    {
        eigs_state_set_strict(NULL, 1); /* lifecycle setters are NULL-safe */
        eigs_state_set_strict(st, 0);

        EigsState *strict = eigs_state_new();
        CHECK(strict != NULL, "#1394 create staged strict state");
        eigs_state_set_strict(strict, -1); /* every nonzero value enables */
        CHECK(eigs_thread_switch(strict) != NULL, "#1394 switch to strict state");
        CHECK(eigs_state_init_runtime(strict) == 0, "#1394 init staged strict state");
        EigsValue *strict_result = eigs_eval_string("abs of \"x\"");
        CHECK(strict_result == NULL && eigs_has_error(),
              "#1394 strict state rejects abs(string)");
        eigs_value_release(strict_result);
        eigs_clear_error();

        CHECK(eigs_thread_switch(st) != NULL, "#1394 switch to non-strict state");
        EigsValue *soft_result = eigs_eval_string("abs of \"x\"");
        CHECK(soft_result != NULL && eigs_value_type(soft_result) == EIGS_TYPE_NUM &&
                  eigs_value_as_num(soft_result) == 0.0 && !eigs_has_error(),
              "#1394 non-strict state returns the finite stand-in");
        eigs_value_release(soft_result);

        CHECK(eigs_thread_switch(strict) != NULL, "#1394 switch back to strict state");
        eigs_close(strict);
        CHECK(eigs_thread_switch(st) != NULL, "#1394 restore non-strict state");
        soft_result = eigs_eval_string("abs of \"x\"");
        CHECK(soft_result != NULL && eigs_value_as_num(soft_result) == 0.0 &&
                  !eigs_has_error(),
              "#1394 non-strict state remains non-strict after switching");
        eigs_value_release(soft_result);
    }

    /* --- Eval a script that defines a global. ------------------------ */
    EigsValue *r = eigs_eval_string("x is 5\ny is x * 7\ny");
    CHECK(r != NULL, "eval returns a value");
    CHECK(eigs_value_type(r) == EIGS_TYPE_NUM, "eval result is num");
    CHECK(eigs_value_as_num(r) == 35.0, "5 * 7 == 35");
    eigs_value_release(r);

    /* --- Composition seam (#742): the embed API builds the global env
     * through register_builtins alone, so every compiled-in extension is
     * present here, not just through the CLI. store is always compiled;
     * gfx rides when built with EIGENSCRIPT_EXT_GFX (pre-#742 only main.c
     * registered gfx, so a gfx build used through this API had no gfx
     * builtins at all — `make embed-smoke-gfx` pins that leg). ---------- */
    r = eigs_eval_string("type of store_open");
    CHECK(r != NULL && eigs_value_type(r) == EIGS_TYPE_STR &&
              strcmp(eigs_value_as_string(r), "builtin") == 0,
          "store_open composed via the embed seam");
    eigs_value_release(r);
#if EIGENSCRIPT_EXT_GFX
    r = eigs_eval_string("type of gfx_open");
    CHECK(r != NULL && eigs_value_type(r) == EIGS_TYPE_STR &&
              strcmp(eigs_value_as_string(r), "builtin") == 0,
          "gfx_open composed via the embed seam (#742)");
    eigs_value_release(r);
#endif

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

    /* #1102: source reservation is shared by the embedding parser. A
     * rejected unit must not execute its earlier assignment, and another
     * eval must recover with no stale diagnostic code. */
    {
        const char *names[] = {"report", "report_value"};
        for (int i = 0; i < 2; i++) {
            char source[192];
            snprintf(source, sizeof(source),
                     "embed_reserved_ran is 1\ndefine f(\n  %s\n) as:\n    return 0\n",
                     names[i]);
            r = eigs_eval_string(source);
            CHECK(r == NULL && g_parse_errors > 0,
                  "reserved observer parameter rejected by embed eval");
            CHECK(g_first_error_line == 3 && g_first_error_code &&
                  strcmp(g_first_error_code, "E005") == 0 &&
                  strstr(g_first_error_msg, "reserved observer form"),
                  "embed reserved diagnostic code and offending line");
            eigs_value_release(r);
            EigsValue *ran = eigs_get_global("embed_reserved_ran");
            CHECK(!ran || eigs_value_type(ran) == EIGS_TYPE_NULL,
                  "embed rejected unit executes no earlier statement");
            eigs_value_release(ran);
            r = eigs_eval_string("1 + 2");
            CHECK(r && eigs_value_as_num(r) == 3.0 && g_first_error_line == 0,
                  "embed recovers after reserved observer error");
            eigs_value_release(r);
        }
    }

    /* --- FFI: register a C function, call from script. --------------- */
    eigs_register_function("host_add", host_add);
    r = eigs_eval_string("host_add of [3, 4]");
    CHECK(r != NULL, "FFI eval returns value");
    CHECK(r && eigs_value_type(r) == EIGS_TYPE_NUM, "FFI result is num");
    CHECK(r && eigs_value_as_num(r) == 7.0, "host_add(3,4) == 7");
    eigs_value_release(r);
    /* #1637: a bool reads as NaN through eigs_value_as_num (never 0.0); the
     * typed host function refuses it; other non-numbers keep 0.0. */
    r = eigs_eval_string("5 > 3");
    CHECK(r && eigs_value_type(r) == EIGS_TYPE_BOOL && isnan(eigs_value_as_num(r)),
          "eigs_value_as_num of a bool is NaN");
    CHECK(r && eigs_value_as_bool(r) == 1, "eigs_value_as_bool reads the bool");
    eigs_value_release(r);
    r = eigs_eval_string("\"s\"");
    CHECK(r && eigs_value_as_num(r) == 0.0, "eigs_value_as_num of a string stays 0.0");
    eigs_value_release(r);
    r = eigs_eval_string("host_add of [true, 1]");
    CHECK(r && eigs_value_type(r) == EIGS_TYPE_NULL, "host_add refuses a bool operand");
    eigs_value_release(r);

    /* --- #1387: embed API errors do not inherit an eval's last line. -- */
    {
        r = eigs_eval_string("a is 1\nb is 2\nc is 3\nd is 4\ne is 5\n");
        if (r) eigs_value_release(r);
        eigs_clear_error();
        EigsValue *one = eigs_value_new_num(1.0);
        eigs_set_global("_#fstr", one);
        CHECK(eigs_has_error() && eigs_last_error_line() == 0,
              "#1387 set_global after an eval has no stale source line");
        eigs_value_release(one);
        eigs_clear_error();
    }

    /* --- #1322: the embed API refuses reserved runtime names. -------- */
    /* `_#fstr` is the f-string conversion binding; binding it would hijack
     * every f-string. Each door refuses, leaves a "value" error pending, and
     * f-strings keep the builtin conversion. */
    {
        EigsValue *seven = eigs_value_new_num(7.0);
        eigs_clear_error();
        eigs_set_global("_#fstr", seven);
        CHECK(eigs_has_error() && eigs_last_error_kind() &&
              strcmp(eigs_last_error_kind(), "value") == 0,
              "#1322 set_global of a reserved name is refused with a value error");
        eigs_value_release(seven);
        eigs_clear_error();
        eigs_register_function("_#fstr", host_add);
        CHECK(eigs_has_error(), "#1322 register_function of a reserved name is refused");
        eigs_clear_error();
        EigsValue *g = eigs_get_global("_#fstr");
        CHECK(g == NULL && eigs_has_error(), "#1322 get_global of a reserved name is refused");
        if (g) eigs_value_release(g);
        eigs_clear_error();
        r = eigs_eval_string("f\"<{5}>\"");
        CHECK(r && eigs_value_type(r) == EIGS_TYPE_STR &&
              strcmp(eigs_value_as_string(r), "<5>") == 0,
              "#1322 f-strings still use the builtin after the refused binds");
        if (r) eigs_value_release(r);
    }

    /* --- #1434: an error after a call into EigenScript reports the line the
     * host entered with, not the last line the called code ran. The host
     * stamps line 30 (the AOT's shape), evaluates three lines, then a refused
     * bind raises with no VM frame live: pre-fix it reported line 3. Then a
     * host function called from line 3 runs an eval whose line-5 raise it
     * swallows, and raises its own: pre-fix `e.line` was 5. */
    {
        int line_save = g_trace_current_line;
        EigsValue *seven = eigs_value_new_num(7.0);
        g_trace_current_line = 30;
        r = eigs_eval_string("p is 1\nq is p + 1\nw is q + 1\n");
        if (r) eigs_value_release(r);
        eigs_clear_error();
        eigs_set_global("_#fstr", seven);
        CHECK(eigs_has_error() && eigs_last_error_line() == 30,
              "#1434 a raise after eigs_eval_string reports the host's line (30)");
        eigs_clear_error();
        eigs_register_function("host_swallow", host_swallow);
        r = eigs_eval_string("x is 1\ntry:\n    z is host_swallow of 1\ncatch e:\n"
                             "    got is e.line\ngot");
        CHECK(r && eigs_value_type(r) == EIGS_TYPE_NUM && eigs_value_as_num(r) == 3.0,
              "#1434 a host function's raise after a swallowed eval error reports its caller's line (3)");
        if (r) eigs_value_release(r);
        eigs_value_release(seven);
        eigs_clear_error();
        g_trace_current_line = line_save;
    }

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
    eigs_value_buffer_set(buf, 2, INFINITY);
    CHECK(eigs_value_buffer_get(buf, 2) == EIGS_NUM_MAX,
          "buffer non-finite get is clamped");

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

    /* #1417: ordinary host buffers can contain NaN. Scalar readers must
     * raise before later elements are read, and a speculative leaf must
     * fall back while its callee source/frame can still be reported. */
    {
        int nf_saved_strict = g_strict;
        unsigned nf_saved_flags = g_math_flags;
        EigsValue *nf_raw = eigs_value_new_buffer(2);
        EigsValue *nf_finite = eigs_value_new_buffer(2);
        EigsValue *nf_later = eigs_value_new_buffer(2);
        eigs_value_buffer_set(nf_raw, 0, NAN);
        eigs_value_buffer_set(nf_raw, 1, INFINITY);
        eigs_value_buffer_set(nf_finite, 0, 3.0);
        eigs_value_buffer_set(nf_finite, 1, 4.0);
        eigs_value_buffer_set(nf_later, 0, INFINITY);
        eigs_value_buffer_set(nf_later, 1, 4.0);
        eigs_set_global("nf_raw", nf_raw);
        eigs_set_global("nf_finite", nf_finite);
        eigs_set_global("nf_later", nf_later);
        eigs_value_release(nf_raw);
        eigs_value_release(nf_finite);
        eigs_value_release(nf_later);
        eigs_state_set_strict(st, 1);
        r = eigs_eval_string("nf_shaped is reshape of [nf_raw, 1, 2]");
        CHECK(r != NULL && !eigs_has_error(),
              "#1417 prepare shaped materialization control");
        eigs_value_release(r);
        const char *nf_reads[] = {
            "nf_raw == nf_raw", "nf_raw == nf_finite",
            "list_contains of [[nf_raw, nf_later], nf_finite]",
            "list_index_of of [[nf_raw, nf_later], nf_finite]",
            "sum of nf_raw", "mean of nf_raw", "norm of nf_raw",
            "sum of ([nf_raw, nf_later])",
            "mean of ([nf_raw, nf_later])",
            "norm of ([nf_raw, nf_later])",
            "dot of [nf_raw, nf_finite]",
            "buf_dot of [nf_raw, nf_finite, 0, 0, 2]",
            "buf_peak of [nf_raw, 0, 2]",
            "str_from_bytes of nf_raw", "f64_from_bytes of nf_raw",
            "buf_from_pcm16le of [nf_raw, 0, 1]",
            "buf_to_pcm16le of [nf_raw, 0, 2]",
            "add of [nf_raw, [0, 0]]", "add of [[0, 0], nf_raw]",
            "subtract of [nf_raw, [0, 0]]", "subtract of [[0, 0], nf_raw]",
            "multiply of [nf_raw, [0, 0]]", "multiply of [[0, 0], nf_raw]",
            "divide of [nf_raw, [1, 1]]", "divide of [[1, 1], nf_raw]",
            "pow of [nf_raw, [1, 1]]", "pow of [[1, 1], nf_raw]",
            "add of [nf_shaped, [[0, 0]]]", "add of [[[0, 0]], nf_shaped]",
            "add of [[[nf_raw], [nf_later]], [[[0, 0]], [[0, 0]]]]",
            "add of [[[[0, 0]], [[0, 0]]], [[nf_raw], [nf_later]]]"
#if EIGENSCRIPT_EXT_ZLIB
            , "inflate of nf_raw"
#endif
#if EIGENSCRIPT_EXT_NET
            , "net_send of [0, nf_raw]"
#endif
        };
        for (size_t i = 0; i < sizeof nf_reads / sizeof nf_reads[0]; i++) {
            g_math_flags = 0;
            r = eigs_eval_string(nf_reads[i]);
            CHECK(r == NULL && eigs_has_error(), nf_reads[i]);
            CHECK(eigs_last_error_kind() &&
                      strcmp(eigs_last_error_kind(), "value") == 0,
                  "#1417 strict scalar read reports value error");
            CHECK(g_math_flags == EIGS_MATH_INVALID,
                  "#1417 stop at NaN before reading later infinity");
            CHECK(eigs_last_error_message() &&
                      strstr(eigs_last_error_message(), "not a number"),
                  "#1417 retain the first NaN diagnostic");
            eigs_value_release(r);
            eigs_clear_error();
        }
        /* The byte wrapper must finish validation before opening/truncating
         * a file. This is one ordinary byte, with a first-read NaN input. */
        char nf_path[] = "/tmp/eigs_nf_bytes_XXXXXX";
        int nf_fd = mkstemp(nf_path);
        CHECK(nf_fd >= 0, "#1417 prepare byte-output control");
        if (nf_fd >= 0) {
            CHECK(write(nf_fd, "Q", 1) == 1, "#1417 initialize byte-output control");
            close(nf_fd);
            EigsValue *nf_path_value = eigs_value_new_string(nf_path);
            eigs_set_global("nf_byte_path", nf_path_value);
            eigs_value_release(nf_path_value);
            g_math_flags = 0;
            r = eigs_eval_string("write_bytes of [nf_byte_path, nf_raw]");
            CHECK(r == NULL && eigs_has_error() && eigs_last_error_kind() &&
                      strcmp(eigs_last_error_kind(), "value") == 0,
                  "#1417 byte sink retains the normalized read error");
            CHECK(g_math_flags == EIGS_MATH_INVALID,
                  "#1417 byte sink stops before the later infinity");
            eigs_value_release(r);
            eigs_clear_error();
            FILE *nf_file = fopen(nf_path, "rb");
            CHECK(nf_file && fgetc(nf_file) == 'Q' && fgetc(nf_file) == EOF,
                  "#1417 failed byte read does not truncate its destination");
            if (nf_file) fclose(nf_file);
            unlink(nf_path);
        }
#if EIGENSCRIPT_EXT_GFX
        /* The PPU builtin is pure computation: no window or device opens.
         * Fixed hardware dimensions are the smallest valid ordinary input. */
        EigsValue *nf_ppu_mem = eigs_value_new_buffer(65536);
        EigsValue *nf_ppu_fb = eigs_value_new_buffer(23040);
        eigs_set_global("nf_ppu_mem", nf_ppu_mem);
        eigs_set_global("nf_ppu_fb", nf_ppu_fb);
        eigs_value_buffer_set(nf_ppu_mem, 0xFF40, NAN);
        eigs_value_buffer_set(nf_ppu_mem, 0xFF42, INFINITY);
        eigs_value_buffer_set(nf_ppu_fb, 0, 9);
        g_math_flags = 0;
        r = eigs_eval_string("ppu_render_frame of [nf_ppu_mem, nf_ppu_fb]");
        CHECK(r == NULL && eigs_has_error() && eigs_last_error_kind() &&
                  strcmp(eigs_last_error_kind(), "value") == 0,
              "#1417 PPU normalizes its first register read");
        CHECK(g_math_flags == EIGS_MATH_INVALID &&
                  eigs_value_buffer_get(nf_ppu_fb, 0) == 9,
              "#1417 PPU register error stops before later reads or writes");
        eigs_value_release(r);
        eigs_clear_error();
        eigs_value_buffer_set(nf_ppu_mem, 0xFF40, 0x91);
        eigs_value_buffer_set(nf_ppu_mem, 0xFF42, 0);
        eigs_value_buffer_set(nf_ppu_mem, 0x9800, NAN);
        g_math_flags = 0;
        r = eigs_eval_string("ppu_render_frame of [nf_ppu_mem, nf_ppu_fb]");
        CHECK(r == NULL && eigs_has_error() && eigs_last_error_kind() &&
                  strcmp(eigs_last_error_kind(), "value") == 0,
              "#1417 PPU normalizes its tile-map byte read");
        CHECK(g_math_flags == EIGS_MATH_INVALID &&
                  eigs_value_buffer_get(nf_ppu_fb, 0) == 9,
              "#1417 PPU tile error stops before framebuffer writes");
        eigs_value_release(r);
        eigs_clear_error();
        eigs_value_buffer_set(nf_ppu_mem, 0xFF40, 0);
        r = eigs_eval_string("ppu_render_frame of [nf_ppu_mem, nf_ppu_fb]");
        CHECK(r != NULL && !eigs_has_error() &&
                  eigs_value_buffer_get(nf_ppu_fb, 0) == 0,
              "#1417 finite LCD-off control still blanks the framebuffer");
        eigs_value_release(r);
        eigs_value_release(nf_ppu_mem);
        eigs_value_release(nf_ppu_fb);
#endif
        /* Validate the entire index vector before scatter writes anything.
         * The second NaN must leave even the earlier valid destination alone. */
        EigsValue *nf_indices = eigs_value_new_buffer(2);
        EigsValue *nf_dst = eigs_value_new_buffer(2);
        eigs_value_buffer_set(nf_indices, 0, 0.0);
        eigs_value_buffer_set(nf_indices, 1, NAN);
        eigs_value_buffer_set(nf_dst, 0, 10.0);
        eigs_value_buffer_set(nf_dst, 1, 20.0);
        eigs_set_global("nf_indices", nf_indices);
        eigs_set_global("nf_dst", nf_dst);
        r = eigs_eval_string("scatter_add of [nf_dst, nf_indices, [5, 5]]");
        CHECK(r == NULL && eigs_has_error() && eigs_last_error_kind() &&
                  strcmp(eigs_last_error_kind(), "value") == 0,
              "#1417 scatter propagates a normalized index error");
        CHECK(eigs_value_buffer_get(nf_dst, 0) == 10.0 &&
                  eigs_value_buffer_get(nf_dst, 1) == 20.0,
              "#1417 scatter index error leaves every destination unchanged");
        eigs_value_release(r);
        eigs_clear_error();

        /* Both the partially filled and first-row failure free gather output.
         * A later invalid index must not replace the first NaN diagnostic. */
        for (int nf_first_row = 0; nf_first_row < 2; nf_first_row++) {
            eigs_value_buffer_set(nf_indices, 0, nf_first_row ? NAN : 0.0);
            eigs_value_buffer_set(nf_indices, 1, nf_first_row ? 2.0 : NAN);
            g_math_flags = 0;
            r = eigs_eval_string("gather of [(buffer of [2, 1]), nf_indices]");
            CHECK(r == NULL && eigs_has_error() && eigs_last_error_kind() &&
                      strcmp(eigs_last_error_kind(), "value") == 0,
                  "#1417 gather retains the first normalized index error");
            CHECK(g_math_flags == EIGS_MATH_INVALID,
                  "#1417 gather stops at its NaN index");
            eigs_value_release(r);
            eigs_clear_error();
        }
        /* The same fallible index helper serves row/column gradient readers
         * and mutators, for both matrix representations. No callback or
         * matrix write may happen after the first index read raises. */
        r = eigs_eval_string("nf_matrix is buffer of [2, 2]\n"
                             "nf_matrix[0] is 10\n"
                             "nf_matrix[1] is 20\n"
                             "nf_matrix[2] is 30\n"
                             "nf_matrix[3] is 40\n"
                             "nf_list_matrix is [[10, 20], [30, 40]]\n"
                             "nf_grad_calls is 0\n"
                             "define nf_loss(n) as:\n"
                             "    nf_grad_calls += 1\n"
                             "    return 1\n");
        CHECK(r != NULL && !eigs_has_error(),
              "#1417 prepare finite index-consumer controls");
        eigs_value_release(r);
        const char *nf_index_reads[] = {
            "numerical_grad_rows of [nf_loss, nf_matrix, nf_indices, 0.01]",
            "numerical_grad_rows of [nf_loss, nf_list_matrix, nf_indices, 0.01]",
            "numerical_grad_cols of [nf_loss, nf_matrix, nf_indices, 0.01]",
            "numerical_grad_cols of [nf_loss, nf_list_matrix, nf_indices, 0.01]",
            "sgd_update_rows of [nf_matrix, nf_matrix, nf_indices, 0.1]",
            "sgd_update_rows of [nf_list_matrix, nf_list_matrix, nf_indices, 0.1]",
            "sgd_update_cols of [nf_matrix, nf_matrix, nf_indices, 0.1]",
            "sgd_update_cols of [nf_list_matrix, nf_list_matrix, nf_indices, 0.1]"
        };
        for (size_t i = 0; i < sizeof nf_index_reads / sizeof nf_index_reads[0]; i++) {
            g_math_flags = 0;
            r = eigs_eval_string(nf_index_reads[i]);
            CHECK(r == NULL && eigs_has_error() && eigs_last_error_kind() &&
                      strcmp(eigs_last_error_kind(), "value") == 0,
                  nf_index_reads[i]);
            CHECK(g_math_flags == EIGS_MATH_INVALID,
                  "#1417 index consumer stops on the first NaN");
            eigs_value_release(r);
            eigs_clear_error();
            r = eigs_eval_string("nf_grad_calls == 0 and "
                                 "nf_matrix[0] == 10 and nf_matrix[1] == 20 and "
                                 "nf_matrix[2] == 30 and nf_matrix[3] == 40 and "
                                 "nf_list_matrix == [[10, 20], [30, 40]]");
            CHECK(r != NULL && eigs_value_as_bool(r) && !eigs_has_error(),
                  "#1417 failed index read performs no callback or matrix write");
            eigs_value_release(r);
        }
        eigs_value_release(nf_indices);
        eigs_value_release(nf_dst);

        r = eigs_eval_string("define nf_first(x, i) as:\n"
                             "    return x[i]\n"
                             "nf_first of [nf_finite, 0]\n");
        CHECK(r != NULL && eigs_value_as_num(r) == 3.0 && !eigs_has_error(),
              "#1417 finite leaf accessor remains usable");
        eigs_value_release(r);
        FILE *nf_capture = tmpfile();
        int nf_stderr = dup(STDERR_FILENO);
        CHECK(nf_capture != NULL && nf_stderr >= 0,
              "#1417 prepare leaf diagnostic capture");
        if (nf_capture && nf_stderr >= 0) {
            fflush(stderr);
            int nf_redirected = dup2(fileno(nf_capture), STDERR_FILENO);
            CHECK(nf_redirected >= 0, "#1417 capture leaf diagnostic");
            if (nf_redirected >= 0) {
                r = eigs_eval_string("nf_first of [nf_raw, 0]\n");
                CHECK(r == NULL && eigs_has_error(),
                      "#1417 strict NaN leaf raises");
                CHECK(eigs_last_error_line() == 2,
                      "#1417 leaf error retains indexed callee line");
                eigs_value_release(r);
                fflush(stderr);
                CHECK(dup2(nf_stderr, STDERR_FILENO) >= 0,
                      "#1417 restore diagnostic stream");
                rewind(nf_capture);
                char nf_diag[1024];
                size_t nf_size = fread(nf_diag, 1, sizeof nf_diag - 1, nf_capture);
                nf_diag[nf_size] = '\0';
                CHECK(strstr(nf_diag, "  at nf_first (line 2)") != NULL,
                      "#1417 leaf error retains callee frame");
                eigs_clear_error();
            }
        }
        if (nf_stderr >= 0) close(nf_stderr);
        if (nf_capture) fclose(nf_capture);
        eigs_state_set_strict(st, nf_saved_strict);
        g_math_flags = nf_saved_flags;
    }

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
    eigs_trace_declare_kind("host_sensor", EIGS_KIND(EIGS_TYPE_NUM));   /* #1637 */
    eigs_set_trace_sink(tape_sink, NULL);
    r = eigs_eval_string("s1 is host_sensor of []\n"
                         "s2 is host_sensor of []\n"
                         "s1 * 1000 + s2");
    CHECK(r != NULL && eigs_value_as_num(r) == 100101.0,
          "live sensor reads 100 then 101");
    if (r) eigs_value_release(r);

    /* #1441: once the interpreted callback above has returned, a native
     * producer has no VM frame.  Its assignment belongs to module/native
     * scope, not to the callback frame named by the tape's preceding S. */
    {
        static const char *const NM = "native_after_callback";
        EigsSlot s;
        SLOT_NUM_RAW(s) = 1441.0;
        trace_assign(NM, s);
        g_tape[g_tape_len < sizeof g_tape ? g_tape_len : sizeof g_tape - 1] = 0;
        CHECK(strstr(g_tape, "S 0 <native> 0 0\nA 0 native_after_callback=1441\n") != NULL,
              "native assignment after callback carries native scope");
    }
    eigs_set_trace_sink(NULL, NULL);
    CHECK(g_tape_len > 0, "sink captured tape bytes");
    g_tape[g_tape_len < sizeof g_tape ? g_tape_len : sizeof g_tape - 1] = 0;
    CHECK(strstr(g_tape, "N 0 host_sensor=100") != NULL, "tape has N record 100");
    CHECK(strstr(g_tape, "N 0 host_sensor=101") != NULL, "tape has N record 101");
    CHECK(strstr(g_tape, "A 0 s1=100") != NULL, "tape has assignment record");

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
    /* Exhaustion is a replay error; it must not consult the live sensor. */
    r = eigs_eval_string("host_sensor of []");
    CHECK(r == NULL, "tape exhausted: replay raises without a live read");
    if (r) eigs_value_release(r);
    CHECK(eigs_set_replay_tape(NULL, 0, 0) == 1, "replay cleared");
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 103.0, "clear: live again");
    if (r) eigs_value_release(r);

    /* --- #411 refusal contract: install-time, atomic, return 0. ------ */
    /* Headerless tape: refused, nothing installed, live source intact. */
    static const char noh[] = "N host_sensor=999\n";
    CHECK(eigs_set_replay_tape(noh, sizeof noh - 1, 0) == 0,
          "headerless tape refused (return 0)");
    r = eigs_eval_string("host_sensor of []");
    CHECK(r != NULL && eigs_value_as_num(r) == 104.0,
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
    /* --- #1388: module builtins are isolated from the host's rebinding.
     * The host rebinds `len` with a top-level `is` (sealed: the builtin layer
     * is never written), rebinds the registered `host_add`, and sets a global
     * named `str`; module code still sees the builtins and the registered
     * function. A non-builtin eigs_set_global value stays readable from
     * module code (the layer's parent is the global scope). */
    eigs_set_source_provider(smoke_provider, NULL);
    r = eigs_eval_string("saved_len is len\nsaved_add is host_add\nsaved_str is str\nlen is 5\nhost_add is 0\n0");
    if (r) eigs_value_release(r);
    EigsValue *one = eigs_value_new_num(1.0);
    eigs_set_global("str", one);
    EigsValue *nine = eigs_value_new_num(9.0);
    eigs_set_global("iso_g", nine);
    eigs_value_release(one);
    eigs_value_release(nine);
    r = eigs_eval_string("import isomod\nisomod.m_len of ([1, 2, 3])");
    CHECK(r != NULL && eigs_value_as_num(r) == 3.0,
          "#1388 module len is the builtin after host `len is 5`");
    if (r) eigs_value_release(r);
    r = eigs_eval_string("import isomod\nisomod.m_add of null");
    CHECK(r != NULL && eigs_value_as_num(r) == 7.0,
          "#1388 registered function visible in module, immune to host rebinding");
    if (r) eigs_value_release(r);
    r = eigs_eval_string("import isomod\nisomod.m_str of null");
    CHECK(r != NULL && eigs_value_type(r) == EIGS_TYPE_STR &&
          strcmp(eigs_value_as_string(r), "5") == 0,
          "#1388 eigs_set_global of a builtin name does not reach module code");
    if (r) eigs_value_release(r);
    r = eigs_eval_string("import isomod\nisomod.m_glob of null");
    CHECK(r != NULL && eigs_value_as_num(r) == 9.0,
          "#1388 non-builtin eigs_set_global value readable from module code");
    if (r) eigs_value_release(r);
    r = eigs_eval_string("len");
    CHECK(r != NULL && eigs_value_as_num(r) == 5.0, "#1388 host keeps its own len");
    if (r) eigs_value_release(r);
    /* A second, independent state's `len` is untouched. */
    CHECK(eigs_thread_switch(st2) != NULL, "#1388 switch to st2");
    /* st2 imported smokemod above. Closing that non-last state below must
     * reclaim the module/function cycle without disturbing this builtin. */
    r = eigs_eval_string("len of [1, 2]");
    CHECK(r != NULL && eigs_value_as_num(r) == 2.0,
          "#1388 st2's len untouched by st1's `len is 5`");
    if (r) eigs_value_release(r);
    CHECK(eigs_thread_switch(st) != NULL, "#1388 switch back to st1");
    r = eigs_eval_string("len is saved_len\nhost_add is saved_add\nstr is saved_str\n0");
    if (r) eigs_value_release(r);
    eigs_set_source_provider(NULL, NULL);

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

    /* #739: `exit of N` must not permanently disable try/catch for the state.
     * The exit request is deliberately uncatchable, but it was a process global
     * that nothing ever reset — so after ANY script called exit, every later
     * eval in the process ran with exception handling silently off: a raise
     * inside `try` went to vm_error_halt instead of the catch handler. This is
     * the shape a long-lived host running untrusted snippets hits, and it is
     * only reachable through the embed API (on the CLI, exit ends the process).
     * The first CHECK is the control: catching must work BEFORE the exit. */
    const char *catcher = "try:\n    throw of \"boom\"\ncatch e:\n    \"CAUGHT\"";
    r = eigs_eval_string(catcher);
    CHECK(r != NULL && eigs_value_as_string(r) &&
          strcmp(eigs_value_as_string(r), "CAUGHT") == 0,
          "try/catch works before any exit (control)");
    if (r) eigs_value_release(r);

    r = eigs_eval_string("exit of 0");
    if (r) eigs_value_release(r);
    eigs_clear_error();

    /* The state-wide worker latch is evaluation-scoped too. A stale latch
     * used to be imported by the next eval's first loop back-edge even though
     * eval_source had cleared the thread-local exit flag. */
    r = eigs_eval_string("i is 0\nloop while i < 2:\n    i is i + 1\ni");
    CHECK(r != NULL && eigs_value_as_num(r) == 2.0,
          "loops still run after a script called exit (#1149)");
    if (r) eigs_value_release(r);

    r = eigs_eval_string(catcher);
    CHECK(r != NULL && eigs_value_as_string(r) &&
          strcmp(eigs_value_as_string(r), "CAUGHT") == 0,
          "try/catch still works after a script called exit (#739)");
    if (r) eigs_value_release(r);

    /* --- #797: the lint allow-list parses FRESH. ----------------------
     * eigs_json_lint_allow_for was the seventh lenient parse root missed
     * by #777's sweep: it read g_json_parse_err left set by an UNRELATED
     * earlier parse in the same thread, decoded the well-formed allow-list
     * to an empty dict, and warning suppression silently stopped applying.
     * Unreachable from the CLI (one file, one process, no prior parse) —
     * this embedder shape is the only consumer that can hit it. */
    {
        char dir797[] = "/tmp/eigs797_XXXXXX";
        CHECK(mkdtemp(dir797) != NULL, "#797: mkdtemp");
        char pj[512], pe[512];
        snprintf(pj, sizeof pj, "%s/eigs.json", dir797);
        snprintf(pe, sizeof pe, "%s/t.eigs", dir797);
        FILE *f = fopen(pj, "w");
        fputs("{\"lint\": {\"allow\": {\"t.eigs\": [\"W001\"]}}}\n", f);
        fclose(f);
        f = fopen(pe, "w");
        fputs("unusedtop797 is 1\nprint of \"hi\"\n", f);
        fclose(f);

        CHECK(eigenscript_lint(pe, 0, 1) == 0,
              "#797: allow-list suppresses W001 before any other parse");

        int jpos797 = 0;
        Value *bad797 = eigs_json_parse_value("{nope", &jpos797);
        /* The lenient parser repairs what it can and may return a partial
         * value — the poison is the thread-local error flag it leaves set
         * (static in builtins.c, so not assertable here; that it IS set is
         * what makes the next CHECK fail without the lint.c fix). */
        if (bad797) val_decref(bad797);

        CHECK(eigenscript_lint(pe, 0, 1) == 0,
              "#797: allow-list still suppresses after an unrelated failed parse");

        remove(pj); remove(pe); rmdir(dir797);
    }

    /* Leave a recv-blocked, never-joined worker for eigs_close to reap — this
     * hangs (or leaks/UAFs) unless eigs_close drains (close+wake+join, #303). */
    r = eigs_eval_string(
        "ch2 is channel of 1\n"
        "w is spawn of [recv, ch2]\n"
        "1");
    CHECK(r != NULL, "embed leaves a recv-blocked worker for eigs_close to reap");
    eigs_value_release(r);

    eigs_close(st);
    test_worker_exit_lifecycle();

    if (failures == 0) {
        printf("embed_smoke: OK\n");
        return 0;
    }
    fprintf(stderr, "embed_smoke: %d failure(s)\n", failures);
    return 1;
}
