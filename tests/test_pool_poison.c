/* #1665 follow-up: planted stale reads of the two kept recycling pools.
 *
 *   test_pool_poison num      read a NUM parked on the per-thread freelist
 *   test_pool_poison env      read values[0] of a call env parked on its chunk
 *   test_pool_poison envfield read a field (count) of that parked Env struct
 *   test_pool_poison control  the pools' own reuse paths (pop, take, a cycle
 *                             collection over a parked env) -- must stay clean
 *
 * A fault mode prints "ARMED <mode>: ... reading <address>" just before its
 * stale read and "UNDETECTED <mode>" after it. On an ASan build with pool poisoning the read
 * is reported as use-after-poison and the process dies between the two lines;
 * on a build without it (release, or an ASan build that predates the
 * poisoning) the read is an ordinary in-bounds load of still-allocated memory
 * and the process prints UNDETECTED and exits 0. Exit 3 = the plant could not
 * be armed (no parked object to read), never a verdict. */
#include <stdio.h>
#include <string.h>

#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"

static const char *PROGRAM =
    "define pool_poison_fn(a) as:\n"
    "    b is a + 1\n"
    "    return b\n"
    "pool_poison_r is pool_poison_fn of [41]\n";

/* The function's chunk, whose env_cache holds the env parked on return. */
static EigsChunk *fn_chunk(void) {
    Value *fn = eigs_get_global("pool_poison_fn");
    if (!fn || fn->type != VAL_FN || fn->data.fn.body_count != -1) {
        if (fn) eigs_value_release(fn);
        return NULL;
    }
    EigsChunk *c = (EigsChunk *)fn->data.fn.body;
    eigs_value_release(fn);   /* the global binding keeps it alive */
    return c;
}

static int run_program(void) {
    Value *r = eigs_eval_string(PROGRAM);
    if (!r) {
        fprintf(stderr, "SETUP FAIL: eval: %s\n",
                eigs_last_error_message() ? eigs_last_error_message() : "?");
        return 0;
    }
    eigs_value_release(r);
    return 1;
}

static int plant_num(void) {
    Value *v = make_num(42.5);
    val_decref(v);                       /* refcount 0 -> parked on the freelist */
    if (g_num_freelist != v) { puts("NOT-ARMED num: value not parked"); return 3; }
    printf("ARMED num: parked NUM %p, reading %p\n", (void *)v,
           (void *)&VAL_NUM_RAW(v));
    fflush(stdout);
    volatile double stale = VAL_NUM_RAW(v);   /* the planted stale read */
    printf("UNDETECTED num: read %g from a parked NUM\n", stale);
    return 0;
}

/* The values[] base of a parked env, read WITHOUT instrumentation: the Env
 * struct is poisoned too, so an instrumented `parked->values` would report at
 * the struct field before the planted array read could run. */
#if defined(__SANITIZE_ADDRESS__) || defined(__clang__)
__attribute__((no_sanitize_address))
#endif
static EigsSlot *values_base_unchecked(Env *e) {
    return *(EigsSlot *volatile *)&e->values;
}

static Env *parked_env(const char *mode) {
    if (!run_program()) return NULL;
    EigsChunk *c = fn_chunk();
    Env *parked = c ? c->env_cache : NULL;
    if (!parked) printf("NOT-ARMED %s: no parked call env\n", mode);
    return parked;
}

/* env: the parked env's values[0] (its slot array). */
static int plant_env(void) {
    Env *parked = parked_env("env");
    if (!parked) return 3;
    EigsSlot *vals = values_base_unchecked(parked);
    printf("ARMED env: parked call env %p, reading %p\n", (void *)parked,
           (void *)&vals[0]);
    fflush(stdout);
    volatile uint64_t stale = vals[0].u;             /* the planted stale read */
    printf("UNDETECTED env: read %#llx from a parked env's values[0]\n",
           (unsigned long long)stale);
    return 0;
}

/* envfield: a field of the parked Env struct itself (count). */
static int plant_envfield(void) {
    Env *parked = parked_env("envfield");
    if (!parked) return 3;
    printf("ARMED envfield: parked call env %p, reading %p\n", (void *)parked,
           (void *)&parked->count);
    fflush(stdout);
    volatile int stale = parked->count;              /* the planted stale read */
    printf("UNDETECTED envfield: read count %d from a parked env\n", stale);
    return 0;
}

static int control(void) {
    int bad = 0;
    /* NUM pop: make_num hands the parked Value back, readable again. */
    Value *v = make_num(1.5);
    val_decref(v);
    Value *again = make_num(2.5);
    if (again != v) { puts("NOT-ARMED control: freelist did not reuse"); return 3; }
    if (VAL_NUM_RAW(again) != 2.5 || again->refcount != 1) bad = 1;
    printf("control num reuse: %s\n", bad ? "WRONG" : "ok");
    val_decref(again);

    /* Env take: the second call takes the parked env (same struct). */
    if (!run_program()) return 3;
    EigsChunk *c = fn_chunk();
    Env *first = c ? c->env_cache : NULL;
    if (!first) { puts("NOT-ARMED control: no parked call env"); return 3; }
    /* A cycle collection walks chunk -> env_cache; it must lift and then
     * restore the poison without reporting. A captured env binding the
     * function puts fn -> chunk -> parked env in the collector's universe. */
    Value *r = eigs_eval_string(
        "define pool_poison_mk() as:\n"
        "    f is pool_poison_fn\n"
        "    return () => f\n"
        "pool_poison_c is pool_poison_mk of []\n");
    if (r) eigs_value_release(r);
    gc_collect_cycles();
#if defined(EIGS_ASAN_POOL_POISON)
    /* The collector lifts the park poison to walk the env; it must restore
     * it for a chunk that survives. */
    if (!__asan_address_is_poisoned(&first->count)) {
        puts("control gc: parked env left UNPOISONED after a collection");
        bad = 1;
    }
#endif
    r = eigs_eval_string("pool_poison_r is pool_poison_fn of [7]\n");
    if (!r) { puts("control take: eval failed"); return 1; }
    eigs_value_release(r);
    Value *res = eigs_get_global("pool_poison_r");
    int ok = res && res->type == VAL_NUM && VAL_NUM_RAW(res) == 8.0;
    if (res) eigs_value_release(res);
    int same = c->env_cache == first;
    printf("control env take: %s (re-parked same env: %s)\n",
           ok ? "ok" : "WRONG", same ? "yes" : "no");
    if (!ok || !same) bad = 1;
    /* chunk_free drops a parked env: rebinding the only owner of a function
     * frees its chunk (the defining eval's module chunk is already gone)
     * while its call env is parked. */
    r = eigs_eval_string("define pool_poison_drop(a) as:\n"
                         "    b is a + 1\n"
                         "    return b\n"
                         "pool_poison_d is pool_poison_drop of [3]\n");
    if (r) eigs_value_release(r);
    Value *dfn = eigs_get_global("pool_poison_drop");
    EigsChunk *dc = (dfn && dfn->type == VAL_FN && dfn->data.fn.body_count == -1)
                  ? (EigsChunk *)dfn->data.fn.body : NULL;
    int drop_armed = dc && dc->env_cache && dc->refcount == 1;
    if (dfn) eigs_value_release(dfn);
    if (!drop_armed) { printf("NOT-ARMED control: drop chunk %p env_cache %p refcount %d\n", (void *)dc, dc ? (void *)dc->env_cache : NULL, dc ? dc->refcount : -1); return 3; }
    r = eigs_eval_string("pool_poison_drop is null\n");
    if (r) eigs_value_release(r);
    puts("control chunk_free of a parked env: ok");
    printf("control: %s\n", bad ? "FAIL" : "all clean");
    return bad;
}

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "";
    EigsState *st = eigs_open();
    if (!st) { fputs("SETUP FAIL: eigs_open\n", stderr); return 2; }
    int rc;
    if (!strcmp(mode, "num")) rc = plant_num();
    else if (!strcmp(mode, "env")) rc = plant_env();
    else if (!strcmp(mode, "envfield")) rc = plant_envfield();
    else if (!strcmp(mode, "control")) rc = control();
    else { fprintf(stderr, "usage: %s num|env|envfield|control\n", argv[0]); rc = 2; }
    eigs_close(st);
    return rc;
}
