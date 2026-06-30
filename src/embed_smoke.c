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

#include "eigs_embed.h"

static int failures = 0;

#define CHECK(cond, msg) do {                                              \
    if (!(cond)) {                                                         \
        fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (msg));    \
        failures++;                                                        \
    }                                                                      \
} while (0)

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

    /* --- #301: spawn + channel through the embed path. eigs_close() must
     * drain the handle table (reap workers, free channels, clear multithreaded)
     * just like main.c — otherwise embedders leak channels/threads, the exit
     * collector silently no-ops, and a live worker can UAF the freed state. */
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
