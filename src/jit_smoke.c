/*
 * JIT Stage 1 smoke test.
 *
 * Allocates a code cache, emits a thunk returning a known int64, seals
 * the cache (RW -> RX), invokes the thunk, and asserts the result. Run
 * directly after `make jit-smoke` to confirm the platform allows
 * executable mmap regions and the chosen calling convention works.
 */
#include "jit.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>

/* Stage 3b layout probe lives in vm.c — stub it so the standalone smoke
 * binary links. The smoke test never invokes jit_try_compile_chunk, so
 * this stub is unreachable. */
void eigs_jit_get_layout(EigsJitLayout *out) { (void)out; }

/* Stage 4c references &free_value as an immediate in the decref emitter,
 * so the linker needs a definition even though the smoke path never
 * invokes the emitter. Stub returns void. */
typedef struct Value Value;
void free_value(Value *v) { (void)v; }

/* Diagnostic histogram in jit_module_shutdown references op_name from
 * chunk.c. The smoke binary never triggers the histogram path because
 * EIGS_JIT_STOPS is not set, but the linker still needs a definition. */
const char *op_name(uint8_t op) { (void)op; return "?"; }

/* Stage 4k references &jit_helper_get_name as an immediate in the
 * OP_GET_NAME emitter. Smoke test never invokes that emitter, but
 * the linker needs a definition. */
struct EigsChunk;
void jit_helper_get_name(struct EigsChunk *chunk, int idx) {
    (void)chunk; (void)idx;
}

/* Stage 4l: same shape — emitter takes &jit_helper_local_idx_get as an
 * immediate. Smoke binary never invokes the emit path. */
void jit_helper_local_idx_get(int slot, int idx) {
    (void)slot; (void)idx;
}

/* Stage 4m: same shape — emitter takes &jit_helper_local_dot_get as an
 * immediate. Smoke binary never invokes the emit path. */
void jit_helper_local_dot_get(struct EigsChunk *chunk, int slot, int name_idx) {
    (void)chunk; (void)slot; (void)name_idx;
}

static int run_case(int64_t expected) {
    EigsJitCache *jc = jit_cache_new(1);
    if (!jc) {
        fprintf(stderr, "FAIL: jit_cache_new\n");
        return 1;
    }
    JitConstFn fn = jit_emit_const_return(jc, expected);
    if (!fn) {
        fprintf(stderr, "FAIL: jit_emit_const_return\n");
        jit_cache_free(jc);
        return 1;
    }
    if (jit_cache_seal(jc) != 0) {
        fprintf(stderr, "FAIL: jit_cache_seal\n");
        jit_cache_free(jc);
        return 1;
    }
    int64_t got = fn();
    int rc = 0;
    if (got != expected) {
        fprintf(stderr, "FAIL: expected %" PRId64 ", got %" PRId64 "\n",
                expected, got);
        rc = 1;
    } else {
        printf("ok  const_return(%" PRId64 ") = %" PRId64
               "  [%zu bytes emitted]\n",
               expected, got, jit_cache_used(jc));
    }
    jit_cache_free(jc);
    return rc;
}

int main(void) {
    int rc = 0;
    rc |= run_case(42);
    rc |= run_case(-1);
    rc |= run_case(0x0123456789ABCDEFLL);
    rc |= run_case(INT64_MIN);
    rc |= run_case(INT64_MAX);
    if (rc == 0) printf("\nJIT smoke: all cases passed.\n");
    return rc;
}
