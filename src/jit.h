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

/* On-stack-replacement variant. Compiles a thunk that begins execution
 * at `entry_offset` (typically a hot loop header) rather than chunk
 * byte 0, into chunk->jit_osr[slot] (Stage 5g: one slot per hot loop
 * header, JIT_OSR_SLOTS max — vm.c's JUMP_BACK handler picks the
 * slot). Idempotent per slot: returns immediately if the slot's state
 * is already set. Failed offsets stay recorded in the slot so the
 * caller's scan doesn't retry them. */
void jit_try_compile_chunk_osr(struct EigsChunk *chunk, int entry_offset,
                               int slot);

/* Lifetime hooks for the per-thread JIT cache. jit_module_shutdown is
 * optional (process exit reclaims pages anyway) but useful in tests. */
void jit_module_init(void);
void jit_module_shutdown(void);

/* OSR threshold accessor for vm.c. vm.c caches the result thread-local
 * on the first JUMP_BACK so the dispatch loop doesn't pay a getenv per
 * iteration. The value is honors-EIGS_JIT_OSR_THRESHOLD env var. */
int eigs_jit_get_osr_threshold(void);

/* Register a chunk so its exec_count can be dumped at shutdown when
 * EIGS_JIT_HOT=1. Idempotent. Called from vm_run on top-level entry
 * and from jit_try_compile_chunk on every first JIT visit. */
void jit_register_chunk(struct EigsChunk *chunk);
void jit_unregister_chunk(struct EigsChunk *chunk);

/* ---- Stage 3b inline-emit layout descriptor ----
 *
 * vm.c owns g_vm (static __thread) so it is the only TU that can
 * compute the TLS @tpoff for that symbol and the VM/CallFrame field
 * offsets. The JIT emitter reads this once at first compile and uses
 * it to inline native loads/stores against g_vm without going through
 * helper functions. */
typedef struct {
    long g_vm_tpoff;                /* &g_vm - %fs:0, signed bytes */
    long g_unobserved_depth_tpoff;  /* &g_unobserved_depth - %fs:0 */
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
    /* Stage 5d: dict field inline cache (vm.c-private DictCacheEntry,
     * static __thread g_dict_cache[]) so LOCAL_DOT_GET/SET can inline
     * the cache-hit path. */
    long g_dict_cache_tpoff;        /* &g_dict_cache[0] - %fs:0 */
    int  sizeof_dcache_entry;
    int  off_dcache_dict;
    int  off_dcache_hash;
    int  off_dcache_index;
    int  dcache_mask;               /* Stage 5h: SET mask (sets - 1) */
    int  dcache_ways;               /* Stage 5h: 2-way associative */
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

/* Stage 4v: out-of-line helper for OP_LOCAL_IDX_DOT_GET — the #1 DMG
 * bailout (48% of stops). Pushes one slot (local[slot][list_idx].name),
 * net sp change +1. Same sp sync/reload pattern as OP_LOCAL_DOT_GET:
 * sync %ecx → g_vm.sp before call so helper's vm_push_* sees the
 * current top; reload %ecx ← g_vm.sp after to pick up the push. */
void jit_helper_local_idx_dot_get(struct EigsChunk *chunk, int slot,
                                  int list_idx, int name_idx);

/* Stage 4q-f: out-of-line helper for OP_DOT_GET. Pops target,
 * pushes target.name — net sp change zero. Needs chunk for
 * const_interns / const_hashes. */
void jit_helper_dot_get(struct EigsChunk *chunk, int name_idx);

/* Stage 5g: out-of-line helper for OP_DOT_SET. Pops value + target,
 * pushes value back (net sp -1). Needs chunk for const_interns /
 * const_hashes. */
void jit_helper_dot_set(struct EigsChunk *chunk, int name_idx);

/* Stage 4q-d: out-of-line helper for OP_LOCAL_DOT_SET. Mirrors
 * CASE(LOCAL_DOT_SET): writes local[slot].name = TOS without popping
 * (next OP_POP clears the stack). Helper reads g_vm.stack[sp-1] so
 * the JIT site must sync %ecx → g_vm.sp before the call; sp is
 * unchanged on return so no reload is required. */
void jit_helper_local_dot_set(struct EigsChunk *chunk, int slot, int name_idx);

/* Stage 4o: out-of-line helpers for OP_OBSERVE_ASSIGN /
 * OP_OBSERVE_ASSIGN_LOCAL. Both update observer history on the value
 * at g_vm.stack[sp-1] (possibly promoting an immediate-num). They do
 * not change sp. The OBSERVE_ASSIGN variant needs chunk for const_interns
 * / const_hashes; OBSERVE_ASSIGN_LOCAL reads the prior value from
 * frame->fn_env->values[slot] directly. */
void jit_helper_observe_assign(struct EigsChunk *chunk, int name_idx);
void jit_helper_observe_assign_local(int slot);

/* Stage 4q-a: out-of-line helper for OP_ITER_NEXT. Returns 1 if the
 * iterator at g_vm.stack[sp-1] is exhausted (no element pushed), 0 if
 * it pushed the next element and advanced the in-state index. Mirrors
 * the body of CASE(ITER_NEXT) in vm.c but without ip mutation — the
 * JIT-emitted call site does the branch. */
int jit_helper_iter_next(void);

/* Stage 4q-c: out-of-line helper for OP_INDEX_GET. Mirrors
 * CASE(INDEX_GET): pops index + target slots from g_vm.stack (sp -= 2),
 * pushes the indexed value (or null on error, after calling
 * runtime_error to preserve interpreter semantics). The JIT site
 * must sync %ecx → g_vm.sp before the call and reload after. */
void jit_helper_index_get(void);
void jit_helper_index_set(void);
int  jit_helper_loop_stall_check(void);
void jit_helper_set_name(struct EigsChunk *chunk, int idx);
void jit_helper_set_name_local(struct EigsChunk *chunk, int idx);
void jit_helper_set_fn_name_local(struct EigsChunk *chunk, int idx);

/* Stage 4r/5f: out-of-line helper for OP_CALL. Returns:
 *   0 — call completed (builtin ran, or a compiled VAL_FN callee ran
 *       natively to its RETURN); caller thunk continues.
 *   1 — not eligible; stack untouched; caller thunk bails with %r13d
 *       at the CALL's offset so the interpreter re-executes it.
 *   2 — deep bail: callee frame(s) live with consistent ips, caller
 *       frame's ip set to resume_off. Caller thunk must exit with the
 *       -2 advance sentinel so vm_run resyncs to the current frame.
 * `chunk` is the CALLER's chunk (for the resume_off → ip fixup);
 * resume_off is the absolute bytecode offset of the op after the CALL. */
int jit_helper_call(struct EigsChunk *chunk, int argc, int resume_off);

/* Stage 4s: out-of-line helper for OP_RETURN. Mirrors the non-top-level
 * branch of CASE(RETURN): pops result, drains frame slice, frees env if
 * owned, restores loop-stall globals, pops the frame, and pushes the
 * result onto the (now-current) caller's stack. Always succeeds — no
 * bail return code. The JIT site pre-sets %r13d = (uint32_t)-1 so the
 * epilogue writes -1 into chunk->jit_advance; vm_run's post-thunk
 * handler detects the sentinel and resyncs frame/ip/chunk (or returns
 * top-of-stack as Value* when g_vm.frame_count <= base_frame). */
void jit_helper_return(void);

/* Stage 4t: out-of-line helper for OP_RETURN_NULL. Same shape as
 * jit_helper_return but skips the TOS-pop — always pushes slot_null().
 * The JIT-emitted call site uses the same jit_advance = -1 sentinel
 * pattern as OP_RETURN. */
void jit_helper_return_null(void);

#endif /* EIGS_JIT_H */
