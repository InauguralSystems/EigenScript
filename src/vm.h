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

/* ---- Opcodes ---- */
typedef enum {
    /* Constants */
    OP_CONST,           /* [idx:16] push constant pool entry */
    OP_NULL,            /* push null */
    OP_NUM_ZERO,        /* push 0.0 */
    OP_NUM_ONE,         /* push 1.0 */

    /* Arithmetic (pop 2, push 1) */
    OP_ADD,
    OP_SUB,
    OP_MUL,
    OP_DIV,
    OP_MOD,

    /* Bitwise (pop 2, push 1) */
    OP_BAND,
    OP_BOR,
    OP_BXOR,
    OP_SHL,
    OP_SHR,

    /* Unary (pop 1, push 1) */
    OP_NEG,
    OP_NOT,
    OP_BNOT,

    /* Comparison (pop 2, push 1) */
    OP_EQ,
    OP_NE,
    OP_LT,
    OP_GT,
    OP_LE,
    OP_GE,

    /* Variables */
    OP_GET_LOCAL,       /* [slot:16] push local from frame slot */
    OP_SET_LOCAL,       /* [slot:16] TOS -> local slot (keep on stack) */
    OP_GET_NAME,        /* [name_idx:16] dynamic lookup by name */
    OP_SET_NAME,        /* [name_idx:16] outward-assignment by name */
    OP_SET_NAME_LOCAL,  /* [name_idx:16] set in current scope only */
    OP_SET_FN_NAME_LOCAL, /* [name_idx:16] set in frame->fn_env (skips intervening loop/scope envs) */

    /* Control flow */
    OP_JUMP,            /* [offset:16] unconditional forward jump */
    OP_JUMP_BACK,       /* [offset:16] unconditional backward jump */
    OP_JUMP_IF_FALSE,   /* [offset:16] pop, jump if falsy */
    OP_JUMP_IF_TRUE,    /* [offset:16] pop, jump if truthy */
    OP_JUMP_IF_FALSE_PEEK, /* [offset:16] peek, jump if falsy (short-circuit and) */
    OP_JUMP_IF_TRUE_PEEK,  /* [offset:16] peek, jump if truthy (short-circuit or) */

    /* Stack manipulation */
    OP_POP,             /* discard TOS */
    OP_DUP,             /* duplicate TOS */
    OP_DUP2,            /* duplicate top two: a b → a b a b */

    /* Functions */
    OP_CLOSURE,         /* [fn_idx:16] create closure from compiled function */
    OP_CALL,            /* [argc:16] call function with argc args */
    OP_RETURN,          /* return TOS */
    OP_RETURN_NULL,     /* return null (implicit) */

    /* Data structures */
    OP_LIST,            /* [count:16] pop count items, push list */
    OP_DICT,            /* [count:16] pop count key-value pairs, push dict */
    OP_INDEX_GET,       /* pop index, pop target, push target[index] */
    OP_INDEX_SET,       /* pop value, pop index, pop target, set, push value */
    OP_DOT_GET,         /* [name_idx:16] pop target, push target.name */
    OP_DOT_SET,         /* [name_idx:16] pop value, pop target, set, push value */

    /* Loops and iteration */
    OP_ITER_SETUP,      /* pop iterable, push iterator state */
    OP_ITER_NEXT,       /* [exit_offset:16] advance or jump to exit */
    OP_LOOP_ENV_FRESH,  /* create fresh child env if current was captured by closure */
    OP_LOOP_ENV_END,    /* restore parent env from loop body env */
    OP_BREAK,           /* unwind to enclosing loop exit */
    OP_CONTINUE,        /* jump to enclosing loop header */

    /* Error handling */
    OP_TRY_BEGIN,       /* [catch_offset:16] push exception handler */
    OP_TRY_END,         /* pop exception handler */

    /* Observer system */
    OP_OBSERVE_ASSIGN,  /* [name_idx:16] observer update for assignment (env walk) */
    OP_OBSERVE_ASSIGN_LOCAL, /* [slot:16] observer update; prev value lives in fn_env slot */
    OP_INTERROGATE,     /* [kind:8] pop target, push query result */
    OP_PREDICATE,       /* [kind:8] push predicate result */
    OP_UNOBSERVED_BEGIN,/* increment g_unobserved_depth */
    OP_UNOBSERVED_END,  /* decrement g_unobserved_depth */
    OP_LOOP_STALL_CHECK,/* [exit_offset:16] observer-stall + iteration cap (observer-based loops) */
    OP_LOOP_CAP_CHECK,  /* [exit_offset:16] iteration cap ONLY (plain loops; no observer-stall) */

    /* Miscellaneous */
    OP_IMPORT,          /* [name_idx:16] import module, push dict */
    OP_MATCH,           /* [case_count:16] pattern match dispatch */
    OP_LISTCOMP_BEGIN,  /* push empty list accumulator */
    OP_LISTCOMP_APPEND, /* append TOS to accumulator */
    OP_LINE,            /* [line:16] update current line number */
    OP_WIDE,            /* next operand is 32-bit */
    OP_DISPATCH,        /* pop arg, key, table; call table[key](arg) inline */

    /* Superinstructions */
    OP_LOCAL_DOT_GET,   /* [slot:16][name_idx:16] push local[slot].name */
    OP_LOCAL_DOT_SET,   /* [slot:16][name_idx:16] TOS = local[slot].name = TOS */
    OP_LOCAL_IDX_GET,   /* [slot:16][idx:16] push local[slot][idx] */
    OP_LOCAL_IDX_DOT_GET, /* [slot:16][idx:16][name_idx:16] push local[slot][idx].name */
    OP_LOCAL_IDX_DOT_SET, /* [slot:16][idx:16][name_idx:16] local[slot][idx].name = TOS */
    OP_INTERROGATE_NAMED, /* [kind:16][name_idx:16] interrogate with known binding name */
    OP_INTERROGATE_NAMED_AT, /* [kind:16][name_idx:16] interrogate at line (popped from stack) */

    OP_DEFAULT_PARAM,   /* [slot:16][skip_off:16] if frame->call_argc > slot, IP += skip_off
                         * (skip the default expression); else fall through (default runs
                         * and ends with OP_SET_LOCAL <slot>; OP_POP). */
    OP_DESTRUCTURE_UNPACK, /* [n:16] pop list, raise if not VAL_LIST or length != n,
                            * else push elements onto stack in reverse so element 0 is TOS.
                            * Pairs with N assignment ops emitted after by the compiler. */
    OP_SLICE_GET,       /* pop 3 (end, start, target); push the slice of target from
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
    OP_REPORT_SLOT,     /* [slot:16] report-of-local via slot trajectory (compile-flag gated) */
    OP_OBSERVE_NAME_POST,/* [name_idx:16] slot-observe a name binding AFTER its SET
                          * (binding now exists), fixing the first-assignment lag.
                          * Emitted only under compile-time EIGS_OBS_SHADOW; peeks TOS. */
    OP_REPORT_NAME,     /* [name_idx:16] report of a non-local name: resolve (env,slot),
                          * classify its slot. Compile-flag gated. */
    OP_OBSERVE_VALUE_SLOT, /* [slot:16] `observe of <local>`: [status,entropy,dH,prev_dH]
                            * from the local's slot trajectory. Compile-flag gated. */
    OP_OBSERVE_VALUE_NAME, /* [name_idx:16] `observe of <name>`: same, resolving the
                            * binding's (env,slot). Compile-flag gated. */
    OP_LOOP_ENV_CLEAR,  /* reset a persisted loop env's bindings for a new iteration.
                         * Appended here (NOT mid-list) per the convention above —
                         * hand-built bytecode hardcodes opcode numbers. */
    OP_PREDICATE_SLOT,  /* [kind:16][slot:16] `<predicate> of <local>` — classify the
                         * named local's slot trajectory (not the global last-observed
                         * alias the bare OP_PREDICATE reads). Appended, not mid-list. */
    OP_PREDICATE_NAME,  /* [kind:16][name_idx:16] `<predicate> of <name>` — resolve the
                         * binding's (env,slot) and classify its slot trajectory. */
    OP_REPORT_VALUE_SLOT, /* [slot:16] `report_value of <local>` — classify the local's
                           * VALUE trajectory (#294), not its entropy. Appended, not mid-list. */
    OP_REPORT_VALUE_NAME, /* [name_idx:16] `report_value of <name>` — resolve the binding's
                           * (env,slot) and classify its value trajectory. */

    OP_COUNT            /* sentinel — number of opcodes */
} OpCode;

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
typedef struct EigsChunk {
    /* Lifetime: 1 creator ref (compile_ast caller, or the parent chunk's
     * functions[] slot for nested chunks) + 1 per live VAL_FN pointing at
     * this chunk (taken in OP_CLOSURE) + 1 per active call frame running
     * it. Atomic when g_vm_multithreaded, plain otherwise — same policy
     * as Value/env refcounts. */
    int      refcount;

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
typedef struct {
    EigsChunk *chunk;
    uint8_t   *ip;              /* instruction pointer */
    int        bp;              /* base pointer into value stack */
    Env       *env;             /* current env (may be loop-fresh child) */
    Env       *fn_env;          /* function's original env (for GET_LOCAL/SET_LOCAL) */
    Value     *closure_val;     /* the VAL_FN that was called */
    int        owns_env;        /* 1 if frame owns its env (free on return) */
    int        is_try;          /* 1 if any try handler active */
    /* Try handler stack (supports nested try/catch within a frame) */
    struct { uint8_t *catch_ip; int catch_bp; } try_handlers[8];
    int        try_count;       /* number of active try handlers */
    /* Saved loop-stall globals (so a callee's loops don't inherit caller's
     * accumulated stall count / iteration count). Scoped per call frame. */
    int        saved_stall_count;
    int        saved_loop_iter;
    int        call_argc;        /* args actually passed to this call; <= chunk->param_count.
                                  * Used by OP_DEFAULT_PARAM to decide if a slot was bound
                                  * by the caller or needs its default expression run. */
} CallFrame;

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
    /* Copying-stack save-buffer — valid only while TASK_SUSPENDED (1b). */
    EigsSlot  *saved_stack;
    int        saved_stack_len;
    struct CallFrame *saved_frames;
    int        saved_frame_count;
    int        saved_current_line;
    /* Completion. */
    Value     *result;             /* owned, deep-copied on normal end */
    int        has_error;          /* died of an uncaught error */
    Value     *error_value;        /* owned {kind,message,line} dict */
} Task;

/* Free a Task's held refs and the struct. Safe on any state; called by
 * handle_table_drain and (1b) by the scheduler on join/teardown. */
void task_free(Task *t);

/* ---- Public API ---- */

/* Chunk lifecycle */
EigsChunk *chunk_new(const char *name);
void       chunk_free(EigsChunk *chunk);   /* alias of chunk_decref */
void       chunk_incref(EigsChunk *chunk);
void       chunk_decref(EigsChunk *chunk);
int        chunk_add_constant(EigsChunk *chunk, Value *val);
void       chunk_emit(EigsChunk *chunk, uint8_t byte, int line);
void       chunk_emit_u16(EigsChunk *chunk, uint16_t val, int line);
int        chunk_emit_jump(EigsChunk *chunk, uint8_t op, int line);
void       chunk_patch_jump(EigsChunk *chunk, int offset);
int        chunk_add_function(EigsChunk *chunk, EigsChunk *fn);
void       chunk_scan_leaf_accessor(EigsChunk *chunk);  /* #366 */
void       chunk_disassemble(EigsChunk *chunk, const char *label);
const char *op_name(uint8_t op);
/* Verify an assembled (untrusted) chunk's bytecode is in-bounds before the VM
 * runs it. Returns 1 if safe to execute, 0 if it must be rejected. */
int        chunk_verify(EigsChunk *chunk);

/* Compiler */
EigsChunk *compile_ast(ASTNode *ast, Env *env);

/* Sandbox loop-iteration cap (0 = default 100M). Set by builtin_sandbox_run. */
extern int g_sandbox_loop_max;

/* Async abort seam: embedder-registered flag polled on every loop
 * back-edge — interpreter AND JIT (#410) — see the definition in vm.c and
 * eigs_set_abort_flag in eigs_embed.h. NEVER NULL: unregistered points at
 * the always-zero sentinel below so both tiers poll with one deref. */
extern volatile int *g_vm_abort_flag;
extern volatile int g_vm_abort_never;

/* #292: sandbox allocation budget. Set by builtin_sandbox_run; size-controlled
 * allocators call sandbox_charge() before allocating. Returns 1 if the charge
 * fits (and commits it), 0 if it would exceed the budget (after raising a
 * catchable runtime_error). No-op when g_sandbox_active is 0. */
extern int    g_sandbox_active;
extern size_t g_sandbox_bytes_used;
extern size_t g_sandbox_byte_max;
int sandbox_charge(size_t bytes);

/* VM execution */
Value     *vm_execute(EigsChunk *chunk, Env *env);

/* Phase 5: free the per-thread VM struct. Called by eigs_thread_detach
 * so the heap-allocated VM (~1MB) doesn't leak. Safe on a thread whose
 * VM was never lazily initialized. */
struct EigsThread;
void       vm_thread_destroy(struct EigsThread *th);

/* Phase 9: zero the hot dict/loop-iter caches that stay __thread on
 * this OS thread, so a state attach on a recycled thread starts clean. */
void       vm_thread_reset_caches(void);

#endif /* EIGENSCRIPT_VM_H */
