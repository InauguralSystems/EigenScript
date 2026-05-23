/*
 * EigenScript JIT — Stage 1 scaffolding.
 *
 * Code cache built on a bump-allocated mmap region that starts RW, then
 * flips to RX once a batch of thunks has been emitted. No external
 * dependencies; raw machine-code emission per target ISA.
 *
 * Stage 1 exposes only the cache primitives plus a smoke emitter that
 * produces a "return int64 constant" thunk. Stage 2+ will add real
 * opcode templates (ARITH_FAST, LOCAL_GET/SET, JUMP) and a chunk-level
 * compile entry hook into vm_run.
 *
 * Currently x86-64 SysV only. aarch64 is a small port: 4-byte fixed-
 * width insns + an explicit __builtin___clear_cache call.
 */
#ifndef EIGS_JIT_H
#define EIGS_JIT_H

#include <stddef.h>
#include <stdint.h>

typedef struct EigsJitCache EigsJitCache;

/* Allocate a code cache covering `page_count` system pages. Memory is
 * initially RW. Returns NULL on mmap failure. */
EigsJitCache *jit_cache_new(size_t page_count);

/* Unmap and free the cache. Safe on NULL. */
void jit_cache_free(EigsJitCache *jc);

/* Bump-allocate `bytes` from the cache. Returns NULL if the cache is
 * sealed or out of room. The returned pointer is writable until seal. */
void *jit_cache_alloc(EigsJitCache *jc, size_t bytes);

/* Flip the entire cache to RX and clear the instruction cache. Returns
 * 0 on success, -1 if mprotect failed. Idempotent. */
int jit_cache_seal(EigsJitCache *jc);

/* Flip the entire cache back to RW for amend-and-reseal. Returns 0 on
 * success, -1 if mprotect failed. Idempotent. Must NOT be called while
 * another thread is executing code in the cache (single-thread cache
 * is enforced by `__thread` ownership). */
int jit_cache_unseal(EigsJitCache *jc);

/* Bytes currently allocated from the cache. */
size_t jit_cache_used(const EigsJitCache *jc);

/* Smoke: emit a thunk with signature `int64_t fn(void)` that returns
 * `value`. Returns a callable pointer or NULL. Caller must seal the
 * cache before invoking the returned function. */
typedef int64_t (*JitConstFn)(void);
JitConstFn jit_emit_const_return(EigsJitCache *jc, int64_t value);

/* ---- In-VM integration ----
 *
 * Forward declare the chunk type so vm.c can hand chunks to the JIT
 * without dragging the full vm.h into jit.c.  The full layout is
 * defined in vm.h. */
struct EigsChunk;

/* Signature of a chunk-level JITed entry point. The thunk has no
 * arguments and no return value: it executes a prefix of the chunk's
 * opcodes against `g_vm` (stack, sp, current_line) and returns. The
 * caller advances `frame->ip` by `chunk->jit_advance` after invocation
 * — keeping the frame-ip math out of the thunk saves ~15 cycles per
 * call and shrinks the emitted body. */
typedef void (*JitChunkFn)(void);

/* Try to compile `chunk` into native code. On success, sets
 * chunk->jit_state = 2 and chunk->jit_code to a JitChunkFn pointer.
 * On any unsupported pattern, sets jit_state = 1 and leaves jit_code
 * NULL. Idempotent — subsequent calls on the same chunk return
 * immediately if jit_state != 0. */
void jit_try_compile_chunk(struct EigsChunk *chunk);

/* Lifetime hooks for the per-thread JIT cache. jit_module_shutdown is
 * optional (process exit reclaims pages anyway) but useful in tests. */
void jit_module_init(void);
void jit_module_shutdown(void);

/* Register a chunk so its exec_count can be dumped at shutdown when
 * EIGS_JIT_HOT=1. Idempotent. Called from vm_run on top-level entry
 * and from jit_try_compile_chunk on every first JIT visit. */
void jit_register_chunk(struct EigsChunk *chunk);

/* ---- Stage 3b inline-emit layout descriptor ----
 *
 * vm.c owns g_vm (static __thread) so it is the only TU that can
 * compute the TLS @tpoff for that symbol and the VM/CallFrame field
 * offsets. The JIT emitter reads this once at first compile and uses
 * it to inline native loads/stores against g_vm without going through
 * helper functions. */
typedef struct {
    long g_vm_tpoff;       /* &g_vm - %fs:0, signed bytes */
    int  off_sp;
    int  off_stack;
    int  off_frame_count;
    int  off_frames;
    int  off_current_line;
    int  off_callframe_ip;
    int  off_callframe_fn_env;
    int  sizeof_callframe;
    int  off_env_values;
    int  off_env_count;
} EigsJitLayout;

void eigs_jit_get_layout(EigsJitLayout *out);

/* Stage 4k: out-of-line helper invoked by JIT-emitted OP_GET_NAME
 * sites. Doing the IC walk inline would cost ~80 bytes of native
 * code per call site; one funcall fits in ~30 bytes and the IC still
 * lives inside the helper. */
void jit_helper_get_name(struct EigsChunk *chunk, int idx);

/* Stage 4l: out-of-line helper for OP_LOCAL_IDX_GET. Mirrors the
 * VAL_BUFFER/VAL_LIST/VAL_STR dispatch in CASE(LOCAL_IDX_GET). */
void jit_helper_local_idx_get(int slot, int idx);

/* Stage 4m: out-of-line helper for OP_LOCAL_DOT_GET. Needs chunk for
 * const_interns / const_hashes — same shape as jit_helper_get_name. */
void jit_helper_local_dot_get(struct EigsChunk *chunk, int slot, int name_idx);

#endif /* EIGS_JIT_H */
