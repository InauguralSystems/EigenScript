#include "jit.h"
#include "eigenscript.h"
#include "vm.h"

#ifdef EIGS_JIT_CHECKED
/* Shared by the runtime and the standalone positive-control plant, so CI
 * exercises the production diagnostic as well as the production emitter. */
static void jit_checked_fail(EigsChunk *chunk, uint32_t site,
                             const char *what, long a, long b) {
    uint32_t off = site & 0xFFFFFFu;
    int line = (chunk && chunk->lines && (int)off < chunk->lines_len)
             ? chunk->lines[off] : 0;
    fprintf(stderr,
            "EIGS_JIT_CHECKED: %s (%ld vs %ld) at %s offset %u in chunk '%s' line %d\n",
            what, a, b, op_name((uint8_t)(site >> 24)), off,
            (chunk && chunk->name) ? chunk->name : "<anon>", line);
    fflush(stderr);
    abort();
}

void jit_checked_local(uint64_t *cached_values, uint32_t slot,
                       uint32_t site, EigsChunk *chunk) {
    Env *e = g_vm.frames[g_vm.frame_count - 1].fn_env;
    if ((void *)cached_values != (void *)e->values)
        jit_checked_fail(chunk, site, "stale %r12 values base (cached != fn_env->values)",
                         (long)(intptr_t)cached_values, (long)(intptr_t)e->values);
    if ((int)slot >= e->count)
        jit_checked_fail(chunk, site, "local slot out of range (slot vs fn_env->count)",
                         (long)slot, (long)e->count);
}

void jit_checked_env_slot(Env *target, uint32_t slot, uint32_t site,
                          EigsChunk *chunk) {
    if ((int)slot >= target->count)
        jit_checked_fail(chunk, site, "IC slot out of range (slot_idx vs target->count)",
                         (long)slot, (long)target->count);
}
#endif
