/* #1665 follow-up: planted stale reads of the two kept recycling pools.
 *
 *   test_pool_poison num      read a NUM parked on the per-thread freelist
 *   test_pool_poison int      read an INT parked on the per-thread freelist
 *   test_pool_poison env      read values[0] of a call env parked on its chunk
 *   test_pool_poison envfield read a field (count) of that parked Env struct
 *   test_pool_poison leaf     a frameless leaf accessor allocates no call env
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

static const char *LEAF_PROGRAM =
    "define pool_poison_leaf(a) as:\n"
    "    return a\n"
    "pool_poison_leaf_r is pool_poison_leaf of [41]\n";

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
    Value *v = make_float(42.5);
    val_decref(v);                       /* refcount 0 -> parked on the freelist */
    if (g_num_freelist != v) { puts("NOT-ARMED num: value not parked"); return 3; }
    printf("ARMED num: parked NUM %p, reading %p\n", (void *)v,
           (void *)&VAL_F64_RAW(v));
    fflush(stdout);
    volatile double stale = VAL_F64_RAW(v);   /* the planted stale read */
    printf("UNDETECTED num: read %g from a parked NUM\n", stale);
    return 0;
}

static int plant_int(void) {
    Value *v = make_int(INT64_C(1) << 60);
    val_decref(v);
    if (g_int_freelist != v) { puts("NOT-ARMED int: value not parked"); return 3; }
    printf("ARMED int: parked INT %p, reading %p\n", (void *)v,
           (void *)&VAL_I64_RAW(v));
    fflush(stdout);
    volatile int64_t stale = VAL_I64_RAW(v);
    printf("UNDETECTED int: read %lld from a parked INT\n", (long long)stale);
    return 0;
}

static int int_reuse_is_fresh(void) {
    Value *a = make_int((INT64_C(1) << 60) + 1);
    Value *b = make_int((INT64_C(1) << 60) + 2);
    val_decref(a);
    val_decref(b);
    if (g_int_freelist_count < 2) { puts("FAIL: fresh comparison parked fewer than two integer boxes"); return 1; }
    Value *reused = make_int(INT64_C(1) << 60);
    eigs_thread_drain_caches(eigs_current);
    Value *fresh = make_int(INT64_C(1) << 60);
    int same = memcmp(reused, fresh, sizeof(Value)) == 0;
    val_decref(reused);
    val_decref(fresh);
    if (!same) { puts("FAIL: reused integer box differs byte-for-byte from fresh box"); return 1; }
    puts("PASS: reused integer box equals fresh box byte-for-byte");
    return 0;
}

static int fill_int_pool(size_t n) {
    Value **held = calloc(n, sizeof(*held));
    if (!held) return 0;
    for (size_t i = 0; i < n; i++) held[i] = make_int(INT64_C(1) << 60);
    for (size_t i = 0; i < n; i++) val_decref(held[i]);
    free(held);
    return 1;
}

#ifndef EIGS_POOL_OFF_NUM
static int int_pool_types_are_int(void) {
#if defined(EIGS_ASAN_POOL_POISON)
    return 1; /* Parked type words are deliberately poisoned in this build. */
#else
    int seen = 0;
    for (Value *v = g_int_freelist; v; ) {
        Value *next;
        if (v->type != VAL_INT) return 0;
        memcpy(&next, EIGS_NUM_LINK(v), sizeof(next));
        v = next;
        seen++;
    }
    return seen == g_int_freelist_count;
#endif
}

static int float_pool_types_are_float(void) {
#if defined(EIGS_ASAN_POOL_POISON)
    return 1;
#else
    int seen = 0;
    for (Value *v = g_num_freelist; v; ) {
        Value *next;
        if (v->type != VAL_FLOAT) return 0;
        memcpy(&next, EIGS_NUM_LINK(v), sizeof(next));
        v = next;
        seen++;
    }
    return seen == g_num_freelist_count;
#endif
}
#endif

static int bounded_int_pool(void) {
#ifdef EIGS_POOL_OFF_NUM
    if (!fill_int_pool(3 * INT_FREELIST_CAP) || g_int_freelist_count != 0) {
        puts("FAIL: pool-off-num integer count changed"); return 1;
    }
    puts("PASS: pool-off-num integer count stays 0 through burst");
    return 0;
#else
    const int takes[] = {1, 100, INT_FREELIST_CAP};
    if (INT_FREELIST_CAP != NUM_FREELIST_CAP) { puts("FAIL: pool caps differ"); return 1; }
    for (size_t t = 0; t < sizeof(takes) / sizeof(takes[0]); t++) {
        if (!fill_int_pool(3 * INT_FREELIST_CAP) ||
            g_int_freelist_count != INT_FREELIST_CAP) {
            printf("FAIL: int burst count=%d cap=%d\n", g_int_freelist_count, INT_FREELIST_CAP); return 1;
        }
        Value **held = calloc((size_t)takes[t] + 1, sizeof(*held));
        if (!held) return 2;
        for (int i = 0; i < takes[t]; i++) held[i] = make_int(INT64_C(1) << 60);
        if (g_int_freelist_count != INT_FREELIST_CAP - takes[t]) {
            printf("FAIL: after K=%d count=%d expected=%d\n", takes[t], g_int_freelist_count, INT_FREELIST_CAP - takes[t]); free(held); return 1;
        }
        held[takes[t]] = make_int(INT64_C(1) << 60);
        if (takes[t] == INT_FREELIST_CAP && g_int_freelist_count != 0) {
            puts("FAIL: allocation after empty pool changed count"); free(held); return 1;
        }
        printf("PASS: integer pool burst=%d K=%d count=%d\n", 3 * INT_FREELIST_CAP, takes[t], INT_FREELIST_CAP - takes[t]);
        for (int i = 0; i <= takes[t]; i++) val_decref(held[i]);
        free(held);
        eigs_thread_drain_caches(eigs_current);
    }
    return 0;
#endif
}

static int disjoint_number_pools(void) {
#ifdef EIGS_POOL_OFF_NUM
    puts("SKIP: number pools disabled"); return 0;
#else
    Value *f = make_float(1.5); val_decref(f);
    int fc = g_num_freelist_count;
    Value *i = make_int(INT64_C(1) << 60);
    if (g_num_freelist_count != fc) { puts("FAIL: make_int took float box"); return 1; }
    val_decref(i); eigs_thread_drain_caches(eigs_current);
    i = make_int(INT64_C(1) << 60); val_decref(i);
    int ic = g_int_freelist_count;
    f = make_float(2.5);
    if (g_int_freelist_count != ic) { puts("FAIL: make_float took integer box"); return 1; }
    val_decref(f); eigs_thread_drain_caches(eigs_current);
    Value **held = calloc(NUM_FREELIST_CAP + 1, sizeof(*held));
    if (!held) return 2;
    for (int n = 0; n <= NUM_FREELIST_CAP; n++) held[n] = make_float(n + .5);
    for (int n = 0; n <= NUM_FREELIST_CAP; n++) val_decref(held[n]);
    if (g_num_freelist_count != NUM_FREELIST_CAP || g_int_freelist_count != 0 ||
        !float_pool_types_are_float() || !int_pool_types_are_int()) { puts("FAIL: full float pool changed integer pool"); free(held); return 1; }
    eigs_thread_drain_caches(eigs_current);
    for (int n = 0; n <= INT_FREELIST_CAP; n++) held[n] = make_int((INT64_C(1) << 60) + n);
    for (int n = 0; n <= INT_FREELIST_CAP; n++) val_decref(held[n]);
    free(held);
    if (g_int_freelist_count != INT_FREELIST_CAP || g_num_freelist_count != 0 ||
        !int_pool_types_are_int() || !float_pool_types_are_float()) { puts("FAIL: full integer pool changed float pool"); return 1; }
    puts("PASS: integer and float pools remain disjoint in both directions and at both caps");
    return 0;
#endif
}

static int drain_int_pool(void) {
    if (!fill_int_pool(8) || g_int_freelist_count == 0) { puts("FAIL: integer pool did not fill before drain"); return 1; }
    eigs_thread_drain_caches(eigs_current);
    if (g_int_freelist || g_int_freelist_count) { puts("FAIL: drain left integer boxes parked"); return 1; }
    puts("PASS: drain empties integer pool and resets its count");
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

/* #1703: an exactly-fed one-expression accessor takes the frameless CALL
 * path. Pin both halves of that mechanism: the compiler classified the chunk
 * as a leaf accessor, and repeated successful calls left no call env to park. */
static int leaf_control(void) {
    Value *r = eigs_eval_string(LEAF_PROGRAM);
    if (!r) { puts("FAIL leaf: initial eval failed"); return 1; }
    eigs_value_release(r);
    Value *fn = eigs_get_global("pool_poison_leaf");
    EigsChunk *c = (fn && fn->type == VAL_FN && fn->data.fn.body_count == -1)
                 ? (EigsChunk *)fn->data.fn.body : NULL;
    int classified = c && c->leaf_accessor;
    int no_env = c && !c->env_cache;
    if (fn) eigs_value_release(fn);
    r = eigs_eval_string("pool_poison_leaf_r is pool_poison_leaf of [7]\n");
    if (r) eigs_value_release(r);
    Value *res = eigs_get_global("pool_poison_leaf_r");
    int result_ok = res && res->type == VAL_INT && VAL_I64_RAW(res) == 7;
    if (res) eigs_value_release(res);
    no_env = no_env && c && !c->env_cache;
    if (classified && no_env && result_ok) {
        puts("PASS: leaf accessor is frameless and has no call env to park");
        return 0;
    }
    printf("FAIL leaf: classified=%d no_call_env=%d result_ok=%d\n",
           classified, no_env, result_ok);
    return 1;
}

static int control(void) {
    int bad = 0;
    /* NUM pop: make_float hands the parked Value back, readable again. */
    Value *v = make_float(1.5);
    val_decref(v);
    Value *again = make_float(2.5);
    if (again != v) { puts("NOT-ARMED control: freelist did not reuse"); return 3; }
    if (VAL_F64_RAW(again) != 2.5 || again->refcount != 1) bad = 1;
    printf("control num reuse: %s\n", bad ? "WRONG" : "ok");
    val_decref(again);

    /* INT pop: make_int hands its own parked Value back, readable again. */
    v = make_int(INT64_C(1) << 60);
    val_decref(v);
    again = make_int((INT64_C(1) << 60) + 1);
    if (again != v) { puts("NOT-ARMED control: integer freelist did not reuse"); return 3; }
    if (VAL_I64_RAW(again) != (INT64_C(1) << 60) + 1 || again->refcount != 1) bad = 1;
    printf("control int reuse: %s\n", bad ? "WRONG" : "ok");
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
    /* #1758 N1/N3: this natural integer program returns the exact int 8. */
    int ok = res && res->type == VAL_INT && VAL_I64_RAW(res) == 8;
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
    else if (!strcmp(mode, "int")) rc = plant_int();
    else if (!strcmp(mode, "int-fresh")) rc = int_reuse_is_fresh();
    else if (!strcmp(mode, "int-bounds")) rc = bounded_int_pool();
    else if (!strcmp(mode, "number-kinds")) rc = disjoint_number_pools();
    else if (!strcmp(mode, "int-drain")) rc = drain_int_pool();
    else if (!strcmp(mode, "env")) rc = plant_env();
    else if (!strcmp(mode, "envfield")) rc = plant_envfield();
    else if (!strcmp(mode, "leaf")) rc = leaf_control();
    else if (!strcmp(mode, "control")) rc = control();
    else { fprintf(stderr, "usage: %s num|int|int-fresh|int-bounds|number-kinds|int-drain|env|envfield|leaf|control\n", argv[0]); rc = 2; }
    eigs_close(st);
    return rc;
}
