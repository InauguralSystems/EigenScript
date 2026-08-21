/* ================================================================
 * EigenScript Bytecode VM — Header
 * ================================================================
 * Stack-based bytecode VM replacing the AST tree-walker.
 * Encoding: [op:8] or [op:8][arg:16LE] or [op:8][arg1:16LE][arg2:16LE]
 */
#ifndef EIGENSCRIPT_VM_H
#define EIGENSCRIPT_VM_H

#include <stdint.h>

/* Forward declarations from eigenscript.h */
typedef struct Value Value;
typedef struct Env Env;
typedef struct ASTNode ASTNode;

/* EigsSlot is defined in value_slot.h which is included via
 * eigenscript.h after the Value struct is fully declared (needed
 * for the inline slot_incref / slot_decref refcount helpers). */
#include "value_slot.h"
/* Re-include is harmless because of the header guard, but if a TU
 * includes vm.h before eigenscript.h, slot_incref / slot_decref will
 * be incomplete-typed. All current TUs include eigenscript.h first. */

/* Direct-borrow scan cap (#546): a borrowing builtin can only return an
 * argument it actually read, and every registered builtin reads its arg
 * vector at small fixed indices (max arity 7). Shared with builtins.c so
 * the #548 guard self-test can construct a past-the-cap violation. */
#define VM_BORROW_SCAN_CAP 8

/* #548: in sanitizer builds the borrow scan keeps scanning past the cap
 * and aborts on a match the capped scan missed — a builtin returning a
 * borrowed direct child past index 7 would otherwise become a silent
 * lifetime-dependent use-after-free. Zero cost in release builds. */
#if defined(__SANITIZE_ADDRESS__)
#  define EIGS_BORROW_GUARD 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define EIGS_BORROW_GUARD 1
#  endif
#endif
#ifndef EIGS_BORROW_GUARD
#  define EIGS_BORROW_GUARD 0
#endif

/* #720: the builtin-result borrow protocol, shared by the three VM call
 * sites and the out-of-VM ones (call_eigs_fn, builtin_dispatch,
 * thread_entry) so they cannot drift apart again. caller_owns_arg=1 means
 * `result == arg` transfers the caller's ref; 0 means the caller only
 * borrows `arg` and identity needs an incref too. Never call this for a
 * consuming builtin (builtin_free_val) — it may have freed `arg`. Full
 * rationale at the definition in vm.c. */
void vm_borrow_compensate(Value *arg, Value *result, int caller_owns_arg,
                          Value *fn_val, Env *env);

/* ---- Opcodes ---- */
typedef enum {
    /* Constants */
    OP_CONST,           /*obs:NONE*/ /* [idx:16] push constant pool entry */
    OP_NULL,            /*obs:NONE*/ /* push null */
    OP_NUM_ZERO,        /*obs:NONE*/ /* push 0.0 */
    OP_NUM_ONE,         /*obs:NONE*/ /* push 1.0 */

    /* Arithmetic (pop 2, push 1) */
    OP_ADD, /*obs:NONE*/
    OP_SUB, /*obs:NONE*/
    OP_MUL, /*obs:NONE*/
    OP_DIV, /*obs:NONE*/
    OP_MOD, /*obs:NONE*/

    /* Bitwise (pop 2, push 1) */
    OP_BAND, /*obs:NONE*/
    OP_BOR, /*obs:NONE*/
    OP_BXOR, /*obs:NONE*/
    OP_SHL, /*obs:NONE*/
    OP_SHR, /*obs:NONE*/

    /* Unary (pop 1, push 1) */
    OP_NEG, /*obs:NONE*/
    OP_NOT, /*obs:NONE*/
    OP_BNOT, /*obs:NONE*/

    /* Comparison (pop 2, push 1) */
    OP_EQ, /*obs:NONE*/
    OP_NE, /*obs:NONE*/
    OP_LT, /*obs:NONE*/
    OP_GT, /*obs:NONE*/
    OP_LE, /*obs:NONE*/
    OP_GE, /*obs:NONE*/

    /* Variables */
    OP_GET_LOCAL,       /*obs:NONE*/ /* [slot:16] push local from frame slot */
    OP_SET_LOCAL,       /*obs:WRITES*/ /* [slot:16] TOS -> local slot (keep on stack) */
    OP_GET_NAME,        /*obs:NONE*/ /* [name_idx:16] dynamic lookup by name */
    OP_SET_NAME,        /*obs:WRITES*/ /* [name_idx:16] outward-assignment by name */
    OP_SET_NAME_LOCAL,  /*obs:WRITES*/ /* [name_idx:16] set in current scope only */
    OP_SET_FN_NAME_LOCAL, /*obs:WRITES*/ /* [name_idx:16] set in frame->fn_env (skips intervening loop/scope envs) */

    /* Control flow */
    OP_JUMP,            /*obs:NONE*/ /* [offset:16] unconditional forward jump */
    OP_JUMP_BACK,       /*obs:NONE*/ /* [offset:16] unconditional backward jump */
    OP_JUMP_IF_FALSE,   /*obs:NONE*/ /* [offset:16] pop, jump if falsy */
    OP_JUMP_IF_TRUE,    /*obs:NONE*/ /* [offset:16] pop, jump if truthy */
    OP_JUMP_IF_FALSE_PEEK, /*obs:NONE*/ /* [offset:16] peek, jump if falsy (short-circuit and) */
    OP_JUMP_IF_TRUE_PEEK,  /*obs:NONE*/ /* [offset:16] peek, jump if truthy (short-circuit or) */

    /* Stack manipulation */
    OP_POP,             /*obs:NONE*/ /* discard TOS */
    OP_DUP,             /*obs:NONE*/ /* duplicate TOS */
    OP_DUP2,            /*obs:NONE*/ /* duplicate top two: a b → a b a b */

    /* Functions */
    OP_CLOSURE,         /*obs:NONE*/ /* [fn_idx:16] create closure from compiled function */
    OP_CALL,            /*obs:NONE*/ /* [argc:16] call function with argc args */
    OP_RETURN,          /*obs:NONE*/ /* return TOS */
    OP_RETURN_NULL,     /*obs:NONE*/ /* return null (implicit) */

    /* Data structures */
    OP_LIST,            /*obs:NONE*/ /* [count:16] pop count items, push list */
    OP_DICT,            /*obs:NONE*/ /* [count:16] pop count key-value pairs, push dict */
    OP_INDEX_GET,       /*obs:NONE*/ /* pop index, pop target, push target[index] */
    OP_INDEX_SET,       /*obs:NONE*/ /* pop value, pop index, pop target, set, push value */
    OP_DOT_GET,         /*obs:NONE*/ /* [name_idx:16] pop target, push target.name */
    OP_DOT_SET,         /*obs:NONE*/ /* [name_idx:16] pop value, pop target, set, push value */

    /* Loops and iteration */
    OP_ITER_SETUP,      /*obs:NONE*/ /* pop iterable, push iterator state */
    OP_ITER_NEXT,       /*obs:NONE*/ /* [exit_offset:16] advance or jump to exit */
    OP_LOOP_ENV_FRESH,  /*obs:NONE*/ /* create fresh child env if current was captured by closure */
    OP_LOOP_ENV_END,    /*obs:NONE*/ /* restore parent env from loop body env */
    OP_BREAK,           /*obs:NONE*/ /* unwind to enclosing loop exit */
    OP_CONTINUE,        /*obs:NONE*/ /* jump to enclosing loop header */

    /* Error handling */
    OP_TRY_BEGIN,       /*obs:NONE*/ /* [catch_offset:16] push exception handler */
    OP_TRY_END,         /*obs:NONE*/ /* pop exception handler */

    /* Observer system */
    OP_OBSERVE_ASSIGN,  /*obs:NONE*/ /* [name_idx:16] observer update for assignment (env walk) */
    OP_OBSERVE_ASSIGN_LOCAL, /*obs:WRITES*/ /* [slot:16] observer update; prev value lives in fn_env slot */
    OP_INTERROGATE,     /*obs:NONE*/ /* [kind:16] pop target, push query result */
    OP_PREDICATE,       /*obs:READS*/ /* [kind:16] push predicate result */
    OP_UNOBSERVED_BEGIN,/*obs:WRITES*/ /* increment g_unobserved_depth */
    OP_UNOBSERVED_END,  /*obs:WRITES*/ /* decrement g_unobserved_depth */
    OP_LOOP_STALL_CHECK,/*obs:READS*/ /* [exit_offset:16] observer-stall + iteration cap (observer-based loops) */
    OP_LOOP_CAP_CHECK,  /*obs:DIAG*/ /* [exit_offset:16] iteration cap ONLY (plain loops; no observer-stall) */

    /* Miscellaneous */
    OP_IMPORT,          /*obs:NONE*/ /* [name_idx:16] import module, push dict */
    OP_MATCH,           /*obs:NONE*/ /* [case_count:16] pattern match dispatch */
    OP_LISTCOMP_BEGIN,  /*obs:NONE*/ /* push empty list accumulator */
    OP_LISTCOMP_APPEND, /*obs:NONE*/ /* append TOS to accumulator */
    OP_LINE,            /*obs:WRITES*/ /* [line:32] update current line number (#630: was 16-bit, wrapped past line 65535) */
    OP_WIDE,            /*obs:NONE*/ /* next operand is 32-bit */
    OP_DISPATCH,        /*obs:NONE*/ /* pop arg, key, table; call table[key](arg) inline */

    /* Superinstructions */
    OP_LOCAL_DOT_GET,   /*obs:NONE*/ /* [slot:16][name_idx:16] push local[slot].name */
    OP_LOCAL_DOT_SET,   /*obs:NONE*/ /* [slot:16][name_idx:16] TOS = local[slot].name = TOS */
    OP_LOCAL_IDX_GET,   /*obs:NONE*/ /* [slot:16][idx:16] push local[slot][idx] */
    OP_LOCAL_IDX_DOT_GET, /*obs:NONE*/ /* [slot:16][idx:16][name_idx:16] push local[slot][idx].name */
    OP_LOCAL_IDX_DOT_SET, /*obs:NONE*/ /* [slot:16][idx:16][name_idx:16] local[slot][idx].name = TOS */
    OP_INTERROGATE_NAMED, /*obs:READS*/ /* [kind:16][name_idx:16] interrogate with known binding name */
    OP_INTERROGATE_NAMED_AT, /*obs:READS*/ /* [kind:16][name_idx:16] interrogate at line (popped from stack) */

    OP_DEFAULT_PARAM,   /*obs:NONE*/ /* [slot:16][skip_off:16] if frame->call_argc > slot, IP += skip_off
                         * (skip the default expression); else fall through (default runs
                         * and ends with OP_SET_LOCAL <slot>; OP_POP). */
    OP_DESTRUCTURE_UNPACK, /*obs:NONE*/ /* [n:16] pop list, raise if not VAL_LIST or length != n,
                            * else push elements onto stack in reverse so element 0 is TOS.
                            * Pairs with N assignment ops emitted after by the compiler. */
    OP_SLICE_GET,       /*obs:NONE*/ /* pop 3 (end, start, target); push the slice of target from
                         * start..end (half-open). null in either bound means default
                         * (0 / len). Target must be VAL_LIST / VAL_STR / VAL_BUFFER.
                         * Negatives resolve via +len before the 0<=start<=end<=len
                         * check; out-of-range raises. Same scanner-stop pattern as
                         * DESTRUCTURE_UNPACK — JIT bails to interpreter. */

    /* #262 Phase-3 observer ops. Added at the END of the enum, NOT mid-list:
     * hand-built / self-hosted-bridge bytecode hardcodes opcode NUMBERS
     * (e.g. tests/test_vm_run_bytecode.eigs's `loopcode` uses 63 = LOOP_CAP_CHECK),
     * so inserting an opcode anywhere before them shifts those numbers and
     * misaligns the bytecode. New opcodes must always append here. */
    OP_REPORT_SLOT,     /*obs:READS*/ /* [slot:16] report-of-local via slot trajectory (compile-flag gated) */
    OP_OBSERVE_NAME_POST,/*obs:WRITES*/ /* [name_idx:16] slot-observe a name binding AFTER its SET
                          * (binding now exists), fixing the first-assignment lag.
                          * Emitted only under compile-time EIGS_OBS_SHADOW; peeks TOS. */
    OP_REPORT_NAME,     /*obs:READS*/ /* [name_idx:16] report of a non-local name: resolve (env,slot),
                          * classify its slot. Compile-flag gated. */
    OP_OBSERVE_VALUE_SLOT, /*obs:READS*/ /* [slot:16] `observe of <local>`: [status,entropy,dH,prev_dH]
                            * from the local's slot trajectory. Compile-flag gated. */
    OP_OBSERVE_VALUE_NAME, /*obs:READS*/ /* [name_idx:16] `observe of <name>`: same, resolving the
                            * binding's (env,slot). Compile-flag gated. */
    OP_LOOP_ENV_CLEAR,  /*obs:WRITES*/ /* reset a persisted loop env's bindings for a new iteration.
                         * Appended here (NOT mid-list) per the convention above —
                         * hand-built bytecode hardcodes opcode numbers. */
    OP_PREDICATE_SLOT,  /*obs:READS*/ /* [kind:16][slot:16] `<predicate> of <local>` — classify the
                         * named local's slot trajectory (not the global last-observed
                         * alias the bare OP_PREDICATE reads). Appended, not mid-list. */
    OP_PREDICATE_NAME,  /*obs:READS*/ /* [kind:16][name_idx:16] `<predicate> of <name>` — resolve the
                         * binding's (env,slot) and classify its slot trajectory. */
    OP_REPORT_VALUE_SLOT, /*obs:READS*/ /* [slot:16] `report_value of <local>` — classify the local's
                           * VALUE trajectory (#294), not its entropy. Appended, not mid-list. */
    OP_REPORT_VALUE_NAME, /*obs:READS*/ /* [name_idx:16] `report_value of <name>` — resolve the binding's
                           * (env,slot) and classify its value trajectory. */
    OP_TRAJECTORY_SLOT, /*obs:READS*/ /* [slot:16] `trajectory of <local>` (#421) — snapshot the local
                         * slot's observer windows into a dict VALUE that survives a call
                         * boundary (the slot itself is binding-identity and cannot).
                         * Appended, not mid-list. */
    OP_TRAJECTORY_NAME, /*obs:READS*/ /* [name_idx:16] `trajectory of <name>` — resolve the binding's
                         * (env,slot) and snapshot it. */
    OP_INTERROGATE_NAMED_WHEN, /*obs:READS*/ /* [kind:16][name_idx:16] `<kw> is x when <N>` (#868) —
                                * interrogate at the Nth RECORDED assignment (ordinal
                                * popped from the stack), not at a source line. The `at`
                                * address space is source lines, which is not injective:
                                * a loop body executed N times keeps one live history
                                * entry (#827's suffix-minima pruning), so every
                                * iteration but the last is unaddressable. Ordinals are
                                * injective and edit-stable. Appended, not mid-list. */

    OP_COUNT            /* sentinel — number of opcodes */
} OpCode;

/* #704: the bytecode ABI revision.
 *
 * Opcode NUMBERS are an ABI (see the append-at-the-end rule above) and so is
 * every operand's WIDTH — but only the numbers were ever guarded. v0.33.0
 * widened OP_LINE's operand 16->32 bits (#630) without renumbering anything,
 * so `test_opcode_abi.c`'s static asserts stayed green while every external
 * producer's chunks ran misaligned: ouroboros emitted empty output for all 44
 * parity programs at exit 0, and iLambdaAi's grading ladder silently lost its
 * top rung. Consumers pin a release, so their CI structurally cannot warn us
 * before the bump.
 *
 * So: an external producer stamps the revision it was BUILT against as element
 * 0 of the top-level descriptor, and vm_run_bytecode / sandbox_run refuse any
 * other value. A stale producer now gets a named error instead of executing
 * garbage.
 *
 * BUMP THIS whenever an opcode's number changes, an opcode is inserted
 * mid-enum, or any operand's width changes. (Appending a NEW opcode at the end
 * does not require a bump — existing chunks stay byte-identical.)
 *
 * The stamp must be a LITERAL in the producer. Do NOT expose this value as a
 * builtin for producers to read back: a producer that asks the runtime which
 * revision it speaks always matches, and the guard becomes decoration. */
#define EIGS_BYTECODE_ABI 1

/* ---- Inline cache for env name resolution ----
 * One entry per string constant, populated lazily by GET_NAME/SET_NAME/
 * SET_NAME_LOCAL on cache miss. Validates via:
 *   - starting_env identity (the frame's env at lookup time)
 *   - starting_env->binding_version unchanged (no shadow added)
 *   - target env (frame->env or frame->env->parent) binding_version
 *     unchanged (target hasn't been freed/recycled/cleared)
 * Restricted to walk_depth 0 or 1 — deeper resolutions fall through to
 * the normal chain walk so we don't have to validate intermediate envs. */
typedef struct {
    struct Env *starting_env; /* NULL = empty entry */
    uint32_t starting_ver;
    uint32_t target_ver;
    int      slot_idx;
    uint8_t  walk_depth;      /* 0 = local, 1 = parent */
} EnvIC;

/* ---- Bytecode Chunk ---- */

/* #407: shared source blob for runtime-error caret excerpts. One blob per
 * compile unit (script, REPL line, eval'd string, imported module); the
 * root chunk and every nested function chunk hold a ref, so the excerpt
 * text outlives the caller's source buffer (REPL lines and eval strings
 * are freed while closures keep their chunks alive). Not a GC edge —
 * plain owned data like chunk->name. Refcount policy mirrors chunk
 * refcounts: atomic when g_vm_multithreaded. */
typedef struct EigsSrcBuf {
    int   refcount;
    char *text;
} EigsSrcBuf;

EigsSrcBuf *srcbuf_new(const char *text);
void        srcbuf_incref(EigsSrcBuf *sb);
void        srcbuf_decref(EigsSrcBuf *sb);

typedef struct EigsChunk {
    /* Lifetime: 1 creator ref (compile_ast caller, or the parent chunk's
     * functions[] slot for nested chunks) + 1 per live VAL_FN pointing at
     * this chunk (taken in OP_CLOSURE) + 1 per active call frame running
     * it. Atomic when g_vm_multithreaded, plain otherwise — same policy
     * as Value/env refcounts. */
    int      refcount;

    /* #830: 1 when this chunk came out of the bytecode compiler, which
     * scanned its source for temporal queries and armed the names they can
     * reach (trace_arm_history_name/all). ONLY such a chunk may use the
     * armed-name filter in trace_assign_filtered — the filter's soundness
     * is exactly that scan. A chunk assembled from a descriptor
     * (vm_run_bytecode / sandbox_run) was never scanned, so its assignments
     * go through the unfiltered trace_assign and record every name.
     * Default 0 (unfiltered) is the conservative direction: forgetting to
     * stamp a compiler-produced chunk costs recording work, while wrongly
     * stamping an unscanned one is a silent wrong answer. */
    uint8_t  compiler_scanned;

    uint8_t *code;              /* bytecode array */
    int      code_len;
    int      code_cap;

    Value  **constants;         /* constant pool */
    uint32_t *const_hashes;     /* cached hashes for string constants */
    char    **const_interns;    /* interned pointers for string constants (NULL for non-str) */
    EnvIC   *env_ic;            /* IC entry per string constant (zeroed = empty) */
    int      const_count;
    int      const_cap;
    int     *const_dedup;       /* compile-time NUM/STR dedup index — open
                                 * addressing, slot = const index+1, 0=empty.
                                 * The linear dedup scan it replaces was 92%
                                 * of compile time on many-name programs
                                 * (#341). Rebuilt on grow; freed with the
                                 * chunk. */
    int      const_dedup_cap;   /* power of two; 0 until first NUM/STR add */

    int     *lines;             /* line number per bytecode offset */
    int      lines_len;
    int      lines_cap;
    int     *cols;              /* #407: 0-based column per bytecode offset
                                 * (the emitting AST node's col; 0 when
                                 * unknown). Same length/cap as lines[].
                                 * Compile-time only data, read on the
                                 * cold error path — never in dispatch. */
    int      cur_col;           /* compile-time cursor: column stamped into
                                 * cols[] by chunk_emit; maintained by
                                 * compile_node's save/set/restore. */
    EigsSrcBuf *src;            /* #407: source text for caret excerpts;
                                 * shared across the unit's chunks. May be
                                 * NULL (no caret printed then). */

    struct EigsChunk **functions; /* nested function chunks */
    int      fn_count;
    int      fn_cap;

    char   **local_names;       /* local variable names */
    int      local_count;

    char    *name;              /* function name or "<module>" */
    int      param_count;
    int      first_default;     /* slot index of first param with a default; ==
                                 * param_count when no defaults. Calls with
                                 * argc in [first_default, param_count] are
                                 * legal; missing tail slots are filled by the
                                 * body prologue via OP_DEFAULT_PARAM. */
    int      max_stack;         /* computed max stack depth */

    /* JIT — populated lazily on first frame push.
     * jit_state: 0 = untried, 1 = failed/unsupported, 2 = compiled.
     * jit_code: callable native thunk (signature void(void)) when
     * jit_state == 2. The thunk runs a prefix of opcodes against g_vm
     * thread-local state and returns; the caller advances frame->ip by
     * jit_advance bytes. Keeping the ip math out of the thunk avoids
     * ~15 cycles of frame_count/sizeof_callframe arithmetic per call. */
    uint8_t  jit_state;
    int      jit_advance;
    void    *jit_code;
    uint8_t  jit_stop_op;       /* opcode that stopped the JIT prefix scan,
                                 * or OP_COUNT if scan ran to end of chunk */

    /* #366: body is a single pure accessor expression over param locals
     * (field/index gets + num arithmetic, ending in RETURN — set by
     * chunk_scan_leaf_accessor at compile time). Exactly-fed calls run
     * frameless against the caller's stack: no env take/rebind/park, no
     * frame push, no chunk refcount round-trip. Any runtime surprise
     * (type mismatch, out-of-range index) bails to the generic CALL
     * path before touching the stack, so error semantics are byte-
     * identical. */
    uint8_t  leaf_accessor;

    /* OSR — On-Stack Replacement. The from-zero JIT slot above only
     * helps chunks that get called repeatedly (exec_count gate) or do
     * enough loop iterations to trip back_edge_count over the iter
     * threshold *between* calls. A "one big function called once with
     * a hot inner loop" — e.g. gauntlet's top-level chunk — never
     * benefits because exec_count tops out at 1.
     *
     * OSR fixes that: while the chunk is mid-execution and a back-edge
     * fires for the Nth time, the JUMP_BACK handler asks the JIT for a
     * thunk that starts at the loop header (entry_offset) instead of
     * byte 0. The interpreter then jumps directly into native code,
     * skipping the prologue + everything before the loop header.
     *
     * jit_osr_state: 0 = untried, 1 = failed/unsupported, 2 = compiled.
     * jit_osr_entry_offset: bytecode offset the thunk begins at.
     * jit_osr_code: callable JitChunkFn when jit_osr_state == 2.
     * jit_osr_advance: bytes to add to frame->ip (which is at
     *   entry_offset at handoff time) after the thunk returns. */
    /* Stage 5g: one OSR slot per hot loop header, JIT_OSR_SLOTS max.
     * A single slot per chunk let whichever loop crossed the back-edge
     * threshold FIRST own native execution forever — bench_dmg_shape's
     * 65k-iteration setup loop pinned the slot and the 500k-iteration
     * main loop ran interpreted for good. The JUMP_BACK handler scans
     * for a slot matching the current loop header and allocates a free
     * one (compiling lazily) when the back-edge gate trips. Failed
     * offsets stay recorded (state 1) so they don't retry-storm.
     * state: 0 = free, 1 = failed/unsupported, 2 = compiled. */
    struct {
        uint8_t  state;
        uint8_t  stop_op;
        int      entry_offset;
        int      advance;
        void    *code;
    } jit_osr[4];
#define JIT_OSR_SLOTS 4

    /* Diagnostic: incremented on every frame entry (vm_run + both CALL
     * paths). Dumped at shutdown when EIGS_JIT_HOT=1 so we can correlate
     * chunk hotness with jit_state and the stop-opcode histogram. */
    uint64_t exec_count;

    /* Hotness: incremented on every interpreter back-edge (OP_JUMP_BACK)
     * while this chunk is the current frame's chunk. Captures internal
     * loop iterations so chunks that are *called* infrequently but
     * *iterate* heavily can still earn a JIT thunk (e.g. one-shot
     * top-level chunk or a worker function called <50× with hot inner
     * loops). u32 saturates at ~4.3B back-edges; on overflow the gate
     * still trips correctly because exec_count or saturation crosses
     * the threshold long before. */
    uint32_t back_edge_count;

    /* Stage 5i: parked call env for recycling. After a call returns,
     * its env can be parked here (values dropped to null; param names,
     * hash entries, and binding_version kept) and the next call to
     * this chunk rebinds the param slots in place — skipping env_new,
     * per-param hash inserts, and the version bump, which also keeps
     * every EnvIC aimed at this env hot across calls. Only envs whose
     * count matches the compiler-known layout are parked (a binding
     * created mid-call must not resolve in the next invocation), only
     * when not captured by a closure, and only single-threaded.
     * Owned by the chunk; released in chunk_decref's destructor. */
    struct Env *env_cache;
} EigsChunk;

/* ---- Call Frame ---- */

/* Max `try` blocks live at once in a single frame. Both the compiler (source)
 * and TRY_BEGIN (untrusted chunks) reject going past it — see #726. */
#define MAX_TRY_HANDLERS 8

typedef struct {
    /* #743: the OWNED fields of a frame are exactly {env (iff owns_env),
     * chunk}; their init and release have a single definition in vm.c —
     * callframe_init (every frame push) and callframe_release (declared
     * below, non-static for cross-TU use). callframe_release covers ALL
     * THREE saved-frame teardown loops: task_sched_thread_free and
     * task_do_kill (vm.c) and task_free (builtins.c). Add an owned field to
     * one of those two helpers, never to an individual teardown site. The
     * live-frame POP paths — the OP_RETURN family, vm_error_halt, and the
     * CHECK_ERROR unwind — deliberately inline the same drops because they
     * ALSO drain the operand-stack window and restore the per-frame
     * loop-stall globals (and OP_RETURN parks reusable envs / defers the
     * chunk ref to a -1 sentinel); a new owned field must be audited there
     * too. */
    EigsChunk *chunk;
    uint8_t   *ip;              /* instruction pointer */
    int        bp;              /* base pointer into value stack */
    Env       *env;             /* current env (may be loop-fresh child) */
    Env       *fn_env;          /* function's original env (for GET_LOCAL/SET_LOCAL) */
    Value     *closure_val;     /* the VAL_FN that was called */
    int        owns_env;        /* 1 if frame owns its env (free on return) */
    int        is_try;          /* 1 if any try handler active */
    /* Try handler stack (supports nested try/catch within a frame). The
     * compiler rejects source that nests deeper than MAX_TRY_HANDLERS; the
     * VM re-checks because untrusted chunks (vm_run_bytecode / sandbox_run)
     * reach TRY_BEGIN without going through the compiler at all (#726). */
    /* #871: unobs_depth is g_unobserved_depth as it stood when this handler
     * was registered. An error unwinding INTO the catch skips every
     * OP_UNOBSERVED_END between the raise and here, so without restoring it
     * the runtime depth stays elevated and the observer silently stops
     * recording for the rest of the process. */
    struct { uint8_t *catch_ip; int catch_bp; int unobs_depth; } try_handlers[MAX_TRY_HANDLERS];
    int        try_count;       /* number of active try handlers */
    /* Saved loop-stall globals (so a callee's loops don't inherit caller's
     * accumulated stall count / iteration count). Scoped per call frame. */
    int        saved_stall_count;
    long long  saved_loop_iter;   /* #772: matches EigsState.loop_iterations */
    int        call_argc;        /* args actually passed to this call; <= chunk->param_count.
                                  * Used by OP_DEFAULT_PARAM to decide if a slot was bound
                                  * by the caller or needs its default expression run. */
    uint32_t   call_serial;      /* #539 v2: per-thread monotonically increasing
                                  * frame-instance id, stamped at every frame push.
                                  * The tape's S records carry it so the stepper can
                                  * tell two invocations of the same function apart
                                  * (POD — rides the task save/restore memcpy). */
} CallFrame;

/* #743: drop a saved frame's owned refs — env iff owns_env, then chunk. The
 * single release definition (see the CallFrame comment above for the owned-set
 * invariant); non-static so builtins.c's task_free reaches the same helper as
 * the two vm.c teardown loops. Live-frame POP paths do NOT use it. */
void callframe_release(CallFrame *f);

/* ---- VM State ---- */
#define VM_STACK_MAX  65536
#define VM_FRAMES_MAX 4096

typedef struct VM {
    EigsSlot   stack[VM_STACK_MAX];
    int        sp;
    CallFrame  frames[VM_FRAMES_MAX];
    int        frame_count;
    int        current_line;
    /* Back-pointer to the owning EigsThread, set in vm_init. Lets the
     * JIT reach EigsThread fields (e.g. unobserved_depth) via a single
     * `mov off_vm_owner(%rbx), %rax` instead of a TLS read at every
     * mid-thunk access — and the same encoding works on both Linux ELF
     * and Darwin/Mach-O (no platform-specific TLS sequence needed). */
    struct EigsThread *owner;
} VM;

/* ---- #408 cooperative task layer ------------------------------------
 * A Task is a reified VM context on the single OS thread — cooperatively
 * scheduled, deterministic by construction (no tape records: interleaving
 * is a pure function of program order). Increment 1a defines the full
 * struct; the copying-stack save-buffer fields (saved_*) are populated by
 * the suspend/resume surgery in increment 1b. Held refs (entry_fn/args/
 * result/error_value) keep their objects live under the trial-deletion
 * cycle collector automatically — a counted ref exceeds the collector's
 * internal edge count within U, exactly as ThreadHandle->fn does; no
 * special root registration needed (docs/CLOSURE_CYCLE_GC.md). */
typedef enum {
    TASK_READY,       /* runnable, not started or between yields */
    TASK_RUNNING,     /* currently executing (== scheduler current) */
    TASK_SUSPENDED,   /* yielded/blocked with a live save-buffer (1b) */
    TASK_DONE,        /* returned normally */
    TASK_DEAD         /* died of an uncaught error */
} TaskState;

typedef struct Task {
    int        id;                 /* == handle-table id; 1-based */
    TaskState  state;
    int        started;            /* 0 until first scheduled (1b) */
    Value     *entry_fn;           /* owned VAL_FN/VAL_BUILTIN to run */
    Value    **args;               /* owned, deep-copied at spawn */
    int        argc;
    /* The task's base call env (1b), created at start from entry_fn's
     * closure with args bound. The base frame BORROWS it (owns_env=0), so
     * the Task owns it across suspend/resume; decref'd when the task ends
     * (or in task_free). NULL for main (task 0 runs on the global env). */
    struct Env *run_env;
    /* Copying-stack save-buffer — valid only while TASK_SUSPENDED (1b). */
    EigsSlot  *saved_stack;
    int        saved_stack_len;
    CallFrame *saved_frames;
    int        saved_frame_count;
    int        saved_current_line;
    /* Blocking join (1b): while this task is suspended in task_join, the id
     * of the task it waits on (0 = not joining). On resume the scheduler
     * writes the joinee's deep-copied result over the placeholder the
     * task_join builtin left on the stack top — a builtin can't return a
     * value it doesn't know yet — or re-raises the joinee's error. */
    int        join_target;
    /* Inc 2: unbounded FIFO mailbox of deep-copied messages (share-nothing,
     * Erlang-style — bounded/backpressure is a cheap later add). Circular
     * buffer; grows on demand. recv_blocked is 1 while this task is suspended
     * in task_recv on an empty mailbox — woken by task_send, delivered to the
     * stack top on resume (same placeholder mechanism as join). */
    Value    **mbox;
    int        mbox_head, mbox_count, mbox_cap;
    int        recv_blocked;
    /* Inc 3: virtual time. `sleeping` is 1 while this task is suspended in
     * task_sleep; `wake_at` is the virtual-clock value it becomes runnable at.
     * The clock is logical (discrete-event) — it never tracks wall time and
     * only jumps forward to the earliest sleeper when nothing else is runnable,
     * so sleeping stays deterministic-by-construction (no tape records). */
    int        sleeping;
    double     wake_at;
    /* Completion. */
    Value     *result;             /* owned, deep-copied on normal end */
    int        has_error;          /* died of an uncaught error */
    Value     *error_value;        /* owned {kind,message,line} dict */
    /* #493: set when a worker (id != 0) dies of an uncaught runtime error and
     * NOT yet observed by a task_join. Cleared once a joiner delivers/re-raises
     * the error (caught or not). A task killed via task_kill is a deliberate
     * teardown, not an uncaught error, so it never sets this. Any task left
     * with this at process exit makes the process exit non-zero — a
     * fire-and-forget worker's death must not silently green a run. */
    int        err_unobserved;
    /* #530: fire-and-forget. Set by task_detach; the task is reaped (freed +
     * handle slot released) the moment it finishes or is killed, instead of
     * lingering joinable until process exit. */
    int        detached;
    /* #535: monotonic spawn stamp (scheduler counter; main is 0). The
     * same-instant sleeper-wake tie-break orders by THIS, never by handle
     * id — ids come from a rotating cursor and encode allocation history. */
    uint64_t   spawn_seq;
} Task;

/* Free a Task's held refs and the struct. Safe on any state; called by
 * handle_table_drain and (1b) by the scheduler on join/teardown. */
void task_free(Task *t);

/* #408 scheduler interface (1b). The task_* builtins (builtins.c) signal the
 * cooperative scheduler through these; the trampoline lives in vm.c, just
 * above the outermost vm_execute, so C-stack depth stays flat across any
 * number of task switches. Suspension is deterministic-by-construction — no
 * tape records. */
/* g_task_suspend_request (set by a suspending builtin, actioned at CASE(CALL))
 * is a per-thread bridge macro in eigenscript.h — #739: as a global it drove
 * other threads' CALL sites into a suspend they never asked for. */
void task_sched_on_spawn(int id);    /* enqueue a freshly spawned task, arm the scheduler */
void task_request_yield(void);       /* current task → tail of the ready queue */
int  task_request_join(int target);  /* current task blocks on `target`; 0 = bad target */
void task_sched_thread_free(void);   /* release the scheduler at thread detach */
int  task_any_unobserved_error(void);/* #493: any worker died of an uncaught error and was never joined? */
/* Inc 2 mailbox interface (builtins.c task_send/task_recv/task_try_recv/task_kill). */
int   task_deliver(int tid, Value *msg_owned); /* append msg (ownership taken); 1 sent / 0 dropped-to-dead */
int   task_mbox_has(void);           /* current task has a queued message? */
Value *task_mbox_pop(void);          /* pop current task's front message (owned ref) */
void  task_request_recv(void);       /* current task blocks awaiting a message */
int   task_do_kill(int tid);         /* deterministic teardown of `tid`; 0 = bad target */
int   task_do_detach(int tid);       /* #530: mark fire-and-forget (reap at finish); 0 = main/unknown */
/* Inc 3 virtual time (builtins.c task_sleep/task_now). */
void   task_request_sleep(double ticks); /* current task sleeps until virtual now + ticks */
double task_virtual_now(void);           /* current virtual-clock value (0 with no scheduler) */
int    task_current_id(void);            /* running task id; 0 = main (incl. no scheduler) — task_self (#526) */
/* Inc 4 seeded scheduling strategy (builtins.c task_sched_seed). */
void   task_sched_set_seed(double seed); /* install a seed → seeded pick; ensures the scheduler */

/* ---- Public API ---- */

/* Chunk lifecycle */
EigsChunk *chunk_new(const char *name);
void       chunk_free(EigsChunk *chunk);   /* alias of chunk_decref */
void       chunk_incref(EigsChunk *chunk);
void       chunk_decref(EigsChunk *chunk);
int        chunk_add_constant(EigsChunk *chunk, Value *val);
int        chunk_add_constant_positional(EigsChunk *chunk, Value *val);
void       chunk_emit(EigsChunk *chunk, uint8_t byte, int line);
void       chunk_emit_u16(EigsChunk *chunk, uint16_t val, int line);
void       chunk_emit_u32(EigsChunk *chunk, uint32_t val, int line);
int        chunk_emit_jump(EigsChunk *chunk, uint8_t op, int line);
void       chunk_patch_jump(EigsChunk *chunk, int offset);
int        chunk_add_function(EigsChunk *chunk, EigsChunk *fn);
void       chunk_scan_leaf_accessor(EigsChunk *chunk);  /* #366 */
void       chunk_disassemble(EigsChunk *chunk, const char *label);
/* #915: 1 if anything in this chunk (or a nested function chunk) can READ
 * observer state — a reader opcode, or an observer-read builtin name in the
 * constant pool (aliasing: `local r is report` emits no reader opcode).
 * Conservative in one direction only: every unclear case answers 1. Drives
 * the observer gate, so a wrong 0 is silently-wrong observer results. */
int        chunk_reads_observer(const EigsChunk *chunk);
/* #915: the opcode half alone, valid on a chunk that never met the compiler
 * (vm_run_bytecode / sandbox_run descriptors). Recurses into functions[]. */
int        chunk_has_reader_opcode(const EigsChunk *chunk);
/* #915: narrower — does it read observer state about a binding already present
 * in `env`? Used by the descriptor sites, where a reader over the chunk's OWN
 * frame slots is legitimate. See the definition for the residual. */
int        chunk_reads_named_binding(const EigsChunk *chunk, Env *env);
/* #915: hand every STRING-LITERAL `load_file` target in this chunk to `visit`.
 * Returns 1 if the unit is OPAQUE — it uses the name `load_file` in any shape
 * this scan does not recognize. An opaque unit must be treated as observing.
 * This does NOT check resolver parity between compile time and run time; that
 * is enforced at the load itself (builtin_load_file). See the definition. */
int        chunk_scan_static_loads(const EigsChunk *chunk,
                                   void (*visit)(const char *path, void *ud),
                                   void *ud);
const char *op_name(uint8_t op);
/* Verify an assembled (untrusted) chunk's bytecode is in-bounds before the VM
 * runs it. Returns 1 if safe to execute, 0 if it must be rejected. */
int        chunk_verify(EigsChunk *chunk);
/* EIGS_VERIFY_SELF=1 gate: assert the C compiler's own output satisfies
 * chunk_verify (including the stack-height pass), or exit 70 naming the chunk
 * and the reason. Called from compile_ast; see chunk.c for the rationale. */
void       chunk_verify_self_check(EigsChunk *chunk, const char *unit);
/* #831: arm history recording for the temporal opcodes an assembled chunk
 * contains (the compiler's source scan, replayed over verified bytecode).
 * Only call on a chunk tree chunk_verify accepted. */
void       chunk_arm_temporal(const EigsChunk *chunk);

/* Compiler */
EigsChunk *compile_ast(ASTNode *ast, Env *env, const char *src);

/* Sandbox loop-iteration cap (0 = default 100M). Set by builtin_sandbox_run.
 * Per-thread bridge macro in eigenscript.h (#739). */

/* Async abort seam: embedder-registered flag polled on every loop
 * back-edge — interpreter AND JIT (#410) — see the definition in vm.c and
 * eigs_set_abort_flag in eigs_embed.h. NEVER NULL: unregistered points at
 * the always-zero sentinel below so both tiers poll with one deref. */
extern volatile int *g_vm_abort_flag;
extern volatile int g_vm_abort_never;

/* #292: sandbox allocation budget. Set by builtin_sandbox_run; size-controlled
 * allocators call sandbox_charge() before allocating. Returns 1 if the charge
 * fits (and commits it), 0 if it would exceed the budget (after raising a
 * catchable runtime_error). No-op when g_sandbox_active is 0.
 *
 * g_sandbox_active / _bytes_used / _byte_max are per-thread bridge macros in
 * eigenscript.h (#739): as process globals, two states running concurrently
 * (ext_http, one state per connection) shared one budget and one active
 * flag. */
int sandbox_charge(size_t bytes);

/* VM execution */
Value     *vm_execute(EigsChunk *chunk, Env *env);
/* #997: vm_execute with an explicit caller-supplied argument count, so an
 * under-arity entry from spawn / task_spawn / a builtin callback still lets
 * the callee's default-parameter prologue fire. vm_execute passes
 * chunk->param_count (every slot supplied), which is right for module-level
 * and handler entries and wrong for those three. */
Value     *vm_execute_argc(EigsChunk *chunk, Env *env, int call_argc);

/* Phase 5: free the per-thread VM struct. Called by eigs_thread_detach
 * so the heap-allocated VM (~1MB) doesn't leak. Safe on a thread whose
 * VM was never lazily initialized. */
struct EigsThread;
void       vm_thread_destroy(struct EigsThread *th);

/* Phase 9: zero the hot dict/loop-iter caches that stay __thread on
 * this OS thread, so a state attach on a recycled thread starts clean. */
void       vm_thread_reset_caches(void);

#endif /* EIGENSCRIPT_VM_H */
