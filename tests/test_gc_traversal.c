/* The runner instruments a temporary copy of the real collector. No test
 * counters, callbacks, or alternate GC implementation enter release builds. */
#include <stdio.h>
#include <stdlib.h>
static void traversal_discovered(void *universe);
static void traversal_collected(int nodes, int garbage);
static unsigned traversal_skips;
#include "gc_traversal_runtime.c"
#include "eigs_embed.h"

static int failures, checks, cases, active, want_nodes, want_garbage, collections;
static int want_kinds[3], saw_growth, total_collections;
static Env *namespace_env;
static Value *duplicate_child;
#define CHECK(c,label) do { ++checks; if (!(c)) { \
    fprintf(stderr,"gc-traversal: FAIL %s\n",label); ++failures; } } while (0)

static void traversal_discovered(void *universe) {
    if (!active) return;
    GcU *u=universe;
    int kinds[3]={0,0,0};
    for (int n=0;n<u->count;++n) ++kinds[u->kind[n]];
    CHECK(u->count==want_nodes,"discovered population");
    for (int k=0;k<3;++k) CHECK(kinds[k]==want_kinds[k],"node-kind population");
    if (want_nodes>256) {
        CHECK(u->cap>=want_nodes && u->mask>511,"array growth and rehash reached");
        saw_growth=1;
        for (int n=0;n<u->count;++n) {
            CHECK(u->internal[n]==1,"ring internal ownership survived growth");
            CHECK(u->has_node_children[n]==1,"ring child metadata survived growth");
        }
    }
    if (namespace_env) {
        int n=gcu_find(u,namespace_env);
        CHECK(n>=0,"module environment discovered");
        CHECK(n>=0 && u->internal[n]==3,"module incoming edges counted separately");
    }
    if (duplicate_child) {
        int n=gcu_find(u,duplicate_child);
        CHECK(n>=0,"duplicate child discovered");
        if (n>=0) {
            CHECK(u->internal[n]==2,"duplicate edges counted separately");
            CHECK(u->has_node_children[n]==0,"numeric list has no node children");
        }
    }
}
static void traversal_collected(int nodes,int garbage) {
    if (!active) return;
    ++collections;
    ++total_collections;
    CHECK(nodes==want_nodes,"completed population");
    CHECK(garbage==want_garbage,"reclaimed population");
}
static void collect(int nodes,int garbage,int values,int envs,int chunks) {
    want_nodes=nodes; want_garbage=garbage;
    want_kinds[0]=values; want_kinds[1]=envs; want_kinds[2]=chunks;
    collections=0; active=1;
    gc_collect_cycles();
    active=0;
    CHECK(collections==1,"one completed collection without accounting abort");
}

static void duplicate_and_leaf(void) {
    Value *leaf=make_list_heap(64), *root=make_list_heap(2);
    for (int i=0;i<64;++i) list_append_owned(leaf,make_num(i));
    list_append(root,leaf); list_append(root,leaf);
    duplicate_child=leaf;
    val_decref(leaf); gc_note_possible_root(root);
    Value *a=make_list_heap(2), *b=make_list_heap(1);
    list_append(a,b); list_append(a,b); list_append(b,a);
    val_decref(a); val_decref(b);
    unsigned before=traversal_skips;
    collect(4,2,4,0,0);
    CHECK(traversal_skips>before,"numeric-leaf mark traversal skipped");
    CHECK(root->data.list.items[0]==root->data.list.items[1],"live duplicate aliases retained");
    CHECK(root->data.list.items[0]->data.list.items[63]->data.num==63,"live leaf contents retained");
    duplicate_child=NULL;
    val_decref(root); gc_collect_cycles();
    ++cases;
}

static void growing_ring(void) {
    enum { N=600 };
    Value **ring=calloc(N,sizeof *ring);
    if (!ring) abort();
    for (int i=0;i<N;++i) ring[i]=make_list_heap(1);
    for (int i=0;i<N;++i) list_append(ring[i],ring[(i+1)%N]);
    /* Suppress candidate registration only while dropping setup refs. Seed
     * just ring[0], forcing the arrays to grow DURING edge discovery rather
     * than preloading all 600 nodes through the candidate-buffer seed pass. */
    int enabled=g_gc_enabled;
    g_gc_enabled=0;
    for (int i=1;i<N;++i) val_decref(ring[i]);
    g_gc_enabled=enabled;
    gc_note_possible_root(ring[0]);
    collect(N,0,N,0,0);
    CHECK(ring[0]->data.list.items[0]==ring[1],"live ring retained after growth");
    val_decref(ring[0]);
    collect(N,N,N,0,0);
    free(ring);
    CHECK(saw_growth,"growth case reached");
    ++cases;
}

static void module_env_chunk_cycle(void) {
    Env *module=env_new(g_global_env);
    Value *fn=make_fn("gc-traversal",NULL,0,module);
    env_mark_captured(module);
    EigsChunk *chunk=chunk_new("gc-traversal");
    /* Transfer creator refs exactly as the VM's owning chunk fields do. */
    chunk->functions[chunk->fn_count++]=chunk_new("nested");
    chunk->env_cache=env_new(module);
    fn->data.fn.body=(ASTNode **)chunk;
    fn->data.fn.body_count=-1;
    Value *exports=make_dict(1);
    dict_set(exports,"fn",fn);
    env_set_local(module,"exports",exports);
    env_set_local(module,"fn",fn);
    eigs_module_ns_attach(exports,module);
    namespace_env=module;
    eigs_module_cache_put("gc-traversal-test-module",exports,module);
    val_decref(fn); val_decref(exports); env_decref(module);
    collect(6,0,2,2,2);
    Value *cached=NULL;
    CHECK(eigs_module_cache_get("gc-traversal-test-module",&cached),"module cache remains a root");
    CHECK(cached==exports,"module exports identity retained");
    /* cache_get returns an owned ref; drop it before removing cache roots. */
    val_decref(cached);
    eigs_module_cache_clear();
    collect(6,6,2,2,2);
    namespace_env=NULL;
    ++cases;
}

static void run_case(const char *name,void (*body)(void)) {
    EigsState *state=eigs_open();
    if (!state) exit(2);
    CHECK(!g_arena.active,"heap mode");
    gc_collect_cycles();
    int first_check=checks, first_failure=failures, first_collection=total_collections;
    unsigned first_skip=traversal_skips;
    body();
    printf("gc-case: name=%s checks=%d collections=%d skips=%u failures=%d\n",
           name,checks-first_check,total_collections-first_collection,
           traversal_skips-first_skip,failures-first_failure);
    eigs_close(state);
}
int main(void) {
    run_case("duplicates",duplicate_and_leaf);
    run_case("growth",growing_ring);
    run_case("namespace",module_env_chunk_cycle);
    CHECK(cases==3,"all graph cases completed");
    printf("gc-traversal: cases=%d checks=%d failures=%d\n",cases,checks,failures);
    /* The deliberate ownership fault can make LSan exit before stdio's
     * normal flush. Preserve the complete assertion population first. */
    if (fflush(stdout)==EOF) return 2;
    return failures ? 1 : 0;
}
