/* Report-owned, SOURCE-ONLY structural ownership oracle.
 * Every table observed here has an explicit test reference until final checks.
 * No bytecode is executed and no uncertain-lifetime spelling is dereferenced.
 */
#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "eigs_embed.h"
#include <stdio.h>
#include <stddef.h>

/* Internal registry shape mirrored solely to inspect live owner membership.
 * This does not copy the production lookup/mutation helper. */
struct EnvInternValueOwner {
    Value *value;
    EnvNameIntern *names;
    struct EnvInternValueOwner *next;
};
static int passed, failed, examined;
#define CHECK(label, condition) do { \
    ++examined; \
    if (condition) { ++passed; printf("PASS: %s\n", label); } \
    else { ++failed; printf("FAIL: %s\n", label); } \
} while (0)
static int refs(EnvInternTable *table) {
    return __atomic_load_n(&table->refcount, __ATOMIC_ACQUIRE);
}
static int owns(EnvInternRef *owners, EnvInternTable *table) {
    int n = 0;
    for (; owners; owners = owners->next) if (owners->table == table) ++n;
    return n;
}
static size_t private_names(EigsState *state, Value *value) {
    size_t n = 0;
    pthread_mutex_lock(&state->intern_owner_lock);
    for (EnvInternValueOwner *owner = state->sandbox_intern_owners;
         owner; owner = owner->next) {
        if (owner->value != value) continue;
        for (EnvNameIntern *name = owner->names; name; name = name->owner_next)
            ++n; /* Never inspect name->name. */
    }
    pthread_mutex_unlock(&state->intern_owner_lock);
    return n;
}
int main(void) {
    EigsState *a = eigs_open();
    if (!a) { fputs("SETUP FAIL: state A\n", stderr); return 2; }
    EnvInternTable *old = eigs_current->intern_tbl;
    env_intern_table_ref(old); /* test owner, retained through normal close */
    env_set_local_owned(a->global_env, "owner_fixture_root", make_num_permanent(3));
    CHECK("state root retains originating table", owns(a->global_env->intern_refs, old) == 1);
    CHECK("builtin layer retains originating table", owns(a->builtin_env->intern_refs, old) == 1);
    int before = refs(old);
    env_set_local_owned(a->global_env, "owner_fixture_second", make_num_permanent(4));
    CHECK("same Env deduplicates table owner", refs(old) == before);

    char *old_name = env_intern_name("owner_fixture_old_chunk");
    EigsChunk *old_chunk = chunk_new("owner-fixture-old");
    CHECK("chunk owns its originating table", old_chunk->intern_tbl == old && refs(old) == before + 1);
    char *params[] = {"owner_fixture_param"};
    Value *fn = make_fn("owner_fixture_fn", params, 1, a->global_env);
    CHECK("function params acquire separate owner", fn->data.fn.param_intern_tbl == old && refs(old) == before + 2);
    Value *ordinary = make_dict(1);
    dict_set_owned(ordinary, "owner_fixture_dict", make_num_permanent(5));
    CHECK("ordinary dict retains its exact table", owns(ordinary->data.dict.intern_refs, old) == 1 && refs(old) == before + 3);

    (void)env_intern_name("owner_fixture_scope_zero");
    uint32_t previous = g_sandbox_intern_scope;
    uint32_t scope = env_intern_scope_begin();
    Value *zero = make_dict(1), *private = make_dict(1);
    dict_set_owned(zero, "owner_fixture_scope_zero", make_num_permanent(6));
    dict_set_owned(private, "owner_fixture_private_key", make_num_permanent(7));
    CHECK("scope-zero reuse has exact table owner", owns(zero->data.dict.intern_refs, old) == 1);
    CHECK("promoted private key has live Value owner", private_names(a, private) == 1);
    CHECK("private copy does not retain whole table", private->data.dict.intern_refs == NULL);
    env_intern_scope_end(scope, previous);
    CHECK("private owner survives scope end", private_names(a, private) == 1);

    eigs_thread_detach(); /* test refs protect ordinary names even on assertion failure */
    CHECK("state Env owner survives creator detach", owns(a->global_env->intern_refs, old) == 1);
    CHECK("private owner remains state-local after detach", private_names(a, private) == 1);
    if (!eigs_thread_attach(a)) { fputs("SETUP FAIL: reattach A\n", stderr); return 2; }
    EnvInternTable *fresh = eigs_current->intern_tbl;
    env_intern_table_ref(fresh);
    CHECK("reattach creates distinct table", fresh != old);
    Env *binding = env_new(NULL);
    before = refs(old);
    env_set_local_pre_interned_slot(binding, old_name, old_chunk->intern_tbl,
                                   env_hash_name(old_name), slot_null());
    CHECK("new attachment binding owns old chunk origin", owns(binding->intern_refs, old) == 1 && refs(old) == before + 1);
    CHECK("binding preserves original intern pointer", binding->names[0] == old_name);
    env_clear(binding);
    CHECK("clear preserves owner until Env teardown", owns(binding->intern_refs, old) == 1);
    env_decref(binding);
    CHECK("empty freelist transition releases owner", refs(old) == before);

    EigsChunk *body = chunk_new("owner-fixture-body");
    /* Exactly the existing OP_CLOSURE body/ref contract; never executed. */
    fn->data.fn.body = (ASTNode **)body;
    fn->data.fn.body_count = -1;
    chunk_incref(body);
    chunk_free(body); /* fn keeps the body ref */
    CHECK("body and parameter tables are distinct", body->intern_tbl == fresh && fn->data.fn.param_intern_tbl == old);
    Env *call = env_new(NULL);
    before = refs(old);
    env_bind_fresh_param_slot(call, fn->data.fn.params[0], fn->data.fn.param_intern_tbl,
                             fn->data.fn.param_hashes[0], slot_null());
    CHECK("parameter Env owns parameter origin", owns(call->intern_refs, old) == 1 && refs(old) == before + 1);
    body->env_cache = call;
    env_incref(call); /* actual chunk cache owns one ref */
    env_decref(call); /* drop creator; leave cache's owner */
    CHECK("per-chunk cache retains names and owner", body->env_cache == call && call->count == 1 && owns(call->intern_refs, old) == 1);
    val_decref(fn); /* drops body, whose destructor releases cached Env */
    CHECK("function and cached Env release separately", refs(old) == before - 1 && refs(fresh) == 2);
    before = refs(old);
    val_decref(ordinary);
    CHECK("temporary dict releases table owner", refs(old) == before - 1);
    before = refs(old);
    val_decref(zero);
    CHECK("scope-zero dictionary releases table owner", refs(old) == before - 1);
    /* No private key bytes are used after detach; only live registry membership. */
    CHECK("other attachment finds private owner", private_names(a, private) == 1);
    val_decref(private);
    CHECK("private owner removed on Value destruction", a->sandbox_intern_owners == NULL);
    chunk_free(old_chunk);

    eigs_thread_detach();
    EigsState *b = eigs_open();
    if (!b) { fputs("SETUP FAIL: state B\n", stderr); return 2; }
    EnvInternTable *other = eigs_current->intern_tbl;
    env_intern_table_ref(other);
    env_set_local_owned(b->global_env, "owner_fixture_other_state", make_num_permanent(8));
    CHECK("state B owns its own table", owns(b->global_env->intern_refs, other) == 1);
    CHECK("state B does not own state A table", owns(b->global_env->intern_refs, old) == 0);
    CHECK("state A does not own state B table", owns(a->global_env->intern_refs, other) == 0);
    eigs_thread_detach();
    if (!eigs_thread_attach(a)) { fputs("SETUP FAIL: close A attach\n", stderr); return 2; }
    /* This final empty attachment has no persistent names; no test reads it. */
    eigs_close(a);
    CHECK("state A old table has only test ref after close", refs(old) == 1);
    CHECK("state A reattachment table has only test ref", refs(fresh) == 1);
    CHECK("closing A preserves B owners", refs(other) > 1 && owns(b->global_env->intern_refs, other) == 1);
    if (!eigs_thread_attach(b)) { fputs("SETUP FAIL: close B attach\n", stderr); return 2; }
    eigs_close(b);
    CHECK("state B table has only test ref after close", refs(other) == 1);
    env_intern_table_unref(old);
    env_intern_table_unref(fresh);
    env_intern_table_unref(other); /* release test refs LAST; never read afterward */
    printf("intern owner structural: %d passed, %d failed (%d declared)\n", passed, failed, 32);
    if (examined != 32) { fprintf(stderr, "FAIL: examined %d expected 32\n", examined); return 1; }
    printf("layout: Value=%zu Env=%zu fn-param-owner=%zu dict-owner=%zu private-flag=%zu\n",
           sizeof(Value), sizeof(Env), offsetof(Value, data.fn.param_intern_tbl),
           offsetof(Value, data.dict.intern_refs), offsetof(Value, intern_private));
    return failed ? 1 : 0;
}
