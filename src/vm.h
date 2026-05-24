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
    OP_OBSERVE_ASSIGN,  /* [name_idx:16] observer update for assignment */
    OP_INTERROGATE,     /* [kind:8] pop target, push query result */
    OP_PREDICATE,       /* [kind:8] push predicate result */
    OP_UNOBSERVED_BEGIN,/* increment g_unobserved_depth */
    OP_UNOBSERVED_END,  /* decrement g_unobserved_depth */
    OP_LOOP_STALL_CHECK,/* [exit_offset:16] stall detection for observer loops */

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
    uint8_t *code;              /* bytecode array */
    int      code_len;
    int      code_cap;

    Value  **constants;         /* constant pool */
    uint32_t *const_hashes;     /* cached hashes for string constants */
    char    **const_interns;    /* interned pointers for string constants (NULL for non-str) */
    EnvIC   *env_ic;            /* IC entry per string constant (zeroed = empty) */
    int      const_count;
    int      const_cap;

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

    /* Diagnostic: incremented on every frame entry (vm_run + both CALL
     * paths). Dumped at shutdown when EIGS_JIT_HOT=1 so we can correlate
     * chunk hotness with jit_state and the stop-opcode histogram. */
    uint64_t exec_count;
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
} CallFrame;

/* ---- VM State ---- */
#define VM_STACK_MAX  65536
#define VM_FRAMES_MAX 4096

typedef struct {
    EigsSlot   stack[VM_STACK_MAX];
    int        sp;
    CallFrame  frames[VM_FRAMES_MAX];
    int        frame_count;
    Env       *global_env;
    int        current_line;
} VM;

/* ---- Public API ---- */

/* Chunk lifecycle */
EigsChunk *chunk_new(const char *name);
void       chunk_free(EigsChunk *chunk);
int        chunk_add_constant(EigsChunk *chunk, Value *val);
void       chunk_emit(EigsChunk *chunk, uint8_t byte, int line);
void       chunk_emit_u16(EigsChunk *chunk, uint16_t val, int line);
int        chunk_emit_jump(EigsChunk *chunk, uint8_t op, int line);
void       chunk_patch_jump(EigsChunk *chunk, int offset);
int        chunk_add_function(EigsChunk *chunk, EigsChunk *fn);
void       chunk_disassemble(EigsChunk *chunk, const char *label);
const char *op_name(uint8_t op);

/* Compiler */
EigsChunk *compile_ast(ASTNode *ast, Env *env);

/* VM execution */
Value     *vm_execute(EigsChunk *chunk, Env *env);

#endif /* EIGENSCRIPT_VM_H */
