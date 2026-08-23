/* ================================================================
 * EigenScript Bytecode Compiler — AST to bytecode
 * ================================================================ */

#include "eigenscript.h"
#include "vm.h"
#include "trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !EIGENSCRIPT_FREESTANDING
/* NB: EIGENSCRIPT_FREESTANDING is always DEFINED (eigenscript.h defaults it to
 * 0), so this must test its VALUE. `#ifndef` here silently excluded both
 * headers and turned the muting below into a permanent no-op — see the
 * comment on obs_gate_mute_stderr. */
#include <unistd.h>     /* dup/dup2/close — #915's eager compile must be silent */
#include <fcntl.h>      /* open(/dev/null) */
#include <sys/stat.h>  /* stat/S_ISREG — reject a non-regular speculative target */
#endif

/* ---- Compiler state ---- */

#define MAX_LOCALS 512

typedef struct {
    char    *name;
    uint32_t hash;
    int      depth;     /* scope depth (0 = function-level) */
    int      slot;
    int      captured;
} Local;

typedef struct {
    int *break_jumps;   /* grown on demand — a fixed cap here once dropped the
                         * 65th break's jump while still emitting its env
                         * cleanup: double free (#335) */
    int  break_count;
    int  break_cap;
    int  continue_target;
    int  scope_depth;
    int  has_fresh_env; /* 1 if loop emits OP_LOOP_ENV_FRESH per iteration (for-loops) */
    int  unobs_depth_at_entry; /* #871: c->unobs_depth when the loop opened —
                              * break/continue leave every `unobserved:` block
                              * they jump out of, exactly as they leave `try`. */
    int  try_depth_at_entry; /* c->try_depth when the loop opened — break/continue
                              * must emit one OP_TRY_END per try block they jump
                              * out of, or the handler stays registered (#726) */
} LoopCtx;

/* Dynamic set of name pointers used for escape analysis & module-name tracking.
 * Strings are NOT owned (point into AST nodes); only the array is malloc'd. */
typedef struct {
    const char **names;
    int          count;
    int          cap;
    int         *index;      /* open addressing: slot -> names idx+1, 0=empty.
                              * The linear-scan dedup/lookup it replaces was
                              * the second quadratic compile cost on many-name
                              * programs (#341). */
    int          index_cap;  /* power of two; 0 until first add */
} NameSet;

typedef struct Compiler {
    EigsChunk        *chunk;
    struct Compiler  *enclosing;
    /* Heap-allocated MAX_LOCALS array (xcalloc'd right after each Compiler's
     * memset-init, freed in the same block's teardown). Inline it was 12 KiB
     * of struct — and compile_node_inner stack-declares a Compiler per nested
     * function, so the compile recursion cost ~12.7 KiB of C stack PER AST
     * LEVEL. Hosted (8 MB stacks) never noticed; on an embedded/kernel stack
     * (EigenOS boots on 64 KiB) a 5-deep AST overflowed and silently trampled
     * the neighboring sections — the mn-repl "#UD heisenbug". */
    Local            *locals;
    int               local_count;
    int               scope_depth;
    LoopCtx         **loops;        /* stack of heap-allocated ctxs; a pointer
                                     * array (not a LoopCtx array) so growth
                                     * can't dangle an outer loop's lp held
                                     * across compile_block (#336) */
    int               loop_depth;
    int               loop_cap;
    Env              *env;          /* for resolving globals at compile time */
    int               stack_depth;  /* tracked stack depth for validation */
    int               max_stack;    /* high-water mark */
    int               param_count;  /* number of function params (for local opt) */
    NameSet           captured;     /* names captured by nested closures (slow path) */
    NameSet           interrogated; /* names used in `who/when is x` (slow path for assign_counts) */
    NameSet           env_bound;    /* #633: names a listcomp var / `catch` name binds into the
                                     * env by name (OP_SET_NAME_LOCAL) in this scope. A same-named
                                     * plain `x is ...` must NOT slot-promote, or the slot and the
                                     * env binding diverge and a slot read returns a stale value. */
    NameSet          *module_names; /* root-compiler-owned: names defined at module scope */
    NameSet           module_slot_names; /* root-compiler-owned: names promoted to module slots */
    ASTNode          *root_ast;     /* root-compiler-owned: full AST for escape analysis */
    int               last_line;    /* #174: last OP_LINE value emitted; -1 = "next emit must
                                     * stamp the line". Reset at every basic-block boundary
                                     * (patch_jump targets, emit_loop, loop_start capture,
                                     * after CALL/DISPATCH/RETURN, fn entry). */
    int               dispatch_rebound; /* #459, root-computed and copied to fn
                                     * compilers: the unit binds `dispatch`
                                     * somewhere (any scope) or references
                                     * `eval`, so the OP_DISPATCH
                                     * superinstruction must not fire — the
                                     * normal name-call path honors the user
                                     * binding, and the builtin fallback is
                                     * semantically identical (fail-open). */
    int               unobs_depth;  /* #871: lexical `unobserved:` nesting here.
                                     * g_unobserved_depth is a runtime counter
                                     * that only UNOBSERVED_END decrements, so
                                     * every non-fallthrough exit must emit its
                                     * own — same disease as #726's try_depth. */
    int               try_depth;    /* #726: lexical `try` nesting at this point in
                                     * THIS function's body (a nested AST_FUNC gets
                                     * its own Compiler, so it restarts at 0 —
                                     * matching the per-CallFrame handler stack).
                                     * Drives the non-local-exit OP_TRY_END
                                     * unwinding and the MAX_TRY_HANDLERS cap. */
} Compiler;

int g_compile_module_slots = 0;

/* ---- NameSet helpers ---- */

static uint32_t name_set_hash(const char *name) {
    uint32_t h = 2166136261u;    /* FNV-1a */
    for (const char *p = name; *p; p++) {
        h ^= (unsigned char)*p;
        h *= 16777619u;
    }
    return h;
}

static void name_set_index_insert(NameSet *s, uint32_t h, int idx) {
    uint32_t mask = (uint32_t)s->index_cap - 1;
    uint32_t slot = h & mask;
    while (s->index[slot]) slot = (slot + 1) & mask;
    s->index[slot] = idx + 1;
}

static void name_set_index_grow(NameSet *s) {
    int new_cap = s->index_cap ? s->index_cap * 2 : 16;
    free(s->index);
    s->index = xcalloc(new_cap, sizeof(int));
    s->index_cap = new_cap;
    for (int i = 0; i < s->count; i++)
        name_set_index_insert(s, name_set_hash(s->names[i]), i);
}

static int name_set_has(const NameSet *s, const char *name) {
    if (!s || s->count == 0) return 0;
    uint32_t mask = (uint32_t)s->index_cap - 1;
    uint32_t slot = name_set_hash(name) & mask;
    while (s->index[slot]) {
        const char *have = s->names[s->index[slot] - 1];
        if (have == name || strcmp(have, name) == 0) return 1;
        slot = (slot + 1) & mask;
    }
    return 0;
}

static void name_set_add(NameSet *s, const char *name) {
    if (!name) return;
    if ((s->count + 1) * 2 > s->index_cap) name_set_index_grow(s);
    if (name_set_has(s, name)) return;
    if (s->count >= s->cap) {
        s->cap = s->cap ? s->cap * 2 : 8;
        s->names = realloc(s->names, s->cap * sizeof(const char *));
    }
    name_set_index_insert(s, name_set_hash(name), s->count);
    s->names[s->count++] = name;
}

static void name_set_free(NameSet *s) {
    free(s->names);
    s->names = NULL;
    free(s->index);
    s->index = NULL;
    s->count = s->cap = s->index_cap = 0;
}

/* Swap-remove + index rebuild. The removal sites (param filtering) used
 * to swap entries directly, which is fine for a linear array but stales
 * the hash index. These sets are tiny (a function's captured names), so
 * the rebuild is cheap. */
static void name_set_remove(NameSet *s, const char *name) {
    for (int i = 0; i < s->count; i++) {
        if (s->names[i] == name || strcmp(s->names[i], name) == 0) {
            s->names[i] = s->names[--s->count];
            memset(s->index, 0, s->index_cap * sizeof(int));
            for (int k = 0; k < s->count; k++)
                name_set_index_insert(s, name_set_hash(s->names[k]), k);
            return;
        }
    }
}

/* ---- Forward declarations ---- */
static void compile_node(Compiler *c, ASTNode *node);
static void compile_node_inner(Compiler *c, ASTNode *node);
static void compile_block(Compiler *c, ASTNode **stmts, int count);
static void check_discarded_interrogative(ASTNode *stmt);   /* #869 */

/* ---- Loop-context stack (#335/#336) ----
 * Push/pop are strictly balanced within each AST_LOOP/AST_FOR case, so the
 * stack frees itself when the outermost loop pops — no compiler-teardown
 * hook needed. */
static LoopCtx *loop_push(Compiler *c) {
    if (c->loop_depth == c->loop_cap) {
        c->loop_cap = c->loop_cap ? c->loop_cap * 2 : 8;
        c->loops = xrealloc_array(c->loops, c->loop_cap, sizeof(LoopCtx*));
    }
    LoopCtx *lp = xcalloc(1, sizeof(LoopCtx));
    lp->try_depth_at_entry = c->try_depth;
    lp->unobs_depth_at_entry = c->unobs_depth;
    c->loops[c->loop_depth++] = lp;
    return lp;
}

static void loop_pop(Compiler *c) {
    LoopCtx *lp = c->loops[--c->loop_depth];
    free(lp->break_jumps);
    free(lp);
    if (c->loop_depth == 0) {
        free(c->loops);
        c->loops = NULL;
        c->loop_cap = 0;
    }
}

static void loop_add_break(LoopCtx *lp, int jump_offset) {
    if (lp->break_count == lp->break_cap) {
        lp->break_cap = lp->break_cap ? lp->break_cap * 2 : 8;
        lp->break_jumps = xrealloc_array(lp->break_jumps, lp->break_cap, sizeof(int));
    }
    lp->break_jumps[lp->break_count++] = jump_offset;
}

/* Cap the compiler's recursion depth over the AST. The walk overflows the C
 * stack on a pathological tree — a long postfix `a[0][0]…` or left-assoc binop
 * `1+1+…` chain, which the parser builds iteratively and so the parse-depth
 * guard never sees. compile_node sees the *combined* depth (nesting + chains),
 * so one bound here covers every shape. Kept well below the worst-case
 * (-O0 + AddressSanitizer) ~180-frame stack-overflow point measured locally,
 * and far above any real expression depth. Reuses the per-thread parse_depth
 * counter (0 once parsing has finished). */
#define COMPILE_MAX_DEPTH 128

/* ---- Stack depth tracking ---- */

static void adjust_stack(Compiler *c, int delta) {
    c->stack_depth += delta;
    if (c->stack_depth > c->max_stack)
        c->max_stack = c->stack_depth;
    if (c->stack_depth < 0) {
        fprintf(stderr, "[compiler] stack underflow at bytecode offset %d (depth=%d)\n",
                c->chunk->code_len, c->stack_depth);
        c->stack_depth = 0;
    }
}

/* ---- Emit helpers ---- */

/* Stack effect of each opcode.
 * #737: exhaustive switch on OpCode, NO default arm — -Werror=switch
 * makes a new opcode a build error here instead of a silent depth-0
 * assumption (a wrong depth surfaces as stack corruption far from the
 * cause). Dynamic-effect opcodes are listed explicitly and return 0;
 * their emit sites adjust the depth with the real operand. */
static int op_stack_effect(uint8_t op8) {
    switch ((OpCode)op8) {
    /* Push 1 */
    case OP_CONST: case OP_NULL: case OP_NUM_ZERO: case OP_NUM_ONE:
    case OP_GET_LOCAL: case OP_GET_NAME: case OP_DUP:
    case OP_PREDICATE: case OP_LISTCOMP_BEGIN:
    case OP_REPORT_SLOT: case OP_REPORT_NAME:
    case OP_REPORT_VALUE_SLOT: case OP_REPORT_VALUE_NAME:
    case OP_TRAJECTORY_SLOT: case OP_TRAJECTORY_NAME:
    case OP_OBSERVE_VALUE_SLOT: case OP_OBSERVE_VALUE_NAME:
    case OP_PREDICATE_SLOT: case OP_PREDICATE_NAME:
        return 1;
    /* Push 2 */
    case OP_DUP2:
        return 2;
    /* Pop 1 */
    case OP_POP:
        return -1;
    /* Pop 2, push 1 = net -1 */
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
    case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
    case OP_EQ: case OP_NE: case OP_LT: case OP_GT: case OP_LE: case OP_GE:
    case OP_INDEX_GET:
        return -1;
    /* Pop 1, push 1 = net 0 */
    case OP_NEG: case OP_NOT: case OP_BNOT:
    case OP_INTERROGATE:
        return 0;
    /* SET: peek, no change */
    case OP_SET_LOCAL: case OP_SET_NAME: case OP_SET_NAME_LOCAL:
    case OP_SET_FN_NAME_LOCAL:
    case OP_OBSERVE_ASSIGN: case OP_OBSERVE_ASSIGN_LOCAL:
    case OP_OBSERVE_NAME_POST:   /* #262 Phase-3: peeks TOS, no stack change */
        return 0;
    /* Jumps: conditional pops 1, unconditional 0, peek 0 */
    case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE:
        return -1;
    case OP_JUMP: case OP_JUMP_BACK:
    case OP_JUMP_IF_FALSE_PEEK: case OP_JUMP_IF_TRUE_PEEK:
        return 0;
    /* Dot: pop target push result = 0 */
    case OP_DOT_GET:
        return 0;
    /* Dot set: pop value, pop target, push value = -1 */
    case OP_DOT_SET:
        return -1;
    /* Superinstructions */
    case OP_LOCAL_DOT_GET:  /* push result = +1 */
        return 1;
    case OP_LOCAL_DOT_SET:  /* peek TOS, write to local.field = 0 */
        return 0;
    case OP_LOCAL_IDX_GET:  /* push result = +1 */
        return 1;
    case OP_LOCAL_IDX_DOT_GET:  /* push result = +1 */
        return 1;
    case OP_LOCAL_IDX_DOT_SET:  /* peek TOS, write = 0 */
        return 0;
    case OP_INTERROGATE_NAMED:  /* pop 1, push 1 = 0 */
    case OP_INTERROGATE_NAMED_WHEN: /* pop ordinal, push result = 0 */
    case OP_INTERROGATE_NAMED_AT:  /* pop line, push result = 0 */
        return 0;
    case OP_DEFAULT_PARAM:  /* conditional skip — no stack change */
        return 0;
    case OP_DESTRUCTURE_UNPACK:  /* dynamic: -1 + n; caller adjusts directly */
        return 0;
    case OP_SLICE_GET:  /* pop end, start, target; push slice = -2 */
        return -2;
    /* Index set: pop value, pop index, pop target, push value = -2 */
    case OP_INDEX_SET:
        return -2;
    /* Return: special */
    case OP_RETURN: case OP_RETURN_NULL:
        return 0;
    /* Loop env: no stack change */
    case OP_LOOP_ENV_FRESH: case OP_LOOP_ENV_END: case OP_LOOP_ENV_CLEAR:
        return 0;
    /* Iterator: SETUP pops iterable pushes state = 0; NEXT pushes elem = +1 */
    case OP_ITER_SETUP:
        return 0;
    case OP_ITER_NEXT:
        return 1; /* on non-exit path */
    /* Try: no stack change */
    case OP_TRY_BEGIN: case OP_TRY_END:
        return 0;
    /* Loop guards: exit-jump only, no stack change. (#737: these two fell
     * through the old default arm — right answer, by accident.) */
    case OP_LOOP_STALL_CHECK: case OP_LOOP_CAP_CHECK:
        return 0;
    /* Observer blocks: no stack change */
    case OP_UNOBSERVED_BEGIN: case OP_UNOBSERVED_END:
        return 0;
    /* Line: no stack change */
    case OP_LINE:
        return 0;
    /* Break/continue: no stack change (compiler emits as jumps) */
    case OP_BREAK: case OP_CONTINUE:
        return 0;
    /* Closure: pushes 1 */
    case OP_CLOSURE:
        return 1;
    /* LISTCOMP_APPEND: pops 1 */
    case OP_LISTCOMP_APPEND:
        return -1;
    /* IMPORT: pushes 1 */
    case OP_IMPORT:
        return 1;
    /* DISPATCH: pop 3 (table, key, arg), push 1 = -2 */
    case OP_DISPATCH:
        return -2;
    /* Dynamic — the emit site adjusts by the real operand count. */
    case OP_CALL:    /* pops argc + fn, pushes result */
    case OP_LIST:    /* pops count, pushes list */
    case OP_DICT:    /* pops 2*count, pushes dict */
    case OP_MATCH:   /* dispatch; compiled arms manage their own depth */
        return 0;
    case OP_WIDE:    /* placeholder — never emitted */
        return 0;
    case OP_COUNT:   /* sentinel — never emitted */
        return 0;
    }
    return 0;   /* unreachable */
}

static void emit(Compiler *c, uint8_t op, int line) {
    chunk_emit(c->chunk, op, line);
    adjust_stack(c, op_stack_effect(op));
}

static void emit_op_u16(Compiler *c, uint8_t op, uint16_t arg, int line) {
    chunk_emit(c->chunk, op, line);
    chunk_emit_u16(c->chunk, arg, line);
    adjust_stack(c, op_stack_effect(op));
}

/* #630: 32-bit operand form (OP_LINE only). */
static void emit_op_u32(Compiler *c, uint8_t op, uint32_t arg, int line) {
    chunk_emit(c->chunk, op, line);
    chunk_emit_u32(c->chunk, arg, line);
    adjust_stack(c, op_stack_effect(op));
}

static void emit_op_u16_u16(Compiler *c, uint8_t op, uint16_t arg1, uint16_t arg2, int line) {
    chunk_emit(c->chunk, op, line);
    chunk_emit_u16(c->chunk, arg1, line);
    chunk_emit_u16(c->chunk, arg2, line);
    adjust_stack(c, op_stack_effect(op));
}

static void emit_op_u16_u16_u16(Compiler *c, uint8_t op, uint16_t a1, uint16_t a2, uint16_t a3, int line) {
    chunk_emit(c->chunk, op, line);
    chunk_emit_u16(c->chunk, a1, line);
    chunk_emit_u16(c->chunk, a2, line);
    chunk_emit_u16(c->chunk, a3, line);
    adjust_stack(c, op_stack_effect(op));
}

static void emit_call(Compiler *c, uint16_t argc, int line) {
    chunk_emit(c->chunk, OP_CALL, line);
    chunk_emit_u16(c->chunk, argc, line);
    /* CALL pops fn + argc args, pushes result = -(argc+1) + 1 = -argc */
    adjust_stack(c, -(int)argc);
    /* #174: the callee runs its own OP_LINE stream, leaving the VM's
     * current_line on whatever it returned from. The next instruction
     * here must restamp. */
    c->last_line = -1;
}

static void emit_list(Compiler *c, uint16_t count, int line) {
    chunk_emit(c->chunk, OP_LIST, line);
    chunk_emit_u16(c->chunk, count, line);
    /* LIST pops count items, pushes list = -(count) + 1 = -(count-1) */
    adjust_stack(c, -(int)count + 1);
}

static void emit_dict(Compiler *c, uint16_t count, int line) {
    chunk_emit(c->chunk, OP_DICT, line);
    chunk_emit_u16(c->chunk, count, line);
    /* DICT pops count*2 items (keys+values), pushes dict */
    adjust_stack(c, -(int)count * 2 + 1);
}

static int emit_jump(Compiler *c, uint8_t op, int line) {
    chunk_emit(c->chunk, op, line);
    adjust_stack(c, op_stack_effect(op));
    int patch = c->chunk->code_len;
    chunk_emit_u16(c->chunk, 0xFFFF, line);
    return patch;
}

static void patch_jump(Compiler *c, int offset) {
    chunk_patch_jump(c->chunk, offset);
    /* #174: the next emit lands at the jump target — control may arrive
     * from either fall-through or this jump, so the runtime current_line
     * could be anything. Force the next OP_LINE through. */
    c->last_line = -1;
}

static void emit_loop(Compiler *c, int loop_start, int line) {
    chunk_emit(c->chunk, OP_JUMP_BACK, line);
    int offset = c->chunk->code_len - loop_start + 2;
    if (offset > 0xFFFF) {
        /* Back-edge too far for a u16 operand. The old code silently
         * truncated it (wrong back-jump → corrupt control flow). Flag the
         * error and clamp to an in-bounds 0 so nothing executes a wild jump. */
        fprintf(stderr,
                "Compile error line %d: bytecode loop offset too large\n",
                line);
        g_parse_errors++;
        offset = 0;
    }
    chunk_emit_u16(c->chunk, (uint16_t)offset, line);
    /* #174: the next emit is past the back-jump; the loop's exit edge
     * lands either here (fall-through after a false condition) or via
     * a patched forward jump. Both are merge points. */
    c->last_line = -1;
}

/* #174: capture loop_start. The bytecode emitted next is a back-edge
 * target, so future iterations re-enter with the previous iteration's
 * current_line state. Reset so the first instruction at loop_start
 * stamps the line. */
static int capture_loop_start(Compiler *c) {
    c->last_line = -1;
    return c->chunk->code_len;
}

/* #174: dedup OP_LINE emission. Per-AST-node line stamps spammed the
 * dispatch loop with redundant updates (most child nodes share their
 * parent's line). Emit only when the line changes; reset at every
 * basic-block boundary so we never *skip* a stamp the runtime needs. */
static void emit_line(Compiler *c, int line) {
    if (c->last_line == line) return;
    emit_op_u32(c, OP_LINE, (uint32_t)line, line);   /* #630: 32-bit — was (uint16_t), wrapped past line 65535 */
    c->last_line = line;
}

/* ---- Constant helpers ---- */

/* u16 operand ceiling: constant indices are encoded as 16-bit operands
 * everywhere (OP_CONST, the name ops, ...). Past 65535 the (uint16_t)
 * cast at the emit sites silently wrapped — a SET_NAME operand landing
 * on a NUM constant made const_interns[idx] NULL and env_hash_name
 * crashed (found via #341's cap removals). A chunk needing more
 * constants is a compile error, not a wrap. */
static int check_const_index(int idx) {
    if (idx > 0xFFFF) {
        /* Report once (the first index past the line is exactly 0x10000 —
         * dedup returns only existing indices below it); count every
         * occurrence so the post-compile gate always aborts. */
        if (idx == 0x10000) {
            fprintf(stderr, "Compile error: constant pool exceeds 65536 entries in one chunk\n");
            eigs_record_first_error(0, "constant pool exceeds 65536 entries in one chunk");
        }
        g_parse_errors++;
        return 0;   /* in-bounds placeholder; the post-compile gate aborts */
    }
    return idx;
}

static int add_string_constant(Compiler *c, const char *str) {
    Value *v = make_str(str);
    int idx = chunk_add_constant(c->chunk, v);
    val_decref(v);
    return check_const_index(idx);
}

static int add_num_constant(Compiler *c, double num) {
    Value *v = make_num(num);
    int idx = chunk_add_constant(c->chunk, v);
    val_decref(v);
    return check_const_index(idx);
}

/* ---- Local variable tracking ---- */

static int resolve_local(Compiler *c, const char *name, uint32_t hash) {
    for (int i = c->local_count - 1; i >= 0; i--) {
        if (c->locals[i].hash == hash && strcmp(c->locals[i].name, name) == 0)
            return c->locals[i].slot;
    }
    return -1;
}

/* #895: slot resolution for the observer call-forms whose operand is a bare
 * name — `report of x`, `report_value of x`, `trajectory of x`, `observe of x`,
 * `<predicate> of x`. Each picks a *_SLOT opcode when the name is a frame slot
 * and a *_NAME opcode otherwise, and each used to ask for the slot only inside
 * a function (`c->enclosing`). At module scope that is wrong for exactly the
 * names an `unobserved:` block promotes to module slots (Part B): the binding
 * is a slot, so the *_NAME opcode's env lookup finds nothing and the form
 * raised `undefined variable` for a name a plain read of resolves two lines
 * later. Mirrors the AST_IDENT read path — module scope resolves a slot only
 * for a promoted name, so an ordinary module binding still takes *_NAME. */
static int resolve_observer_operand_slot(Compiler *c, ASTNode *id) {
    const char *name = id->data.ident.name;
    if (!c->enclosing && !name_set_has(&c->module_slot_names, name)) return -1;
    uint32_t h = id->name_hash ? id->name_hash : env_hash_name(name);
    return resolve_local(c, name, h);
}

static int add_local(Compiler *c, const char *name, uint32_t hash) {
    if (c->local_count >= MAX_LOCALS) return -1;
    int slot = c->local_count;
    c->locals[slot].name = (char *)name;
    c->locals[slot].hash = hash;
    c->locals[slot].depth = c->scope_depth;
    c->locals[slot].slot = slot;
    c->locals[slot].captured = 0;
    c->local_count++;
    return slot;
}

/* ---- Binary operator mapping ---- */

static uint8_t binop_to_opcode(const char *op) {
    if (op[0] == '+' && op[1] == 0) return OP_ADD;
    if (op[0] == '-' && op[1] == 0) return OP_SUB;
    if (op[0] == '*' && op[1] == 0) return OP_MUL;
    if (op[0] == '/' && op[1] == 0) return OP_DIV;
    if (op[0] == '%' && op[1] == 0) return OP_MOD;
    if (op[0] == '&' && op[1] == 0) return OP_BAND;
    if (op[0] == '|' && op[1] == 0) return OP_BOR;
    if (op[0] == '^' && op[1] == 0) return OP_BXOR;
    if (op[0] == '<' && op[1] == '<') return OP_SHL;
    if (op[0] == '>' && op[1] == '>') return OP_SHR;
    if (op[0] == '<' && op[1] == 0) return OP_LT;
    if (op[0] == '>' && op[1] == 0) return OP_GT;
    if (op[0] == '<' && op[1] == '=') return OP_LE;
    if (op[0] == '>' && op[1] == '=') return OP_GE;
    if (op[0] == '=' && op[1] == 0) return OP_EQ;
    if (op[0] == '!' && op[1] == '=') return OP_NE;
    return 0;
}

/* ---- AST walkers for escape analysis ---- */

/* Forward decl */
static void collect_referenced_names(ASTNode *node, NameSet *out);

/* Like collect_referenced_names, but skips the subtree rooted at `skip` (pointer
 * comparison). Used by module-slot escape analysis to find names referenced
 * OUTSIDE a particular unobserved block. */
static void collect_referenced_names_skip(ASTNode *node, ASTNode *skip, NameSet *out) {
    if (!node || node == skip) return;
    switch (node->type) {
    case AST_IDENT:
        name_set_add(out, node->data.ident.name);
        break;
    case AST_ASSIGN:
        name_set_add(out, node->data.assign.name);
        collect_referenced_names_skip(node->data.assign.expr, skip, out);
        break;
    case AST_BINOP:
        collect_referenced_names_skip(node->data.binop.left, skip, out);
        collect_referenced_names_skip(node->data.binop.right, skip, out);
        break;
    case AST_UNARY:
        collect_referenced_names_skip(node->data.unary.operand, skip, out);
        break;
    case AST_RELATION:
        collect_referenced_names_skip(node->data.relation.left, skip, out);
        collect_referenced_names_skip(node->data.relation.right, skip, out);
        break;
    case AST_IF:
        collect_referenced_names_skip(node->data.cond.cond, skip, out);
        for (int i = 0; i < node->data.cond.if_count; i++)
            collect_referenced_names_skip(node->data.cond.if_body[i], skip, out);
        for (int i = 0; i < node->data.cond.else_count; i++)
            collect_referenced_names_skip(node->data.cond.else_body[i], skip, out);
        break;
    case AST_LOOP:
        collect_referenced_names_skip(node->data.loop.cond, skip, out);
        for (int i = 0; i < node->data.loop.body_count; i++)
            collect_referenced_names_skip(node->data.loop.body[i], skip, out);
        break;
    case AST_RETURN:
        collect_referenced_names_skip(node->data.ret.expr, skip, out);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < node->data.block.count; i++)
            collect_referenced_names_skip(node->data.block.stmts[i], skip, out);
        break;
    case AST_LIST:
        for (int i = 0; i < node->data.list.count; i++)
            collect_referenced_names_skip(node->data.list.elems[i], skip, out);
        break;
    case AST_INDEX:
        collect_referenced_names_skip(node->data.index.target, skip, out);
        collect_referenced_names_skip(node->data.index.index, skip, out);
        break;
    case AST_LISTCOMP:
        collect_referenced_names_skip(node->data.listcomp.expr, skip, out);
        collect_referenced_names_skip(node->data.listcomp.iter, skip, out);
        collect_referenced_names_skip(node->data.listcomp.filter, skip, out);
        break;
    case AST_FOR:
        name_set_add(out, node->data.forloop.var);
        collect_referenced_names_skip(node->data.forloop.iter, skip, out);
        for (int i = 0; i < node->data.forloop.body_count; i++)
            collect_referenced_names_skip(node->data.forloop.body[i], skip, out);
        break;
    case AST_FUNC:
        name_set_add(out, node->data.func.name);
        for (int i = 0; i < node->data.func.body_count; i++)
            collect_referenced_names_skip(node->data.func.body[i], skip, out);
        break;
    case AST_LAMBDA:
        collect_referenced_names_skip(node->data.lambda.body, skip, out);
        break;
    case AST_INTERROGATE:
        collect_referenced_names_skip(node->data.interrogate.expr, skip, out);
        if (node->data.interrogate.at_expr)
            collect_referenced_names_skip(node->data.interrogate.at_expr, skip, out);
        if (node->data.interrogate.when_expr)
            collect_referenced_names_skip(node->data.interrogate.when_expr, skip, out);
        break;
    case AST_TRY:
        for (int i = 0; i < node->data.trycatch.try_count; i++)
            collect_referenced_names_skip(node->data.trycatch.try_body[i], skip, out);
        if (node->data.trycatch.err_name) name_set_add(out, node->data.trycatch.err_name);
        for (int i = 0; i < node->data.trycatch.catch_count; i++)
            collect_referenced_names_skip(node->data.trycatch.catch_body[i], skip, out);
        break;
    case AST_DICT:
        for (int i = 0; i < node->data.dict.count; i++) {
            collect_referenced_names_skip(node->data.dict.keys[i], skip, out);
            collect_referenced_names_skip(node->data.dict.vals[i], skip, out);
        }
        break;
    case AST_DOT:
        collect_referenced_names_skip(node->data.dot.target, skip, out);
        break;
    case AST_DOT_ASSIGN:
        collect_referenced_names_skip(node->data.dot_assign.target, skip, out);
        collect_referenced_names_skip(node->data.dot_assign.expr, skip, out);
        break;
    case AST_INDEX_ASSIGN:
        collect_referenced_names_skip(node->data.index_assign.target, skip, out);
        collect_referenced_names_skip(node->data.index_assign.index, skip, out);
        collect_referenced_names_skip(node->data.index_assign.expr, skip, out);
        break;
    case AST_MATCH:
        collect_referenced_names_skip(node->data.match.expr, skip, out);
        for (int i = 0; i < node->data.match.case_count; i++) {
            collect_referenced_names_skip(node->data.match.patterns[i], skip, out);
            for (int j = 0; j < node->data.match.body_counts[i]; j++)
                collect_referenced_names_skip(node->data.match.bodies[i][j], skip, out);
        }
        break;
    case AST_LIST_PATTERN_ASSIGN:
        for (int i = 0; i < node->data.list_pattern_assign.name_count; i++)
            name_set_add(out, node->data.list_pattern_assign.names[i]);
        collect_referenced_names_skip(node->data.list_pattern_assign.expr, skip, out);
        break;
    case AST_SLICE:
        collect_referenced_names_skip(node->data.slice.target, skip, out);
        collect_referenced_names_skip(node->data.slice.start, skip, out);
        collect_referenced_names_skip(node->data.slice.end, skip, out);
        break;
    case AST_PROGRAM:
        for (int i = 0; i < node->data.program.count; i++)
            collect_referenced_names_skip(node->data.program.stmts[i], skip, out);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_NULL:
    case AST_PREDICATE:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_IMPORT:
        break;
    }
}

/* Collect every identifier referenced anywhere in a subtree (transitively, including
 * inside nested closures). Used to determine which outer names a closure captures.
 * Does NOT track shadowing by deeper nested locals — conservative over-collection. */
static void collect_referenced_names(ASTNode *node, NameSet *out) {
    if (!node) return;
    switch (node->type) {
    case AST_IDENT:
        name_set_add(out, node->data.ident.name);
        break;
    case AST_ASSIGN:
        name_set_add(out, node->data.assign.name);
        collect_referenced_names(node->data.assign.expr, out);
        break;
    case AST_BINOP:
        collect_referenced_names(node->data.binop.left, out);
        collect_referenced_names(node->data.binop.right, out);
        break;
    case AST_UNARY:
        collect_referenced_names(node->data.unary.operand, out);
        break;
    case AST_RELATION:
        collect_referenced_names(node->data.relation.left, out);
        collect_referenced_names(node->data.relation.right, out);
        break;
    case AST_IF:
        collect_referenced_names(node->data.cond.cond, out);
        for (int i = 0; i < node->data.cond.if_count; i++)
            collect_referenced_names(node->data.cond.if_body[i], out);
        for (int i = 0; i < node->data.cond.else_count; i++)
            collect_referenced_names(node->data.cond.else_body[i], out);
        break;
    case AST_LOOP:
        collect_referenced_names(node->data.loop.cond, out);
        for (int i = 0; i < node->data.loop.body_count; i++)
            collect_referenced_names(node->data.loop.body[i], out);
        break;
    case AST_RETURN:
        collect_referenced_names(node->data.ret.expr, out);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < node->data.block.count; i++)
            collect_referenced_names(node->data.block.stmts[i], out);
        break;
    case AST_LIST:
        for (int i = 0; i < node->data.list.count; i++)
            collect_referenced_names(node->data.list.elems[i], out);
        break;
    case AST_INDEX:
        collect_referenced_names(node->data.index.target, out);
        collect_referenced_names(node->data.index.index, out);
        break;
    case AST_LISTCOMP:
        collect_referenced_names(node->data.listcomp.expr, out);
        collect_referenced_names(node->data.listcomp.iter, out);
        collect_referenced_names(node->data.listcomp.filter, out);
        break;
    case AST_FOR:
        name_set_add(out, node->data.forloop.var);
        collect_referenced_names(node->data.forloop.iter, out);
        for (int i = 0; i < node->data.forloop.body_count; i++)
            collect_referenced_names(node->data.forloop.body[i], out);
        break;
    case AST_FUNC:
        /* Nested function — recurse into its body. The function's own name and
         * params will be filtered out by the caller when needed. */
        name_set_add(out, node->data.func.name);
        for (int i = 0; i < node->data.func.body_count; i++)
            collect_referenced_names(node->data.func.body[i], out);
        break;
    case AST_LAMBDA:
        collect_referenced_names(node->data.lambda.body, out);
        break;
    case AST_INTERROGATE:
        collect_referenced_names(node->data.interrogate.expr, out);
        if (node->data.interrogate.at_expr)
            collect_referenced_names(node->data.interrogate.at_expr, out);
        if (node->data.interrogate.when_expr)
            collect_referenced_names(node->data.interrogate.when_expr, out);
        break;
    case AST_PREDICATE:
        /* PREDICATE uses similar shape to relation/interrogate; descend on whatever lives in it */
        break;
    case AST_TRY:
        for (int i = 0; i < node->data.trycatch.try_count; i++)
            collect_referenced_names(node->data.trycatch.try_body[i], out);
        if (node->data.trycatch.err_name) name_set_add(out, node->data.trycatch.err_name);
        for (int i = 0; i < node->data.trycatch.catch_count; i++)
            collect_referenced_names(node->data.trycatch.catch_body[i], out);
        break;
    case AST_DICT:
        for (int i = 0; i < node->data.dict.count; i++) {
            collect_referenced_names(node->data.dict.keys[i], out);
            collect_referenced_names(node->data.dict.vals[i], out);
        }
        break;
    case AST_DOT:
        collect_referenced_names(node->data.dot.target, out);
        break;
    case AST_DOT_ASSIGN:
        collect_referenced_names(node->data.dot_assign.target, out);
        collect_referenced_names(node->data.dot_assign.expr, out);
        break;
    case AST_INDEX_ASSIGN:
        collect_referenced_names(node->data.index_assign.target, out);
        collect_referenced_names(node->data.index_assign.index, out);
        collect_referenced_names(node->data.index_assign.expr, out);
        break;
    case AST_MATCH:
        collect_referenced_names(node->data.match.expr, out);
        for (int i = 0; i < node->data.match.case_count; i++) {
            collect_referenced_names(node->data.match.patterns[i], out);
            for (int j = 0; j < node->data.match.body_counts[i]; j++)
                collect_referenced_names(node->data.match.bodies[i][j], out);
        }
        break;
    case AST_LIST_PATTERN_ASSIGN:
        for (int i = 0; i < node->data.list_pattern_assign.name_count; i++)
            name_set_add(out, node->data.list_pattern_assign.names[i]);
        collect_referenced_names(node->data.list_pattern_assign.expr, out);
        break;
    case AST_SLICE:
        collect_referenced_names(node->data.slice.target, out);
        collect_referenced_names(node->data.slice.start, out);
        collect_referenced_names(node->data.slice.end, out);
        break;
    case AST_PROGRAM:
        for (int i = 0; i < node->data.program.count; i++)
            collect_referenced_names(node->data.program.stmts[i], out);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_NULL:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_IMPORT:
        break;
    }
}

/* Walk a function body looking for nested closures. For each one found,
 * collect names it references that aren't its own params — those are captures
 * of our scope. Used so the outer function can mark matching locals as captured. */
static void scan_for_captures(ASTNode *node, NameSet *out) {
    if (!node) return;
    switch (node->type) {
    case AST_FUNC: {
        NameSet inner = {0};
        for (int i = 0; i < node->data.func.body_count; i++)
            collect_referenced_names(node->data.func.body[i], &inner);
        /* Filter out the closure's own params */
        for (int i = 0; i < inner.count; i++) {
            int shadowed = 0;
            for (int j = 0; j < node->data.func.param_count; j++) {
                if (strcmp(inner.names[i], node->data.func.params[j]) == 0) {
                    shadowed = 1; break;
                }
            }
            if (!shadowed) name_set_add(out, inner.names[i]);
        }
        name_set_free(&inner);
        break;
    }
    case AST_LAMBDA: {
        NameSet inner = {0};
        collect_referenced_names(node->data.lambda.body, &inner);
        for (int i = 0; i < inner.count; i++) {
            int shadowed = 0;
            for (int j = 0; j < node->data.lambda.param_count; j++) {
                if (strcmp(inner.names[i], node->data.lambda.params[j]) == 0) {
                    shadowed = 1; break;
                }
            }
            if (!shadowed) name_set_add(out, inner.names[i]);
        }
        name_set_free(&inner);
        break;
    }
    /* Descend through control flow / blocks to find nested closures */
    case AST_IF:
        for (int i = 0; i < node->data.cond.if_count; i++)
            scan_for_captures(node->data.cond.if_body[i], out);
        for (int i = 0; i < node->data.cond.else_count; i++)
            scan_for_captures(node->data.cond.else_body[i], out);
        break;
    case AST_LOOP:
        for (int i = 0; i < node->data.loop.body_count; i++)
            scan_for_captures(node->data.loop.body[i], out);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < node->data.block.count; i++)
            scan_for_captures(node->data.block.stmts[i], out);
        break;
    case AST_FOR:
        for (int i = 0; i < node->data.forloop.body_count; i++)
            scan_for_captures(node->data.forloop.body[i], out);
        break;
    case AST_TRY:
        for (int i = 0; i < node->data.trycatch.try_count; i++)
            scan_for_captures(node->data.trycatch.try_body[i], out);
        for (int i = 0; i < node->data.trycatch.catch_count; i++)
            scan_for_captures(node->data.trycatch.catch_body[i], out);
        break;
    case AST_MATCH:
        for (int i = 0; i < node->data.match.case_count; i++)
            for (int j = 0; j < node->data.match.body_counts[i]; j++)
                scan_for_captures(node->data.match.bodies[i][j], out);
        break;
    /* Expressions that may contain lambdas */
    case AST_BINOP:
        scan_for_captures(node->data.binop.left, out);
        scan_for_captures(node->data.binop.right, out);
        break;
    case AST_UNARY:
        scan_for_captures(node->data.unary.operand, out);
        break;
    case AST_RELATION:
        scan_for_captures(node->data.relation.left, out);
        scan_for_captures(node->data.relation.right, out);
        break;
    case AST_ASSIGN:
        scan_for_captures(node->data.assign.expr, out);
        break;
    case AST_RETURN:
        scan_for_captures(node->data.ret.expr, out);
        break;
    case AST_LIST:
        for (int i = 0; i < node->data.list.count; i++)
            scan_for_captures(node->data.list.elems[i], out);
        break;
    case AST_INDEX:
        scan_for_captures(node->data.index.target, out);
        scan_for_captures(node->data.index.index, out);
        break;
    case AST_LISTCOMP:
        scan_for_captures(node->data.listcomp.expr, out);
        scan_for_captures(node->data.listcomp.iter, out);
        scan_for_captures(node->data.listcomp.filter, out);
        break;
    case AST_DICT:
        for (int i = 0; i < node->data.dict.count; i++) {
            scan_for_captures(node->data.dict.keys[i], out);
            scan_for_captures(node->data.dict.vals[i], out);
        }
        break;
    case AST_DOT:
        scan_for_captures(node->data.dot.target, out);
        break;
    case AST_DOT_ASSIGN:
        scan_for_captures(node->data.dot_assign.target, out);
        scan_for_captures(node->data.dot_assign.expr, out);
        break;
    case AST_INDEX_ASSIGN:
        scan_for_captures(node->data.index_assign.target, out);
        scan_for_captures(node->data.index_assign.index, out);
        scan_for_captures(node->data.index_assign.expr, out);
        break;
    case AST_LIST_PATTERN_ASSIGN:
        scan_for_captures(node->data.list_pattern_assign.expr, out);
        break;
    case AST_SLICE:
        scan_for_captures(node->data.slice.target, out);
        scan_for_captures(node->data.slice.start, out);
        scan_for_captures(node->data.slice.end, out);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_IDENT:
    case AST_NULL:
    case AST_PROGRAM:
    case AST_INTERROGATE:
    case AST_PREDICATE:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_IMPORT:
        break;
    }
}

/* True if the subtree defines any closure (function/lambda). Used to gate the
 * persisted-loop-env optimization: OP_CLOSURE captures frame->env
 * unconditionally (even with no free variables — see CASE(CLOSURE)), so a body
 * that defines any closure pins the loop env and must NOT have that env reused
 * /cleared across iterations. Mirrors scan_for_captures' node coverage so it
 * can't miss a nesting site; returns on the first closure found. Does not
 * descend into a closure's own body (finding the closure is sufficient). */
static int ast_has_closure(ASTNode *node) {
    if (!node) return 0;
#define ANY(n) do { if (ast_has_closure(n)) return 1; } while (0)
    switch (node->type) {
    case AST_FUNC:
    case AST_LAMBDA:
        return 1;
    case AST_IF:
        for (int i = 0; i < node->data.cond.if_count; i++) ANY(node->data.cond.if_body[i]);
        for (int i = 0; i < node->data.cond.else_count; i++) ANY(node->data.cond.else_body[i]);
        ANY(node->data.cond.cond);
        break;
    case AST_LOOP:
        ANY(node->data.loop.cond);
        for (int i = 0; i < node->data.loop.body_count; i++) ANY(node->data.loop.body[i]);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < node->data.block.count; i++) ANY(node->data.block.stmts[i]);
        break;
    case AST_FOR:
        ANY(node->data.forloop.iter);
        for (int i = 0; i < node->data.forloop.body_count; i++) ANY(node->data.forloop.body[i]);
        break;
    case AST_TRY:
        for (int i = 0; i < node->data.trycatch.try_count; i++) ANY(node->data.trycatch.try_body[i]);
        for (int i = 0; i < node->data.trycatch.catch_count; i++) ANY(node->data.trycatch.catch_body[i]);
        break;
    case AST_MATCH:
        ANY(node->data.match.expr);
        for (int i = 0; i < node->data.match.case_count; i++)
            for (int j = 0; j < node->data.match.body_counts[i]; j++)
                ANY(node->data.match.bodies[i][j]);
        break;
    case AST_BINOP:
        ANY(node->data.binop.left); ANY(node->data.binop.right);
        break;
    case AST_UNARY:
        ANY(node->data.unary.operand);
        break;
    case AST_RELATION:
        ANY(node->data.relation.left); ANY(node->data.relation.right);
        break;
    case AST_ASSIGN:
        ANY(node->data.assign.expr);
        break;
    case AST_RETURN:
        ANY(node->data.ret.expr);
        break;
    case AST_LIST:
        for (int i = 0; i < node->data.list.count; i++) ANY(node->data.list.elems[i]);
        break;
    case AST_INDEX:
        ANY(node->data.index.target); ANY(node->data.index.index);
        break;
    case AST_LISTCOMP:
        ANY(node->data.listcomp.expr); ANY(node->data.listcomp.iter); ANY(node->data.listcomp.filter);
        break;
    case AST_DICT:
        for (int i = 0; i < node->data.dict.count; i++) {
            ANY(node->data.dict.keys[i]); ANY(node->data.dict.vals[i]);
        }
        break;
    case AST_DOT:
        ANY(node->data.dot.target);
        break;
    case AST_DOT_ASSIGN:
        ANY(node->data.dot_assign.target); ANY(node->data.dot_assign.expr);
        break;
    case AST_INDEX_ASSIGN:
        ANY(node->data.index_assign.target); ANY(node->data.index_assign.index);
        ANY(node->data.index_assign.expr);
        break;
    case AST_LIST_PATTERN_ASSIGN:
        ANY(node->data.list_pattern_assign.expr);
        break;
    case AST_SLICE:
        ANY(node->data.slice.target); ANY(node->data.slice.start); ANY(node->data.slice.end);
        break;
    case AST_INTERROGATE:
        ANY(node->data.interrogate.expr); ANY(node->data.interrogate.at_expr);
        ANY(node->data.interrogate.when_expr);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_IDENT:
    case AST_NULL:
    case AST_PROGRAM:
    case AST_PREDICATE:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_IMPORT:
        break;
    }
#undef ANY
    return 0;
}

/* Overwrite-safety analysis for the persisted loop env. The persist+overwrite
 * tier skips the per-iteration CLEAR (keeping binding_version stable so the
 * outer-variable inline cache stays hot) — but that is only correct if the loop
 * body creates NO binding that lives in the loop env, because such a binding
 * would persist across iterations instead of being fresh each pass. A binding
 * lands in the loop env when the body assigns a name not already bound in an
 * enclosing scope (a loop-local), or via `local`, comprehension-var leakage,
 * a catch error name, a list-pattern, an import, or a closure. This routine
 * returns 1 only when it can PROVE the subtree creates none of those: every
 * plain assignment targets a name in `bound` (unconditionally bound before the
 * loop) or an existing global/builtin, and no hard-to-prove binder appears.
 * Conservative: anything unrecognised returns 0 (→ fall back to persist+clear,
 * which is always correct). Nested for-loops/functions get their own env, but
 * are bailed on here rather than reasoned through. */
static int subtree_overwrite_safe(ASTNode *n, NameSet *bound, Env *env) {
    if (!n) return 1;
#define SAFE(x) do { if (!subtree_overwrite_safe((x), bound, env)) return 0; } while (0)
    switch (n->type) {
    /* Binders / leak / closure / opaque — cannot prove fresh-per-iteration. */
    case AST_FUNC: case AST_LAMBDA:
    case AST_LISTCOMP: case AST_TRY: case AST_MATCH:
    case AST_FOR: case AST_IMPORT: case AST_LIST_PATTERN_ASSIGN:
        return 0;
    case AST_ASSIGN:
        if (n->data.assign.local_only) return 0;            /* explicit shadow */
        if (!name_set_has(bound, n->data.assign.name)) {
            uint32_t h = env_hash_name(n->data.assign.name);
            if (!(env && env_get_hashed(env, n->data.assign.name, h)))
                return 0;                                   /* fresh loop-local */
        }
        SAFE(n->data.assign.expr);
        break;
    /* Same-env control flow — every child must be safe. */
    case AST_IF:
        SAFE(n->data.cond.cond);
        for (int i = 0; i < n->data.cond.if_count; i++) SAFE(n->data.cond.if_body[i]);
        for (int i = 0; i < n->data.cond.else_count; i++) SAFE(n->data.cond.else_body[i]);
        break;
    case AST_LOOP:
        SAFE(n->data.loop.cond);
        for (int i = 0; i < n->data.loop.body_count; i++) SAFE(n->data.loop.body[i]);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < n->data.block.count; i++) SAFE(n->data.block.stmts[i]);
        break;
    /* Expressions: no name binding, but recurse to catch nested lambdas/comps. */
    case AST_BINOP:        SAFE(n->data.binop.left); SAFE(n->data.binop.right); break;
    case AST_UNARY:        SAFE(n->data.unary.operand); break;
    case AST_RELATION:     SAFE(n->data.relation.left); SAFE(n->data.relation.right); break;
    case AST_RETURN:       SAFE(n->data.ret.expr); break;
    case AST_LIST:         for (int i = 0; i < n->data.list.count; i++) SAFE(n->data.list.elems[i]); break;
    case AST_INDEX:        SAFE(n->data.index.target); SAFE(n->data.index.index); break;
    case AST_DICT:
        for (int i = 0; i < n->data.dict.count; i++) { SAFE(n->data.dict.keys[i]); SAFE(n->data.dict.vals[i]); }
        break;
    case AST_DOT:          SAFE(n->data.dot.target); break;
    case AST_DOT_ASSIGN:   SAFE(n->data.dot_assign.target); SAFE(n->data.dot_assign.expr); break;
    case AST_INDEX_ASSIGN: SAFE(n->data.index_assign.target); SAFE(n->data.index_assign.index); SAFE(n->data.index_assign.expr); break;
    case AST_SLICE:        SAFE(n->data.slice.target); SAFE(n->data.slice.start); SAFE(n->data.slice.end); break;
    case AST_INTERROGATE:  SAFE(n->data.interrogate.expr); SAFE(n->data.interrogate.at_expr);
                           SAFE(n->data.interrogate.when_expr); break;
    /* Leaves with no binding effect. */
    case AST_IDENT: case AST_NUM: case AST_STR: case AST_NULL:
    case AST_PREDICATE: case AST_BREAK: case AST_CONTINUE:
        break;
    /* These take the fallback the deleted `default:` supplied. Enumerated
     * rather than covered by a `default:` so that -Werror=switch (Makefile
     * CFLAGS) makes a new ASTType a build error here. */
    case AST_PROGRAM:
        return 0;
    }
#undef SAFE
    return 1;
}

/* Collect names unconditionally bound at module top level BEFORE `loop_node`:
 * the targets of direct top-level binding statements that precede it in the
 * program. These are guaranteed bound when the loop runs, so a body assignment
 * to one of them is an outer mutation, not a loop-local. Returns 1 if loop_node
 * was found as a direct top-level statement (so `bound` is meaningful), else 0
 * (the loop is nested — caller must not use the overwrite tier). */
/* Add the name(s) a single statement unconditionally binds in the current env. */
static void collect_stmt_bind(ASTNode *s, NameSet *bound) {
    if (!s) return;
    if (s->type == AST_ASSIGN && !s->data.assign.local_only)
        name_set_add(bound, s->data.assign.name);
    else if (s->type == AST_FUNC)
        name_set_add(bound, s->data.func.name);
    else if (s->type == AST_LIST_PATTERN_ASSIGN)
        for (int j = 0; j < s->data.list_pattern_assign.name_count; j++)
            name_set_add(bound, s->data.list_pattern_assign.names[j]);
}

/* Collect names unconditionally bound BEFORE `loop_node` in a statement list,
 * recursing through `unobserved`/plain blocks (transparent — same env, no
 * branching — so their bindings leak to this scope and execute in order).
 * Returns 1 if loop_node was reached (so `bound` is complete and the overwrite
 * tier may apply), 0 if not found in this unconditional stream (the loop is
 * nested under a conditional / loop / function — caller stays on persist+clear).
 * `if` is intentionally NOT descended: a binding inside one is not guaranteed
 * before the loop. */
static int collect_bound_before_in_block(ASTNode **stmts, int count,
                                         ASTNode *loop_node, NameSet *bound) {
    for (int i = 0; i < count; i++) {
        ASTNode *s = stmts[i];
        if (s == loop_node) return 1;
        if (!s) continue;
        if (s->type == AST_UNOBSERVED || s->type == AST_BLOCK) {
            if (collect_bound_before_in_block(s->data.block.stmts, s->data.block.count,
                                              loop_node, bound))
                return 1;  /* loop is inside this block; binds before it collected */
            for (int j = 0; j < s->data.block.count; j++)
                collect_stmt_bind(s->data.block.stmts[j], bound);  /* whole block ran before */
        } else {
            collect_stmt_bind(s, bound);
        }
    }
    return 0;
}

static int collect_bound_before_loop(ASTNode *root, ASTNode *loop_node, NameSet *bound) {
    if (!root || root->type != AST_PROGRAM) return 0;
    return collect_bound_before_in_block(root->data.program.stmts,
                                         root->data.program.count, loop_node, bound);
}

/* Walk a function body collecting names that appear in `who is x` or `when is x`
 * interrogations. These need the slow path so env assign_counts stays consistent. */
static void scan_for_interrogated(ASTNode *node, NameSet *out) {
    if (!node) return;
    switch (node->type) {
    case AST_INTERROGATE:
        if (node->data.interrogate.expr &&
            node->data.interrogate.expr->type == AST_IDENT) {
            name_set_add(out, node->data.interrogate.expr->data.ident.name);
        }
        scan_for_interrogated(node->data.interrogate.expr, out);
        scan_for_interrogated(node->data.interrogate.at_expr, out);
        scan_for_interrogated(node->data.interrogate.when_expr, out);
        break;
    case AST_BINOP:
        scan_for_interrogated(node->data.binop.left, out);
        scan_for_interrogated(node->data.binop.right, out);
        break;
    case AST_UNARY:
        scan_for_interrogated(node->data.unary.operand, out);
        break;
    case AST_RELATION:
        scan_for_interrogated(node->data.relation.left, out);
        scan_for_interrogated(node->data.relation.right, out);
        break;
    case AST_ASSIGN:
        scan_for_interrogated(node->data.assign.expr, out);
        break;
    case AST_IF:
        scan_for_interrogated(node->data.cond.cond, out);
        for (int i = 0; i < node->data.cond.if_count; i++)
            scan_for_interrogated(node->data.cond.if_body[i], out);
        for (int i = 0; i < node->data.cond.else_count; i++)
            scan_for_interrogated(node->data.cond.else_body[i], out);
        break;
    case AST_LOOP:
        scan_for_interrogated(node->data.loop.cond, out);
        for (int i = 0; i < node->data.loop.body_count; i++)
            scan_for_interrogated(node->data.loop.body[i], out);
        break;
    case AST_RETURN:
        scan_for_interrogated(node->data.ret.expr, out);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < node->data.block.count; i++)
            scan_for_interrogated(node->data.block.stmts[i], out);
        break;
    case AST_LIST:
        for (int i = 0; i < node->data.list.count; i++)
            scan_for_interrogated(node->data.list.elems[i], out);
        break;
    case AST_INDEX:
        scan_for_interrogated(node->data.index.target, out);
        scan_for_interrogated(node->data.index.index, out);
        break;
    case AST_FOR:
        scan_for_interrogated(node->data.forloop.iter, out);
        for (int i = 0; i < node->data.forloop.body_count; i++)
            scan_for_interrogated(node->data.forloop.body[i], out);
        break;
    case AST_TRY:
        for (int i = 0; i < node->data.trycatch.try_count; i++)
            scan_for_interrogated(node->data.trycatch.try_body[i], out);
        for (int i = 0; i < node->data.trycatch.catch_count; i++)
            scan_for_interrogated(node->data.trycatch.catch_body[i], out);
        break;
    case AST_DICT:
        for (int i = 0; i < node->data.dict.count; i++) {
            scan_for_interrogated(node->data.dict.keys[i], out);
            scan_for_interrogated(node->data.dict.vals[i], out);
        }
        break;
    case AST_DOT:
        scan_for_interrogated(node->data.dot.target, out);
        break;
    case AST_DOT_ASSIGN:
        scan_for_interrogated(node->data.dot_assign.target, out);
        scan_for_interrogated(node->data.dot_assign.expr, out);
        break;
    case AST_INDEX_ASSIGN:
        scan_for_interrogated(node->data.index_assign.target, out);
        scan_for_interrogated(node->data.index_assign.index, out);
        scan_for_interrogated(node->data.index_assign.expr, out);
        break;
    case AST_MATCH:
        scan_for_interrogated(node->data.match.expr, out);
        for (int i = 0; i < node->data.match.case_count; i++)
            for (int j = 0; j < node->data.match.body_counts[i]; j++)
                scan_for_interrogated(node->data.match.bodies[i][j], out);
        break;
    case AST_LIST_PATTERN_ASSIGN:
        scan_for_interrogated(node->data.list_pattern_assign.expr, out);
        break;
    case AST_SLICE:
        scan_for_interrogated(node->data.slice.target, out);
        scan_for_interrogated(node->data.slice.start, out);
        scan_for_interrogated(node->data.slice.end, out);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_IDENT:
    case AST_NULL:
    case AST_FUNC:
    case AST_LISTCOMP:
    case AST_PROGRAM:
    case AST_PREDICATE:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_IMPORT:
    case AST_LAMBDA:
        break;
    }
}

/* #633: collect names that a listcomp variable or a `catch` error-name binds
 * into the env *by name* (OP_SET_NAME_LOCAL — see AST_LISTCOMP / AST_TRY) in
 * THIS scope. A plain `x is ...` of the same name must not slot-promote in
 * emit_assign_for_tos, or the assignment writes a frame slot while the
 * comprehension/catch writes the env by name — the two bindings diverge and a
 * slot read returns a stale value that later (even dead) code flips. This is
 * the mirror of collect_module_names_walk keeping forloop.var off the slot
 * path. Stops at nested function/lambda boundaries — those introduce their own
 * scope — by not recursing into AST_FUNC / AST_LAMBDA. */
static void scan_for_env_bound(ASTNode *node, NameSet *out) {
    if (!node) return;
    switch (node->type) {
    case AST_LISTCOMP:
        name_set_add(out, node->data.listcomp.var);
        scan_for_env_bound(node->data.listcomp.expr, out);
        scan_for_env_bound(node->data.listcomp.iter, out);
        scan_for_env_bound(node->data.listcomp.filter, out);
        break;
    case AST_TRY:
        for (int i = 0; i < node->data.trycatch.try_count; i++)
            scan_for_env_bound(node->data.trycatch.try_body[i], out);
        if (node->data.trycatch.err_name) name_set_add(out, node->data.trycatch.err_name);
        for (int i = 0; i < node->data.trycatch.catch_count; i++)
            scan_for_env_bound(node->data.trycatch.catch_body[i], out);
        break;
    /* Descend through control flow / blocks to reach nested listcomps/catches */
    case AST_IF:
        for (int i = 0; i < node->data.cond.if_count; i++)
            scan_for_env_bound(node->data.cond.if_body[i], out);
        for (int i = 0; i < node->data.cond.else_count; i++)
            scan_for_env_bound(node->data.cond.else_body[i], out);
        break;
    case AST_LOOP:
        for (int i = 0; i < node->data.loop.body_count; i++)
            scan_for_env_bound(node->data.loop.body[i], out);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        for (int i = 0; i < node->data.block.count; i++)
            scan_for_env_bound(node->data.block.stmts[i], out);
        break;
    case AST_FOR:
        scan_for_env_bound(node->data.forloop.iter, out);
        for (int i = 0; i < node->data.forloop.body_count; i++)
            scan_for_env_bound(node->data.forloop.body[i], out);
        break;
    case AST_MATCH:
        scan_for_env_bound(node->data.match.expr, out);
        for (int i = 0; i < node->data.match.case_count; i++)
            for (int j = 0; j < node->data.match.body_counts[i]; j++)
                scan_for_env_bound(node->data.match.bodies[i][j], out);
        break;
    /* Expressions that may contain a listcomp */
    case AST_BINOP:
        scan_for_env_bound(node->data.binop.left, out);
        scan_for_env_bound(node->data.binop.right, out);
        break;
    case AST_UNARY:
        scan_for_env_bound(node->data.unary.operand, out);
        break;
    case AST_RELATION:
        scan_for_env_bound(node->data.relation.left, out);
        scan_for_env_bound(node->data.relation.right, out);
        break;
    case AST_ASSIGN:
        scan_for_env_bound(node->data.assign.expr, out);
        break;
    case AST_RETURN:
        scan_for_env_bound(node->data.ret.expr, out);
        break;
    case AST_LIST:
        for (int i = 0; i < node->data.list.count; i++)
            scan_for_env_bound(node->data.list.elems[i], out);
        break;
    case AST_INDEX:
        scan_for_env_bound(node->data.index.target, out);
        scan_for_env_bound(node->data.index.index, out);
        break;
    case AST_DICT:
        for (int i = 0; i < node->data.dict.count; i++) {
            scan_for_env_bound(node->data.dict.keys[i], out);
            scan_for_env_bound(node->data.dict.vals[i], out);
        }
        break;
    case AST_DOT:
        scan_for_env_bound(node->data.dot.target, out);
        break;
    case AST_DOT_ASSIGN:
        scan_for_env_bound(node->data.dot_assign.target, out);
        scan_for_env_bound(node->data.dot_assign.expr, out);
        break;
    case AST_INDEX_ASSIGN:
        scan_for_env_bound(node->data.index_assign.target, out);
        scan_for_env_bound(node->data.index_assign.index, out);
        scan_for_env_bound(node->data.index_assign.expr, out);
        break;
    case AST_LIST_PATTERN_ASSIGN:
        scan_for_env_bound(node->data.list_pattern_assign.expr, out);
        break;
    case AST_SLICE:
        scan_for_env_bound(node->data.slice.target, out);
        scan_for_env_bound(node->data.slice.start, out);
        scan_for_env_bound(node->data.slice.end, out);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_IDENT:
    case AST_NULL:
    case AST_FUNC:
    case AST_PROGRAM:
    case AST_INTERROGATE:
    case AST_PREDICATE:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_IMPORT:
    case AST_LAMBDA:
        break;
    }
}

/* Collect module-level names (functions defined, top-level assignments).
 * Stops at function/lambda boundaries — those introduce their own scope.
 * Used to decide whether an assignment inside a function is updating a global
 * (slow name path) vs creating a fresh local (fast slot path). */
static void collect_module_names_block(ASTNode **stmts, int count, NameSet *out);
static void collect_module_names_walk(ASTNode *node, NameSet *out) {
    if (!node) return;
    switch (node->type) {
    case AST_ASSIGN:
        name_set_add(out, node->data.assign.name);
        break;
    case AST_FUNC:
        name_set_add(out, node->data.func.name);
        /* Don't descend into function body */
        break;
    case AST_IF:
        collect_module_names_block(node->data.cond.if_body, node->data.cond.if_count, out);
        collect_module_names_block(node->data.cond.else_body, node->data.cond.else_count, out);
        break;
    case AST_LOOP:
        collect_module_names_block(node->data.loop.body, node->data.loop.body_count, out);
        break;
    case AST_FOR:
        /* Don't add forloop.var: AST_FOR binds it via OP_SET_NAME_LOCAL
         * (env-based), so promoting it to a frame slot leaves the slot null
         * while writes go to env — every read returns null. */
        collect_module_names_block(node->data.forloop.body, node->data.forloop.body_count, out);
        break;
    case AST_BLOCK:
    case AST_UNOBSERVED:
        collect_module_names_block(node->data.block.stmts, node->data.block.count, out);
        break;
    case AST_TRY:
        collect_module_names_block(node->data.trycatch.try_body, node->data.trycatch.try_count, out);
        if (node->data.trycatch.err_name) name_set_add(out, node->data.trycatch.err_name);
        collect_module_names_block(node->data.trycatch.catch_body, node->data.trycatch.catch_count, out);
        break;
    case AST_MATCH:
        for (int i = 0; i < node->data.match.case_count; i++)
            collect_module_names_block(node->data.match.bodies[i], node->data.match.body_counts[i], out);
        break;
    case AST_LIST_PATTERN_ASSIGN:
        for (int i = 0; i < node->data.list_pattern_assign.name_count; i++)
            name_set_add(out, node->data.list_pattern_assign.names[i]);
        break;
    case AST_PROGRAM:
        collect_module_names_block(node->data.program.stmts, node->data.program.count, out);
        break;
    /* Nothing to do for these. Enumerated rather than covered by a `default:`
     * so that -Werror=switch (Makefile CFLAGS) makes a new ASTType a build
     * error here instead of a silent no-op. */
    case AST_NUM:
    case AST_STR:
    case AST_IDENT:
    case AST_NULL:
    case AST_BINOP:
    case AST_UNARY:
    case AST_RELATION:
    case AST_RETURN:
    case AST_LIST:
    case AST_INDEX:
    case AST_LISTCOMP:
    case AST_INTERROGATE:
    case AST_PREDICATE:
    case AST_DICT:
    case AST_DOT:
    case AST_BREAK:
    case AST_CONTINUE:
    case AST_DOT_ASSIGN:
    case AST_IMPORT:
    case AST_LAMBDA:
    case AST_INDEX_ASSIGN:
    case AST_SLICE:
        break;
    }
}
static void collect_module_names_block(ASTNode **stmts, int count, NameSet *out) {
    for (int i = 0; i < count; i++) collect_module_names_walk(stmts[i], out);
}

/* #459: does this compilation unit bind `dispatch` anywhere — module scope,
 * any function/lambda body, any binder position (a plain `dispatch is ...`
 * inside a function writes through to the global builtin binding, see
 * in_globals in emit_assign_for_tos) — or reference `eval`, which can bind
 * it dynamically (the same escape E003 honors)? Match patterns compare, they
 * don't bind (same reading as the E003 walker). Over-approximation is
 * deliberate: a spurious hit only costs the OP_DISPATCH fast path; a miss is
 * a silent wrong answer. Cross-unit rebinding (a load_file'd module that
 * rebinds `dispatch` for a sibling unit) is out of scope here and is what
 * the compile-time env check at the emit site catches for the REPL/embed
 * sequential-unit case. */
static int scan_dispatch_rebind_block(ASTNode **stmts, int count);
static int scan_dispatch_rebind(ASTNode *n) {
    if (!n) return 0;
    switch (n->type) {
    case AST_IDENT:
        return strcmp(n->data.ident.name, "eval") == 0;
    case AST_ASSIGN:
        if (strcmp(n->data.assign.name, "dispatch") == 0) return 1;
        return scan_dispatch_rebind(n->data.assign.expr);
    case AST_FUNC:
        if (strcmp(n->data.func.name, "dispatch") == 0) return 1;
        for (int i = 0; i < n->data.func.param_count; i++) {
            if (strcmp(n->data.func.params[i], "dispatch") == 0) return 1;
            if (n->data.func.param_defaults &&
                scan_dispatch_rebind(n->data.func.param_defaults[i])) return 1;
        }
        return scan_dispatch_rebind_block(n->data.func.body, n->data.func.body_count);
    case AST_LAMBDA:
        for (int i = 0; i < n->data.lambda.param_count; i++)
            if (strcmp(n->data.lambda.params[i], "dispatch") == 0) return 1;
        return scan_dispatch_rebind(n->data.lambda.body);
    case AST_BINOP:
        return scan_dispatch_rebind(n->data.binop.left) ||
               scan_dispatch_rebind(n->data.binop.right);
    case AST_UNARY:
        return scan_dispatch_rebind(n->data.unary.operand);
    case AST_RELATION:
        return scan_dispatch_rebind(n->data.relation.left) ||
               scan_dispatch_rebind(n->data.relation.right);
    case AST_IF:
        return scan_dispatch_rebind(n->data.cond.cond) ||
               scan_dispatch_rebind_block(n->data.cond.if_body, n->data.cond.if_count) ||
               scan_dispatch_rebind_block(n->data.cond.else_body, n->data.cond.else_count);
    case AST_LOOP:
        return scan_dispatch_rebind(n->data.loop.cond) ||
               scan_dispatch_rebind_block(n->data.loop.body, n->data.loop.body_count);
    case AST_RETURN:
        return scan_dispatch_rebind(n->data.ret.expr);
    case AST_BLOCK:
    case AST_UNOBSERVED:
        return scan_dispatch_rebind_block(n->data.block.stmts, n->data.block.count);
    case AST_LIST:
        return scan_dispatch_rebind_block(n->data.list.elems, n->data.list.count);
    case AST_INDEX:
        return scan_dispatch_rebind(n->data.index.target) ||
               scan_dispatch_rebind(n->data.index.index);
    case AST_LISTCOMP:
        if (n->data.listcomp.var && strcmp(n->data.listcomp.var, "dispatch") == 0) return 1;
        return scan_dispatch_rebind(n->data.listcomp.expr) ||
               scan_dispatch_rebind(n->data.listcomp.iter) ||
               scan_dispatch_rebind(n->data.listcomp.filter);
    case AST_FOR:
        if (strcmp(n->data.forloop.var, "dispatch") == 0) return 1;
        return scan_dispatch_rebind(n->data.forloop.iter) ||
               scan_dispatch_rebind_block(n->data.forloop.body, n->data.forloop.body_count);
    case AST_PROGRAM:
        return scan_dispatch_rebind_block(n->data.program.stmts, n->data.program.count);
    case AST_INTERROGATE:
        return scan_dispatch_rebind(n->data.interrogate.expr) ||
               scan_dispatch_rebind(n->data.interrogate.at_expr);
    case AST_TRY:
        if (n->data.trycatch.err_name &&
            strcmp(n->data.trycatch.err_name, "dispatch") == 0) return 1;
        return scan_dispatch_rebind_block(n->data.trycatch.try_body, n->data.trycatch.try_count) ||
               scan_dispatch_rebind_block(n->data.trycatch.catch_body, n->data.trycatch.catch_count);
    case AST_DICT:
        return scan_dispatch_rebind_block(n->data.dict.keys, n->data.dict.count) ||
               scan_dispatch_rebind_block(n->data.dict.vals, n->data.dict.count);
    case AST_DOT:
        return scan_dispatch_rebind(n->data.dot.target);
    case AST_DOT_ASSIGN:
        return scan_dispatch_rebind(n->data.dot_assign.target) ||
               scan_dispatch_rebind(n->data.dot_assign.expr);
    case AST_INDEX_ASSIGN:
        return scan_dispatch_rebind(n->data.index_assign.target) ||
               scan_dispatch_rebind(n->data.index_assign.index) ||
               scan_dispatch_rebind(n->data.index_assign.expr);
    case AST_IMPORT:
        return strcmp(n->data.import.module_name, "dispatch") == 0;
    case AST_MATCH:
        if (scan_dispatch_rebind(n->data.match.expr)) return 1;
        for (int i = 0; i < n->data.match.case_count; i++) {
            if (scan_dispatch_rebind(n->data.match.patterns[i])) return 1;
            if (scan_dispatch_rebind_block(n->data.match.bodies[i],
                                           n->data.match.body_counts[i])) return 1;
        }
        return 0;
    case AST_LIST_PATTERN_ASSIGN:
        for (int i = 0; i < n->data.list_pattern_assign.name_count; i++)
            if (strcmp(n->data.list_pattern_assign.names[i], "dispatch") == 0) return 1;
        return scan_dispatch_rebind(n->data.list_pattern_assign.expr);
    case AST_SLICE:
        return scan_dispatch_rebind(n->data.slice.target) ||
               scan_dispatch_rebind(n->data.slice.start) ||
               scan_dispatch_rebind(n->data.slice.end);
    /* These take the fallback the deleted `default:` supplied. Enumerated
     * rather than covered by a `default:` so that -Werror=switch (Makefile
     * CFLAGS) makes a new ASTType a build error here. */
    case AST_NUM:
    case AST_STR:
    case AST_NULL:
    case AST_PREDICATE:
    case AST_BREAK:
    case AST_CONTINUE:
        break;
    }
    return 0;
}
static int scan_dispatch_rebind_block(ASTNode **stmts, int count) {
    for (int i = 0; i < count; i++)
        if (scan_dispatch_rebind(stmts[i])) return 1;
    return 0;
}

/* Is this name visible in an enclosing function's locals/params?
 * Checks three places per enclosing compiler:
 *   - locals[]: names that the enclosing function chose to put on slot-path.
 *   - captured: names referenced by inner closures of the enclosing function
 *     (kept on name-path because the inner closure escapes).
 *   - interrogated: names subject to WHAT/WHO/WHY queries (also name-path).
 * Missing the latter two caused #130: a write like `val is val + 1` inside
 * an inner closure was mis-classified as a fresh local because the outer
 * `val` lives in the env (name-path), not in e->locals[]. */
static int name_in_enclosing(Compiler *c, const char *name) {
    for (Compiler *e = c->enclosing; e && e->enclosing; e = e->enclosing) {
        for (int i = 0; i < e->local_count; i++)
            if (strcmp(e->locals[i].name, name) == 0) return 1;
        if (name_set_has(&e->captured, name)) return 1;
        if (name_set_has(&e->interrogated, name)) return 1;
    }
    return 0;
}

/* Emit OBSERVE + SET ops for an assignment whose value is already on TOS.
 * Mirrors the AST_ASSIGN body so list-pattern destructuring (which leaves
 * each element on TOS via OP_DESTRUCTURE_UNPACK) can reuse the same
 * slot/captured/global resolution rules. local_only matches
 * node->data.assign.local_only — destructure callers pass 0. */
static void emit_assign_for_tos(Compiler *c, const char *name, uint32_t name_hash,
                                int local_only, int line) {
    uint32_t h = name_hash ? name_hash : env_hash_name(name);
    uint8_t  set_op   = 0;
    uint16_t set_arg  = 0;
    uint8_t  obs_op   = 0;
    uint16_t obs_arg  = 0;

    if (c->enclosing) {
        int slot = resolve_local(c, name, h);
        if (slot >= 0) {
            set_op = OP_SET_LOCAL; set_arg = (uint16_t)slot;
            obs_op = OP_OBSERVE_ASSIGN_LOCAL; obs_arg = (uint16_t)slot;
        } else {
            int captured     = name_set_has(&c->captured, name);
            int interrogated = name_set_has(&c->interrogated, name);
            int env_bound    = name_set_has(&c->env_bound, name);
            int in_outer     = name_in_enclosing(c, name);
            int in_module    = c->module_names && name_set_has(c->module_names, name);
            /* #373: whether a pre-existing env binding is a write-through
             * target must not depend on load order. Inside a module compile
             * (load_file/import) the loader's globals are readable but never
             * write-through — the function gets a fresh local instead. */
            int in_globals   = !g_compile_module_boundary &&
                               c->env && env_get_hashed(c->env, name, h) != NULL;
            int local_eligible = !captured && !interrogated && !env_bound && !in_outer && !in_module && !in_globals;

            if (local_eligible) {
                int new_slot = add_local(c, name, h);
                if (new_slot >= 0) {
                    set_op = OP_SET_LOCAL; set_arg = (uint16_t)new_slot;
                    obs_op = OP_OBSERVE_ASSIGN_LOCAL; obs_arg = (uint16_t)new_slot;
                } else {
                    int idx = add_string_constant(c, name);
                    set_op = OP_SET_FN_NAME_LOCAL; set_arg = (uint16_t)idx;
                    obs_op = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
                }
            } else if (local_only || captured || interrogated || env_bound) {
                int idx = add_string_constant(c, name);
                set_op = OP_SET_FN_NAME_LOCAL; set_arg = (uint16_t)idx;
                obs_op = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
            } else {
                int idx = add_string_constant(c, name);
                set_op = OP_SET_NAME; set_arg = (uint16_t)idx;
                obs_op = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
            }
        }
    } else {
        int picked = 0;
        if (name_set_has(&c->module_slot_names, name)) {
            int slot = resolve_local(c, name, h);
            if (slot >= 0) {
                set_op = OP_SET_LOCAL; set_arg = (uint16_t)slot;
                obs_op = OP_OBSERVE_ASSIGN_LOCAL; obs_arg = (uint16_t)slot;
                picked = 1;
            }
        }
        if (!picked) {
            int idx = add_string_constant(c, name);
            /* #589: at an IMPORTED module's own top level, a bare write
             * must never walk past mod_env to rebind whatever the
             * importer's scope already holds under the same name —
             * mirrors #373's function-body rule one level up. load_file
             * doesn't set g_compile_import_toplevel, so its top-level
             * writes keep walking the chain into the caller's scope,
             * per its documented "current scope" contract. */
            if (local_only || g_compile_import_toplevel) {
                set_op = OP_SET_NAME_LOCAL; set_arg = (uint16_t)idx;
            } else {
                set_op = OP_SET_NAME; set_arg = (uint16_t)idx;
            }
            obs_op = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
        }
    }

    emit_op_u16(c, obs_op, obs_arg, line);
    emit_op_u16(c, set_op, set_arg, line);

    /* #262 Phase-3 (observe-at-SET): for a NAME binding, the OBSERVE_ASSIGN
     * above ran before the binding existed, so its slot couldn't be observed
     * on the first assignment. Re-observe AFTER the SET, when the binding is
     * live, fixing the first-assignment lag. Only under the compile-time
     * EIGS_OBS_SHADOW flag, so flag-off bytecode is byte-identical. Slot
     * bindings (OBSERVE_ASSIGN_LOCAL) already observe from assignment 1 — their
     * slots are pre-allocated — so they need no post-observe. */
    if (obs_op == OP_OBSERVE_ASSIGN) {
        emit_op_u16(c, OP_OBSERVE_NAME_POST, obs_arg, line);
    }
}

/* ---- AST compilation ---- */

/* Observer loop-stall (auto-halt on convergence) is OPT-IN: a `loop while`
 * gets it only when its condition is observer-based — i.e. references a bare
 * predicate (converged/stable/improving/diverging/oscillating/equilibrium).
 * This single classification is correctness-critical (see CHANGELOG / the
 * loop-halting design): observer->plain misclassification silently drops the
 * convergence backstop; plain->observer reintroduces the global-observer
 * cross-talk false-halt. We deliberately bias toward "plain": recurse only
 * through the boolean / comparison / unary structure of the condition; calls,
 * lambdas, names, literals, indexing, etc. are opaque and contribute nothing
 * (a predicate buried in a call argument won't enable halting — but also can't
 * cause a false-halt). Runs once at compile time and is encoded in the emitted
 * opcode (OP_LOOP_STALL_CHECK vs OP_LOOP_CAP_CHECK), so the interpreter and JIT
 * can never disagree on the classification. */
static int cond_is_observer_based(const ASTNode *n) {
    if (!n) return 0;
    switch (n->type) {
        case AST_PREDICATE: return 1;
        case AST_UNARY:    return cond_is_observer_based(n->data.unary.operand);
        case AST_BINOP:    return cond_is_observer_based(n->data.binop.left) ||
                                  cond_is_observer_based(n->data.binop.right);
        case AST_RELATION:
            /* A NAMED predicate `<pred> of <ident>` is an explicit, self-
             * terminating loop condition — it reads that binding's slot each
             * iteration — so it must NOT get the global-alias auto-stall, which
             * would halt on whatever was observed last (the settle_steps bug).
             * Only the BARE predicate opts into the stall. */
            if (n->data.relation.left &&
                n->data.relation.left->type == AST_PREDICATE &&
                n->data.relation.right &&
                n->data.relation.right->type == AST_IDENT) {
                return 0;
            }
            return cond_is_observer_based(n->data.relation.left) ||
                   cond_is_observer_based(n->data.relation.right);
        /* These take the fallback the deleted `default:` supplied. Enumerated
         * rather than covered by a `default:` so that -Werror=switch (Makefile
         * CFLAGS) makes a new ASTType a build error here. */
        case AST_NUM:
        case AST_STR:
        case AST_IDENT:
        case AST_NULL:
        case AST_ASSIGN:
        case AST_IF:
        case AST_LOOP:
        case AST_FUNC:
        case AST_RETURN:
        case AST_BLOCK:
        case AST_LIST:
        case AST_INDEX:
        case AST_LISTCOMP:
        case AST_FOR:
        case AST_PROGRAM:
        case AST_INTERROGATE:
        case AST_TRY:
        case AST_DICT:
        case AST_DOT:
        case AST_BREAK:
        case AST_CONTINUE:
        case AST_DOT_ASSIGN:
        case AST_IMPORT:
        case AST_MATCH:
        case AST_LAMBDA:
        case AST_UNOBSERVED:
        case AST_INDEX_ASSIGN:
        case AST_LIST_PATTERN_ASSIGN:
        case AST_SLICE:
            break;
    }
    return 0;
}

static void compile_node(Compiler *c, ASTNode *node) {
    if (g_parse_depth >= COMPILE_MAX_DEPTH) {
        /* Too deep to compile without overflowing the C stack. Flag the error
         * (entry paths abort before executing, cf. the post-compile check) and
         * emit a safe in-bounds placeholder rather than recursing further.
         *
         * #912: this was the one g_parse_errors++ site in the file that never
         * printed anything, so from a terminal the program died with a bare
         * "N compile error(s) — aborting" and `--lint` stayed clean. The
         * recorded message reached an embedder and nobody else. It bites
         * through f-strings above all: the lexer desugars one into a `+` chain
         * (~2 levels per interpolation), so a long status line reaches the
         * limit with nothing in the source that looks nested. Report once per
         * compile — the guard trips again at every sibling of the offending
         * node, and repeating one message is not more information. */
        if (!g_compile_depth_reported) {
            g_compile_depth_reported = 1;
            fprintf(stderr,
                    "Compile error line %d: expression nesting too deep to "
                    "compile (limit %d) — split the expression. Note an "
                    "f-string costs about two levels per interpolation, so a "
                    "long one reaches this with nothing nested-looking in the "
                    "source.\n",
                    node ? node->line : 0, COMPILE_MAX_DEPTH);
        }
        eigs_record_first_error(node ? node->line : 0,
                                "expression nesting too deep to compile");
        g_parse_errors++;
        emit(c, OP_NULL, node ? node->line : 0);
        return;
    }
    g_parse_depth++;
    /* #407: position cursor for the per-byte cols[] table. Set to this
     * node's column for everything it emits, restore on exit so a parent
     * resuming after a child recursion stamps its own ops with its own
     * column (post-order emission would otherwise leave the last child's
     * column on the parent's opcode). */
    int saved_col = c->chunk->cur_col;
    if (node) c->chunk->cur_col = node->col;
    compile_node_inner(c, node);
    c->chunk->cur_col = saved_col;
    g_parse_depth--;
}

static void compile_node_inner(Compiler *c, ASTNode *node) {
    if (!node) { emit(c, OP_NULL, 0); return; }

    emit_line(c, node->line);

    switch (node->type) {

    case AST_NUM: {
        double v = node->data.num;
        if (v == 0.0) { emit(c, OP_NUM_ZERO, node->line); }
        else if (v == 1.0) { emit(c, OP_NUM_ONE, node->line); }
        else { emit_op_u16(c, OP_CONST, (uint16_t)add_num_constant(c, v), node->line); }
        break;
    }

    case AST_STR: {
        int idx = add_string_constant(c, node->data.str);
        emit_op_u16(c, OP_CONST, (uint16_t)idx, node->line);
        break;
    }

    case AST_NULL:
        emit(c, OP_NULL, node->line);
        break;

    case AST_IDENT: {
        /* A reference to the state_at builtin means assignment history
         * will be queried at runtime — enable recording. (Aliasing that
         * hides the name — dict lookups, eval-built strings — won't be
         * seen; recording then starts at the aliasing program's own
         * temporal queries, or never. Documented in TRACE.md.) */
        if (strcmp(node->data.ident.name, "state_at") == 0)
            trace_arm_history_all();   /* #827: state_at queries every name */
        /* Try local slot resolution for params (fast path) */
        if (c->enclosing) {
            uint32_t h = node->name_hash;
            if (h == 0) h = env_hash_name(node->data.ident.name);
            int slot = resolve_local(c, node->data.ident.name, h);
            if (slot >= 0) {
                emit_op_u16(c, OP_GET_LOCAL, (uint16_t)slot, node->line);
                break;
            }
        } else if (name_set_has(&c->module_slot_names, node->data.ident.name)) {
            uint32_t h = node->name_hash;
            if (h == 0) h = env_hash_name(node->data.ident.name);
            int slot = resolve_local(c, node->data.ident.name, h);
            if (slot >= 0) {
                emit_op_u16(c, OP_GET_LOCAL, (uint16_t)slot, node->line);
                break;
            }
        }
        int idx = add_string_constant(c, node->data.ident.name);
        emit_op_u16(c, OP_GET_NAME, (uint16_t)idx, node->line);
        break;
    }

    case AST_ASSIGN: {
        compile_node(c, node->data.assign.expr);
        emit_assign_for_tos(c, node->data.assign.name, node->name_hash,
                            node->data.assign.local_only, node->line);
        break;
    }

    case AST_LIST_PATTERN_ASSIGN: {
        /* Compile RHS, unpack into N stack slots (element 0 at TOS), then
         * for each name: obs+set (peek-only) followed by OP_POP to expose
         * the next element. Skip the trailing POP on the last name so the
         * statement leaves exactly one value on TOS, matching AST_ASSIGN's
         * convention (the outer AST_PROGRAM/BLOCK emits inter-statement POPs). */
        int n = node->data.list_pattern_assign.name_count;
        compile_node(c, node->data.list_pattern_assign.expr);
        chunk_emit(c->chunk, OP_DESTRUCTURE_UNPACK, node->line);
        chunk_emit_u16(c->chunk, (uint16_t)n, node->line);
        adjust_stack(c, n - 1);  /* pop list (-1), push n elements (+n) */
        for (int i = 0; i < n; i++) {
            emit_assign_for_tos(c,
                node->data.list_pattern_assign.names[i],
                node->data.list_pattern_assign.name_hashes[i],
                0, node->line);
            if (i + 1 < n) emit(c, OP_POP, node->line);
        }
        break;
    }

    case AST_BINOP: {
        const char *op = node->data.binop.op;
        /* Short-circuit: and / or */
        if (strcmp(op, "and") == 0) {
            compile_node(c, node->data.binop.left);
            int jump = emit_jump(c, OP_JUMP_IF_FALSE_PEEK, node->line);
            emit(c, OP_POP, node->line);
            compile_node(c, node->data.binop.right);
            patch_jump(c, jump);
            break;
        }
        if (strcmp(op, "or") == 0) {
            compile_node(c, node->data.binop.left);
            int jump = emit_jump(c, OP_JUMP_IF_TRUE_PEEK, node->line);
            emit(c, OP_POP, node->line);
            compile_node(c, node->data.binop.right);
            patch_jump(c, jump);
            break;
        }
        /* Normal binary op */
        compile_node(c, node->data.binop.left);
        compile_node(c, node->data.binop.right);
        uint8_t opc = binop_to_opcode(op);
        if (opc) emit(c, opc, node->line);
        break;
    }

    case AST_UNARY: {
        compile_node(c, node->data.unary.operand);
        if (node->data.unary.op[0] == '-') emit(c, OP_NEG, node->line);
        else if (strcmp(node->data.unary.op, "not") == 0) emit(c, OP_NOT, node->line);
        else if (node->data.unary.op[0] == '~') emit(c, OP_BNOT, node->line);
        break;
    }

    case AST_PROGRAM: {
        for (int i = 0; i < node->data.program.count; i++) {
            compile_node(c, node->data.program.stmts[i]);
            if (i + 1 < node->data.program.count) {
                check_discarded_interrogative(node->data.program.stmts[i]);  /* #869 */
                emit(c, OP_POP, node->line);
            }
        }
        break;
    }

    case AST_BLOCK: {
        compile_block(c, node->data.block.stmts, node->data.block.count);
        break;
    }

    /* ---- Control flow (Stage 4) ---- */

    case AST_IF: {
        compile_node(c, node->data.cond.cond);
        int else_jump = emit_jump(c, OP_JUMP_IF_FALSE, node->line);
        /* condition was popped by JUMP_IF_FALSE. Save depth for else branch. */
        int depth_after_cond = c->stack_depth;
        compile_block(c, node->data.cond.if_body, node->data.cond.if_count);
        int end_jump = emit_jump(c, OP_JUMP, node->line);
        int depth_after_if = c->stack_depth;
        /* Reset depth to what it would be on the false branch */
        patch_jump(c, else_jump);
        c->stack_depth = depth_after_cond;
        if (node->data.cond.else_body && node->data.cond.else_count > 0) {
            compile_block(c, node->data.cond.else_body, node->data.cond.else_count);
        } else {
            emit(c, OP_NULL, node->line);
        }
        patch_jump(c, end_jump);
        /* Both branches should end at the same depth */
        if (c->stack_depth != depth_after_if) {
            fprintf(stderr, "[compiler] if/else stack mismatch: if=%d else=%d at line %d\n",
                    depth_after_if, c->stack_depth, node->line);
        }
        break;
    }

    case AST_LOOP: {
        /* Push loop context for break/continue */
        LoopCtx *lp = loop_push(c);
        lp->scope_depth = c->scope_depth;
        lp->has_fresh_env = 0; /* while-loops don't allocate per-iter envs */

        int loop_start = capture_loop_start(c);
        lp->continue_target = loop_start;

        int depth_at_loop = c->stack_depth;
        compile_node(c, node->data.loop.cond);
        int exit_jump = emit_jump(c, OP_JUMP_IF_FALSE, node->line);
        /* condition popped by JUMP_IF_FALSE */

        compile_block(c, node->data.loop.body, node->data.loop.body_count);
        emit(c, OP_POP, node->line); /* discard body result before next iteration */

        /* Loop check — observer stall+cap for observer-based conditions,
         * cap-only for plain loops (opt-in halting; see cond_is_observer_based). */
        int stall_op = cond_is_observer_based(node->data.loop.cond)
                           ? OP_LOOP_STALL_CHECK : OP_LOOP_CAP_CHECK;
        int stall_jump = emit_jump(c, stall_op, node->line);

        /* Reset depth to loop start for back-edge */
        c->stack_depth = depth_at_loop;
        emit_loop(c, loop_start, node->line);

        /* Exit path: condition was false or stall detected.
         * Set __loop_exit__ and __loop_iterations__ env vars.
         * For stall exit, LOOP_STALL_CHECK already set them.
         * For normal exit, emit code to set them. */
        patch_jump(c, exit_jump);
        /* Normal exit — set __loop_exit__ only; __loop_iterations__ already
         * set by LOOP_STALL_CHECK on each iteration */
        {
            int exit_idx = add_string_constant(c, "__loop_exit__");
            int normal_idx = add_string_constant(c, "normal");
            emit_op_u16(c, OP_CONST, (uint16_t)normal_idx, node->line);
            emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)exit_idx, node->line);
            emit(c, OP_POP, node->line);
        }
        patch_jump(c, stall_jump);
        c->stack_depth = depth_at_loop;

        /* Patch break jumps to land BEFORE OP_NULL so the break path also
         * pushes the loop result, matching the condition-exit/stall-exit paths
         * and the compile-time stack tracking (AST_BREAK's adjust_stack +1). */
        for (int i = 0; i < lp->break_count; i++)
            patch_jump(c, lp->break_jumps[i]);
        loop_pop(c);

        emit(c, OP_NULL, node->line); /* loop result */
        break;
    }

    case AST_FOR: {
        compile_node(c, node->data.forloop.iter);
        emit(c, OP_ITER_SETUP, node->line);

        /* Env-skip optimization: when this for-loop sits inside a function
         * and the body contains no closures and no nested rebinding of the
         * loop var, bind the loop var to a function-env slot via SET_LOCAL
         * and skip LOOP_ENV_FRESH/END entirely. Body reads resolve through
         * the existing resolve_local → GET_LOCAL path. This is purely a
         * perf win (no env_new per iteration, slot-cached writes) and also
         * makes ITER_NEXT the only remaining JIT blocker for hot for-range
         * loops. */
        const char *loop_var = node->data.forloop.var;
        uint32_t loop_var_hash = env_hash_name(loop_var);
        int can_skip_env = 0;
        int loop_var_slot = -1;
        if (c->enclosing) {
            int captured     = name_set_has(&c->captured, loop_var);
            int interrogated = name_set_has(&c->interrogated, loop_var);
            int in_outer     = name_in_enclosing(c, loop_var);
            int in_module    = c->module_names && name_set_has(c->module_names, loop_var);
            if (!captured && !interrogated && !in_outer && !in_module) {
                NameSet captured_here = {0};
                for (int i = 0; i < node->data.forloop.body_count; i++)
                    scan_for_captures(node->data.forloop.body[i], &captured_here);
                if (captured_here.count == 0) {
                    /* Reuse an existing slot for the loop var if there is one
                     * (sequential `for i ...; for i ...` or nested `for i in:
                     * for i in: ...`). Sharing the slot keeps body reads of
                     * the loop var (which compile to GET_LOCAL of the existing
                     * slot) consistent with the SET_LOCAL we emit per iter.
                     * If we used LOOP_ENV_FRESH+SET_NAME_LOCAL here instead,
                     * the body would still GET_LOCAL the stale outer slot. */
                    loop_var_slot = resolve_local(c, loop_var, loop_var_hash);
                    if (loop_var_slot < 0)
                        loop_var_slot = add_local(c, loop_var, loop_var_hash);
                    if (loop_var_slot >= 0) can_skip_env = 1;
                }
                name_set_free(&captured_here);
            }
        }

        /* Persisted-loop-env optimization: for any for-loop that still needs a
         * per-iteration env (can_skip_env didn't apply — notably every
         * module-scope loop, where the loop var and loop-locals must not leak),
         * create the loop env ONCE before the loop and CLEAR it at the top of
         * each iteration instead of allocating a fresh env every pass. The only
         * requirement is that the body define no closure: OP_CLOSURE captures
         * frame->env unconditionally, so a closure would pin the env we reuse.
         * Clearing each iteration makes every iteration identical to the fresh
         * env it replaces, so loop-var/loop-local/shadow semantics are
         * unchanged (the env is still torn down after the loop — the loop var
         * does not leak). Net: one env_new + one env_decref per loop instead of
         * one per iteration. */
        int can_persist_env = 0;
        if (!can_skip_env) {
            int body_has_closure = 0;
            for (int i = 0; i < node->data.forloop.body_count && !body_has_closure; i++)
                if (ast_has_closure(node->data.forloop.body[i])) body_has_closure = 1;
            can_persist_env = !body_has_closure;
        }

        /* Overwrite tier: when the body provably creates no loop-local binding
         * (every assignment is an outer mutation), the loop var can simply be
         * overwritten each iteration with no CLEAR, so binding_version stays
         * stable and the outer-var inline cache stays hot — capturing the IC
         * win on top of the allocation win. Restricted to module top-level
         * loops, where "bound before the loop" is decidable. Anything not
         * provably safe stays on the persist+clear path. */
        int persist_overwrite = 0;
        if (can_persist_env && !c->enclosing && c->root_ast) {
            NameSet bound = {0};
            if (collect_bound_before_loop(c->root_ast, node, &bound)) {
                int safe = 1;
                for (int i = 0; i < node->data.forloop.body_count && safe; i++)
                    if (!subtree_overwrite_safe(node->data.forloop.body[i], &bound, c->env))
                        safe = 0;
                persist_overwrite = safe;
            }
            name_set_free(&bound);
        }

        LoopCtx *lp = loop_push(c);
        lp->scope_depth = c->scope_depth;
        /* break emits its own per-iteration LOOP_ENV_END only in the
         * classic fresh-per-iteration path. The skip path has no env; the
         * persist path has a single LOOP_ENV_END at the loop exit that
         * break falls through to. */
        lp->has_fresh_env = (can_skip_env || can_persist_env) ? 0 : 1;

        int depth_before_loop = c->stack_depth;
        /* Persist: create the reused loop env once, before the back-edge target
         * so continue/JUMP_BACK never re-create it. */
        if (can_persist_env) emit(c, OP_LOOP_ENV_FRESH, node->line);
        int loop_start = capture_loop_start(c);
        lp->continue_target = loop_start;

        int exit_jump = emit_jump(c, OP_ITER_NEXT, node->line);
        /* ITER_NEXT pushes element on non-exit (+1) */

        if (can_skip_env) {
            /* Bind loop var to a function-env slot. SET_LOCAL leaves the
             * value on the stack (matching SET_NAME_LOCAL's convention),
             * so the POP below still applies. */
            emit_op_u16(c, OP_SET_LOCAL, (uint16_t)loop_var_slot, node->line);
            emit(c, OP_POP, node->line);
        } else if (can_persist_env) {
            /* Reuse the loop env created once above. Clear tier: reset its
             * bindings for this iteration. Overwrite tier (provably no
             * loop-local): skip the CLEAR — the SET_NAME_LOCAL below overwrites
             * the loop var in place (no binding_version bump), keeping the
             * outer-var IC hot. */
            if (!persist_overwrite) emit(c, OP_LOOP_ENV_CLEAR, node->line);
            int var_idx = add_string_constant(c, loop_var);
            emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)var_idx, node->line);
            emit(c, OP_POP, node->line);
        } else {
            /* Create fresh loop env for each iteration (required for correct scoping) */
            emit(c, OP_LOOP_ENV_FRESH, node->line);
            int var_idx = add_string_constant(c, loop_var);
            emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)var_idx, node->line);
            emit(c, OP_POP, node->line);
        }

        compile_block(c, node->data.forloop.body, node->data.forloop.body_count);
        emit(c, OP_POP, node->line); /* discard body result */

        if (!can_skip_env && !can_persist_env)
            emit(c, OP_LOOP_ENV_END, node->line);

        /* Reset depth for back-edge (same as loop start) */
        c->stack_depth = depth_before_loop;
        emit_loop(c, loop_start, node->line);

        /* Break lands here — env already cleaned by break's LOOP_ENV_END
         * when has_fresh_env=1; in the env-skip path AST_BREAK saw
         * has_fresh_env=0 and skipped the cleanup. */
        for (int i = 0; i < lp->break_count; i++)
            patch_jump(c, lp->break_jumps[i]);

        /* Exit path: ITER_NEXT jumped here (no element pushed), or break jumped here */
        patch_jump(c, exit_jump);
        c->stack_depth = depth_before_loop; /* iterator state still on stack */
        /* Persist: a single LOOP_ENV_END tears down the reused env. Both the
         * normal exit (ITER_NEXT exhausted) and break converge here with
         * frame->env still the loop env, so both restore the parent exactly
         * once. */
        if (can_persist_env) emit(c, OP_LOOP_ENV_END, node->line);
        emit(c, OP_POP, node->line); /* pop iterator state */
        emit(c, OP_NULL, node->line); /* for-loop result */

        loop_pop(c);
        break;
    }

    case AST_BREAK: {
        if (c->loop_depth > 0) {
            LoopCtx *lp = c->loops[c->loop_depth - 1];
            /* Unwind any `try` blocks this break jumps out of, innermost
             * first. Without this the handler stays registered after the
             * loop: a later error jumped back into the dead catch body with
             * a stale catch_bp, and the restored env lost its bindings
             * (#726). Mirrors the loop-env cleanup below. */
            for (int t = c->try_depth; t > lp->try_depth_at_entry; t--)
                emit(c, OP_TRY_END, node->line);
            /* #871: and leave every `unobserved:` block being jumped out of.
             * Without this the runtime depth stayed elevated for the rest of
             * the PROCESS — the observer silently stopped recording, so every
             * later `report` read `equilibrium` on a moving value and every
             * predicate answered about a frozen trajectory. */
            for (int u = c->unobs_depth; u > lp->unobs_depth_at_entry; u--)
                emit(c, OP_UNOBSERVED_END, node->line);
            /* Clean up loop env before jumping out, but ONLY if the loop allocated
             * a per-iteration env. While-loops don't — emitting OP_LOOP_ENV_END
             * there would free the surrounding env (often the global one). */
            if (lp->has_fresh_env)
                emit(c, OP_LOOP_ENV_END, node->line);
            /* The jump must ALWAYS pair with the env cleanup above — a capped
             * break that emitted LOOP_ENV_END and then fell through double-freed
             * the loop env (#335). */
            loop_add_break(lp, emit_jump(c, OP_JUMP, node->line));
            /* Phantom +1 for stack accounting (dead code follows jump) */
            adjust_stack(c, 1);
        } else {
            /* Break outside any loop: a compile error (#337). This used to
             * be a silent no-op, turning a mis-indented break into a loop
             * that never exits. Emit OP_NULL so compilation continues with
             * balanced stack accounting; the post-compile g_parse_errors
             * gate aborts before execution. */
            fprintf(stderr, "Compile error line %d: 'break' outside a loop\n",
                    node->line);
            eigs_record_first_error(node->line, "'break' outside a loop");
            g_parse_errors++;
            emit(c, OP_NULL, node->line);
        }
        break;
    }

    case AST_CONTINUE: {
        if (c->loop_depth > 0) {
            LoopCtx *lp = c->loops[c->loop_depth - 1];
            /* Same handler unwinding as break (#726) — a `continue` inside a
             * try re-entered TRY_BEGIN each iteration while its TRY_END never
             * ran, so try_count climbed until it pinned at the cap. */
            for (int t = c->try_depth; t > lp->try_depth_at_entry; t--)
                emit(c, OP_TRY_END, node->line);
            /* #871: and leave every `unobserved:` block being jumped out of.
             * Without this the runtime depth stayed elevated for the rest of
             * the PROCESS — the observer silently stopped recording, so every
             * later `report` read `equilibrium` on a moving value and every
             * predicate answered about a frozen trajectory. */
            for (int u = c->unobs_depth; u > lp->unobs_depth_at_entry; u--)
                emit(c, OP_UNOBSERVED_END, node->line);
            /* End this iteration's env before jumping back, exactly as break
             * does below — the back-edge target sits BEFORE the per-iteration
             * OP_LOOP_ENV_FRESH, so without this the env is never torn down:
             * each continue nests another env under the live one, and a
             * continue on the final iteration leaves frame->env pointing at
             * the loop env for everything that follows. At module top level
             * that meant every definition after the loop landed in the leaked
             * loop env instead of the module env and silently vanished from
             * the export dict (#722). Same has_fresh_env gate as break: the
             * env-skip path has no env, and the persist path ends its single
             * reused env at the loop exit. */
            if (lp->has_fresh_env)
                emit(c, OP_LOOP_ENV_END, node->line);
            emit_loop(c, lp->continue_target, node->line);
            /* Phantom +1 for stack accounting (dead code follows jump) */
            adjust_stack(c, 1);
        } else {
            /* Continue outside any loop: a compile error (#337), same
             * rationale as break above. */
            fprintf(stderr, "Compile error line %d: 'continue' outside a loop\n",
                    node->line);
            eigs_record_first_error(node->line, "'continue' outside a loop");
            g_parse_errors++;
            emit(c, OP_NULL, node->line);
        }
        break;
    }

    /* ---- Functions (Stage 5) ---- */

    case AST_FUNC: {
        /* Compile function body into nested chunk */
        EigsChunk *fn_chunk = chunk_new(node->data.func.name);
        fn_chunk->compiler_scanned = 1;   /* #830: this scan armed its names */
        fn_chunk->param_count = node->data.func.param_count;
        fn_chunk->first_default = node->data.func.first_default;
        fn_chunk->src = c->chunk->src;           /* #407: share the unit's blob */
        srcbuf_incref(fn_chunk->src);

        Compiler fn_compiler;
        memset(&fn_compiler, 0, sizeof(fn_compiler));
        fn_compiler.locals = xcalloc_array(MAX_LOCALS, sizeof(Local));
        fn_compiler.chunk = fn_chunk;
        fn_compiler.enclosing = c;
        fn_compiler.env = c->env;
        fn_compiler.last_line = -1;  /* #174: force first OP_LINE in this chunk */
        fn_compiler.param_count = node->data.func.param_count;
        fn_compiler.module_names = c->module_names;
        fn_compiler.dispatch_rebound = c->dispatch_rebound;

        /* Escape analysis: find names captured by nested closures + names that
         * are interrogated (who/when is x). These stay on the slow name path. */
        for (int i = 0; i < node->data.func.body_count; i++) {
            scan_for_captures(node->data.func.body[i], &fn_compiler.captured);
            scan_for_interrogated(node->data.func.body[i], &fn_compiler.interrogated);
            scan_for_env_bound(node->data.func.body[i], &fn_compiler.env_bound);
        }
        /* Function's own params are never "captured by themselves" */
        for (int i = 0; i < node->data.func.param_count; i++)
            name_set_remove(&fn_compiler.captured, node->data.func.params[i]);

        /* Store param names in chunk AND add as compiler locals.
         * Params are at env slots 0..param_count-1, bound by OP_CALL. */
        fn_chunk->local_names = xcalloc(node->data.func.param_count, sizeof(char *));
        fn_chunk->local_count = node->data.func.param_count;
        for (int i = 0; i < node->data.func.param_count; i++) {
            fn_chunk->local_names[i] = strdup(node->data.func.params[i]);
            uint32_t h = env_hash_name(node->data.func.params[i]);
            add_local(&fn_compiler, node->data.func.params[i], h);
        }

        /* Default-param prologue: for each trailing param with a default,
         * emit OP_DEFAULT_PARAM <slot> <skip>; <default expr>; OP_SET_LOCAL;
         * OP_POP. Skip target is just past OP_POP. The opcode reads
         * frame->call_argc — if argc > slot, jump skip (default already
         * supplied by caller). Else fall through (run the default). */
        if (node->data.func.param_defaults) {
            for (int i = node->data.func.first_default;
                 i < node->data.func.param_count; i++) {
                ASTNode *dflt = node->data.func.param_defaults[i];
                if (!dflt) continue;  /* defensive; parser enforces trailing */
                int line = dflt->line ? dflt->line : node->line;
                chunk_emit(fn_chunk, OP_DEFAULT_PARAM, line);
                chunk_emit_u16(fn_chunk, (uint16_t)i, line);
                int skip_patch = fn_chunk->code_len;
                chunk_emit_u16(fn_chunk, 0xFFFF, line);
                compile_node(&fn_compiler, dflt);
                emit_op_u16(&fn_compiler, OP_SET_LOCAL, (uint16_t)i, line);
                chunk_emit(fn_chunk, OP_POP, line);
                adjust_stack(&fn_compiler, -1);
                chunk_patch_jump(fn_chunk, skip_patch);
            }
        }

        compile_block(&fn_compiler, node->data.func.body, node->data.func.body_count);

        /* Ensure function always returns */
        emit(&fn_compiler, OP_RETURN_NULL, node->line);

        /* Writeback: extend chunk->local_count to include any non-param locals
         * the compiler added via add_local during body compilation. The VM uses
         * this to pre-allocate env slots at call time so OP_SET_LOCAL writes land. */
        if (fn_compiler.local_count > fn_chunk->local_count) {
            int new_total = fn_compiler.local_count;
            fn_chunk->local_names = realloc(fn_chunk->local_names, new_total * sizeof(char *));
            for (int i = fn_chunk->local_count; i < new_total; i++)
                fn_chunk->local_names[i] = strdup(fn_compiler.locals[i].name);
            fn_chunk->local_count = new_total;
        }

        name_set_free(&fn_compiler.captured);
        name_set_free(&fn_compiler.interrogated);
        name_set_free(&fn_compiler.env_bound);
        free(fn_compiler.locals);

        chunk_scan_leaf_accessor(fn_chunk);  /* #366 */

        int fn_idx = chunk_add_function(c->chunk, fn_chunk);
        emit_op_u16(c, OP_CLOSURE, (uint16_t)fn_idx, node->line);

        /* Bind function name in current scope */
        int name_idx = add_string_constant(c, node->data.func.name);
        emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)name_idx, node->line);
        break;
    }

    case AST_LAMBDA: {
        EigsChunk *fn_chunk = chunk_new("<lambda>");
        fn_chunk->compiler_scanned = 1;   /* #830: this scan armed its names */
        fn_chunk->param_count = node->data.lambda.param_count;
        fn_chunk->first_default = node->data.lambda.param_count;  /* lambdas don't support defaults */
        fn_chunk->src = c->chunk->src;           /* #407: share the unit's blob */
        srcbuf_incref(fn_chunk->src);

        Compiler fn_compiler;
        memset(&fn_compiler, 0, sizeof(fn_compiler));
        fn_compiler.locals = xcalloc_array(MAX_LOCALS, sizeof(Local));
        fn_compiler.chunk = fn_chunk;
        fn_compiler.enclosing = c;
        fn_compiler.env = c->env;
        fn_compiler.last_line = -1;  /* #174: force first OP_LINE in this chunk */
        fn_compiler.param_count = node->data.lambda.param_count;
        fn_compiler.module_names = c->module_names;
        fn_compiler.dispatch_rebound = c->dispatch_rebound;

        scan_for_captures(node->data.lambda.body, &fn_compiler.captured);
        scan_for_interrogated(node->data.lambda.body, &fn_compiler.interrogated);
        scan_for_env_bound(node->data.lambda.body, &fn_compiler.env_bound);
        for (int i = 0; i < node->data.lambda.param_count; i++) {
            name_set_remove(&fn_compiler.captured, node->data.lambda.params[i]);
        }

        fn_chunk->local_names = xcalloc(node->data.lambda.param_count, sizeof(char *));
        fn_chunk->local_count = node->data.lambda.param_count;
        for (int i = 0; i < node->data.lambda.param_count; i++) {
            fn_chunk->local_names[i] = strdup(node->data.lambda.params[i]);
            uint32_t h = env_hash_name(node->data.lambda.params[i]);
            add_local(&fn_compiler, node->data.lambda.params[i], h);
        }

        /* Lambda body is a single expression — compile and return it */
        compile_node(&fn_compiler, node->data.lambda.body);
        emit(&fn_compiler, OP_RETURN, node->line);

        if (fn_compiler.local_count > fn_chunk->local_count) {
            int new_total = fn_compiler.local_count;
            fn_chunk->local_names = realloc(fn_chunk->local_names, new_total * sizeof(char *));
            for (int i = fn_chunk->local_count; i < new_total; i++)
                fn_chunk->local_names[i] = strdup(fn_compiler.locals[i].name);
            fn_chunk->local_count = new_total;
        }

        name_set_free(&fn_compiler.captured);
        name_set_free(&fn_compiler.interrogated);
        name_set_free(&fn_compiler.env_bound);
        free(fn_compiler.locals);

        chunk_scan_leaf_accessor(fn_chunk);  /* #366 */

        int fn_idx = chunk_add_function(c->chunk, fn_chunk);
        emit_op_u16(c, OP_CLOSURE, (uint16_t)fn_idx, node->line);
        break;
    }

    case AST_RETURN: {
        if (node->data.ret.expr)
            compile_node(c, node->data.ret.expr);
        /* Leave every enclosing `try` before the frame goes away. The frame's
         * try_count dies with the CallFrame, but g_try_depth is a PROCESS
         * global: a `return` from inside a try leaked it permanently, and
         * rt_error's `g_try_depth == 0` gate then swallowed the message of
         * every later uncaught error in the process (#726). */
        for (int t = c->try_depth; t > 0; t--)
            emit(c, OP_TRY_END, node->line);
        /* #871: same for `unobserved:` — a `return` from inside one leaked the
         * runtime depth permanently and killed the observer process-wide. */
        for (int u = c->unobs_depth; u > 0; u--)
            emit(c, OP_UNOBSERVED_END, node->line);
        emit(c, node->data.ret.expr ? OP_RETURN : OP_RETURN_NULL, node->line);
        break;
    }

    case AST_RELATION: {
        /* Function call: f of [a, b] or f of arg */
        ASTNode *fn_node = node->data.relation.left;
        ASTNode *arg_node = node->data.relation.right;

        {
            /* `<predicate> of <ident>` (converged/stable/improving/oscillating/
             * diverging/equilibrium): classify the NAMED binding's slot
             * trajectory — not the global last-observed alias the bare predicate
             * reads. Parallels `report of x`; the operand removes the ambiguity. */
            if (fn_node && fn_node->type == AST_PREDICATE &&
                arg_node && arg_node->type == AST_IDENT) {
                uint16_t pkind = (uint16_t)fn_node->data.predicate.kind;
                int pslot = resolve_observer_operand_slot(c, arg_node);
                if (pslot >= 0) {
                    emit_op_u16_u16(c, OP_PREDICATE_SLOT, pkind, (uint16_t)pslot, node->line);
                    break;
                }
                int pnidx = add_string_constant(c, arg_node->data.ident.name);
                emit_op_u16_u16(c, OP_PREDICATE_NAME, pkind, (uint16_t)pnidx, node->line);
                break;
            }
            if (fn_node && fn_node->type == AST_IDENT &&
                strcmp(fn_node->data.ident.name, "report") == 0 &&
                arg_node && arg_node->type == AST_IDENT) {
                int rslot = resolve_observer_operand_slot(c, arg_node);
                if (rslot >= 0) { emit_op_u16(c, OP_REPORT_SLOT, (uint16_t)rslot, node->line); break; }
                /* Phase-3 B: not a local — report the name's binding via its slot. */
                int rnidx = add_string_constant(c, arg_node->data.ident.name);
                emit_op_u16(c, OP_REPORT_NAME, (uint16_t)rnidx, node->line);
                break;
            }
            if (fn_node && fn_node->type == AST_IDENT &&
                strcmp(fn_node->data.ident.name, "report_value") == 0 &&
                arg_node && arg_node->type == AST_IDENT) {
                /* #294 `report_value of <ident>` — classify the binding's VALUE
                 * trajectory (parallel to report, which classifies entropy). */
                int rslot = resolve_observer_operand_slot(c, arg_node);
                if (rslot >= 0) { emit_op_u16(c, OP_REPORT_VALUE_SLOT, (uint16_t)rslot, node->line); break; }
                int rnidx = add_string_constant(c, arg_node->data.ident.name);
                emit_op_u16(c, OP_REPORT_VALUE_NAME, (uint16_t)rnidx, node->line);
                break;
            }
            if (fn_node && fn_node->type == AST_IDENT &&
                strcmp(fn_node->data.ident.name, "trajectory") == 0 &&
                arg_node && arg_node->type == AST_IDENT) {
                /* #421 `trajectory of <ident>` — snapshot the binding's observer
                 * windows into a dict VALUE that survives a call boundary (the
                 * slot itself is binding-identity). `classify of t` reads it. */
                int tslot = resolve_observer_operand_slot(c, arg_node);
                if (tslot >= 0) { emit_op_u16(c, OP_TRAJECTORY_SLOT, (uint16_t)tslot, node->line); break; }
                int tnidx = add_string_constant(c, arg_node->data.ident.name);
                emit_op_u16(c, OP_TRAJECTORY_NAME, (uint16_t)tnidx, node->line);
                break;
            }
            /* #262 Phase-3 D: `observe of <ident>` reads the binding's slot
             * trajectory, parallel to report — the value path no longer carries
             * observer state on the Value object. Non-ident operands fall
             * through to the builtin_observe call below. */
            if (fn_node && fn_node->type == AST_IDENT &&
                strcmp(fn_node->data.ident.name, "observe") == 0 &&
                arg_node && arg_node->type == AST_IDENT) {
                int oslot = resolve_observer_operand_slot(c, arg_node);
                if (oslot >= 0) { emit_op_u16(c, OP_OBSERVE_VALUE_SLOT, (uint16_t)oslot, node->line); break; }
                int onidx = add_string_constant(c, arg_node->data.ident.name);
                emit_op_u16(c, OP_OBSERVE_VALUE_NAME, (uint16_t)onidx, node->line);
                break;
            }
        }

        /* Optimize: dispatch of [table, key, arg] → OP_DISPATCH.
         * #459 guards, all fail-open to the semantically identical normal
         * call path: (a) the unit statically binds `dispatch` or references
         * `eval` (dispatch_rebound); (b) `dispatch` is already rebound in
         * the compile-time env — a prior REPL line or embed eval (an absent
         * binding stays on the fast path: some embeds run without
         * register_builtins); (c) the parenthesized #355 form is ONE
         * argument, not three (bare-list-only, matching the #405 rule). */
        if (fn_node && fn_node->type == AST_IDENT &&
            strcmp(fn_node->data.ident.name, "dispatch") == 0 &&
            !c->dispatch_rebound &&
            arg_node && arg_node->type == AST_LIST &&
            !arg_node->parenthesized &&
            arg_node->data.list.count == 3) {
            compile_node(c, arg_node->data.list.elems[0]); /* table */
            compile_node(c, arg_node->data.list.elems[1]); /* key */
            compile_node(c, arg_node->data.list.elems[2]); /* arg */
            emit(c, OP_DISPATCH, node->line);
            /* #174: dispatch invokes a callee — same reset as emit_call. */
            c->last_line = -1;
            break;
        }

        compile_node(c, fn_node);

        if (arg_node && arg_node->type == AST_LIST && !arg_node->parenthesized) {
            /* #405: a bare literal list after `of` is ALWAYS an argument
             * list, at every count — `f of []` is zero args, `f of [x]`
             * is one arg (x itself, not a 1-element list), `f of [a, b]`
             * is two. #355's parenthesized form `f of ([x])` remains the
             * pass-a-literal-list-whole escape hatch. */
            for (int i = 0; i < arg_node->data.list.count; i++)
                compile_node(c, arg_node->data.list.elems[i]);
            emit_call(c, (uint16_t)arg_node->data.list.count, node->line);
        } else {
            /* Single arg */
            compile_node(c, arg_node);
            emit_call(c, 1, node->line);
        }
        break;
    }

    /* ---- Data structures (Stage 6) ---- */

    case AST_LIST: {
        for (int i = 0; i < node->data.list.count; i++)
            compile_node(c, node->data.list.elems[i]);
        emit_list(c, (uint16_t)node->data.list.count, node->line);
        break;
    }

    case AST_DICT: {
        for (int i = 0; i < node->data.dict.count; i++) {
            compile_node(c, node->data.dict.keys[i]);
            compile_node(c, node->data.dict.vals[i]);
        }
        emit_dict(c, (uint16_t)node->data.dict.count, node->line);
        break;
    }

    case AST_INDEX: {
        /* Superinstruction: local[const_int] → OP_LOCAL_IDX_GET */
        if (c->enclosing &&
            node->data.index.target->type == AST_IDENT &&
            node->data.index.index->type == AST_NUM) {
            double dv = node->data.index.index->data.num;
            int iv = (int)dv;
            if (iv == dv && iv >= 0 && iv <= 0xFFFF) {
                const char *tname = node->data.index.target->data.ident.name;
                uint32_t th = node->data.index.target->name_hash;
                if (th == 0) th = env_hash_name(tname);
                int slot = resolve_local(c, tname, th);
                if (slot >= 0) {
                    emit_op_u16_u16(c, OP_LOCAL_IDX_GET, (uint16_t)slot, (uint16_t)iv, node->line);
                    break;
                }
            }
        }
        compile_node(c, node->data.index.target);
        compile_node(c, node->data.index.index);
        emit(c, OP_INDEX_GET, node->line);
        break;
    }

    case AST_SLICE: {
        compile_node(c, node->data.slice.target);
        if (node->data.slice.start) compile_node(c, node->data.slice.start);
        else                        emit(c, OP_NULL, node->line);
        if (node->data.slice.end)   compile_node(c, node->data.slice.end);
        else                        emit(c, OP_NULL, node->line);
        emit(c, OP_SLICE_GET, node->line);
        break;
    }

    case AST_INDEX_ASSIGN: {
        compile_node(c, node->data.index_assign.target);
        compile_node(c, node->data.index_assign.index);
        if (node->data.index_assign.compound_op[0]) {
            /* Compound: target index → DUP2 → INDEX_GET → expr → BINOP → INDEX_SET */
            emit(c, OP_DUP2, node->line);
            emit(c, OP_INDEX_GET, node->line);
            compile_node(c, node->data.index_assign.expr);
            uint8_t op = binop_to_opcode(node->data.index_assign.compound_op);
            emit(c, op, node->line);
        } else {
            compile_node(c, node->data.index_assign.expr);
        }
        emit(c, OP_INDEX_SET, node->line);
        break;
    }

    case AST_DOT: {
        /* Superinstruction: local[const].field → OP_LOCAL_IDX_DOT_GET */
        if (c->enclosing && node->data.dot.target->type == AST_INDEX) {
            ASTNode *idx_node = node->data.dot.target;
            if (idx_node->data.index.target->type == AST_IDENT &&
                idx_node->data.index.index->type == AST_NUM) {
                double dv = idx_node->data.index.index->data.num;
                int iv = (int)dv;
                if (iv == dv && iv >= 0 && iv <= 0xFFFF) {
                    const char *tname = idx_node->data.index.target->data.ident.name;
                    uint32_t th = idx_node->data.index.target->name_hash;
                    if (th == 0) th = env_hash_name(tname);
                    int slot = resolve_local(c, tname, th);
                    if (slot >= 0) {
                        int name_idx = add_string_constant(c, node->data.dot.key);
                        emit_op_u16_u16_u16(c, OP_LOCAL_IDX_DOT_GET,
                            (uint16_t)slot, (uint16_t)iv, (uint16_t)name_idx, node->line);
                        break;
                    }
                }
            }
        }
        /* Superinstruction: if target is a local, fuse GET_LOCAL + DOT_GET */
        if (c->enclosing && node->data.dot.target->type == AST_IDENT) {
            const char *tname = node->data.dot.target->data.ident.name;
            uint32_t th = node->data.dot.target->name_hash;
            if (th == 0) th = env_hash_name(tname);
            int slot = resolve_local(c, tname, th);
            if (slot >= 0) {
                int idx = add_string_constant(c, node->data.dot.key);
                emit_op_u16_u16(c, OP_LOCAL_DOT_GET, (uint16_t)slot, (uint16_t)idx, node->line);
                break;
            }
        }
        compile_node(c, node->data.dot.target);
        int idx = add_string_constant(c, node->data.dot.key);
        emit_op_u16(c, OP_DOT_GET, (uint16_t)idx, node->line);
        break;
    }

    case AST_DOT_ASSIGN: {
        /* Superinstruction: local[const].field = expr → OP_LOCAL_IDX_DOT_SET */
        if (c->enclosing && node->data.dot_assign.target->type == AST_INDEX) {
            ASTNode *idx_node = node->data.dot_assign.target;
            if (idx_node->data.index.target->type == AST_IDENT &&
                idx_node->data.index.index->type == AST_NUM) {
                double dv = idx_node->data.index.index->data.num;
                int iv = (int)dv;
                if (iv == dv && iv >= 0 && iv <= 0xFFFF) {
                    const char *tname = idx_node->data.index.target->data.ident.name;
                    uint32_t th = idx_node->data.index.target->name_hash;
                    if (th == 0) th = env_hash_name(tname);
                    int slot = resolve_local(c, tname, th);
                    if (slot >= 0) {
                        compile_node(c, node->data.dot_assign.expr);
                        int name_idx = add_string_constant(c, node->data.dot_assign.key);
                        emit_op_u16_u16_u16(c, OP_LOCAL_IDX_DOT_SET,
                            (uint16_t)slot, (uint16_t)iv, (uint16_t)name_idx, node->line);
                        break;
                    }
                }
            }
        }
        /* Superinstruction: if target is a local, fuse GET_LOCAL + DOT_SET */
        if (c->enclosing && node->data.dot_assign.target->type == AST_IDENT) {
            const char *tname = node->data.dot_assign.target->data.ident.name;
            uint32_t th = node->data.dot_assign.target->name_hash;
            if (th == 0) th = env_hash_name(tname);
            int slot = resolve_local(c, tname, th);
            if (slot >= 0) {
                compile_node(c, node->data.dot_assign.expr);
                int idx = add_string_constant(c, node->data.dot_assign.key);
                emit_op_u16_u16(c, OP_LOCAL_DOT_SET, (uint16_t)slot, (uint16_t)idx, node->line);
                break;
            }
        }
        compile_node(c, node->data.dot_assign.target);
        compile_node(c, node->data.dot_assign.expr);
        int idx = add_string_constant(c, node->data.dot_assign.key);
        emit_op_u16(c, OP_DOT_SET, (uint16_t)idx, node->line);
        break;
    }

    case AST_LISTCOMP: {
        emit(c, OP_LISTCOMP_BEGIN, node->line);
        compile_node(c, node->data.listcomp.iter);
        emit(c, OP_ITER_SETUP, node->line);

        int loop_start = capture_loop_start(c);
        int exit_jump = emit_jump(c, OP_ITER_NEXT, node->line);

        /* Bind loop var via Env */
        {
            int var_idx = add_string_constant(c, node->data.listcomp.var);
            emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)var_idx, node->line);
            emit(c, OP_POP, node->line);
        }

        /* Optional filter */
        int filter_jump = -1;
        int depth_before_filter = c->stack_depth;
        if (node->data.listcomp.filter) {
            compile_node(c, node->data.listcomp.filter);
            filter_jump = emit_jump(c, OP_JUMP_IF_FALSE, node->line);
            /* JUMP_IF_FALSE popped the condition */
        }

        /* Expression to collect */
        compile_node(c, node->data.listcomp.expr);
        emit(c, OP_LISTCOMP_APPEND, node->line);

        if (filter_jump >= 0) {
            int skip = emit_jump(c, OP_JUMP, node->line);
            /* False path: JUMP_IF_FALSE already popped condition */
            patch_jump(c, filter_jump);
            c->stack_depth = depth_before_filter;
            patch_jump(c, skip);
        }

        c->stack_depth = depth_before_filter;
        emit_loop(c, loop_start, node->line);

        patch_jump(c, exit_jump);
        emit(c, OP_POP, node->line); /* pop iterator state */
        /* listcomp accumulator is now TOS */
        break;
    }

    /* ---- Error handling / observer (Stage 7) ---- */

    case AST_TRY: {
        /* The VM's per-frame handler stack is a fixed MAX_TRY_HANDLERS array.
         * Past it, TRY_BEGIN used to register nothing while its TRY_END still
         * popped — silently mis-pairing every handler from there out, so a
         * raise took the WRONG catch with no diagnostic (#726). Reject at
         * compile time instead, the way `break` outside a loop is (#337). */
        if (c->try_depth >= MAX_TRY_HANDLERS) {
            fprintf(stderr, "Compile error line %d: 'try' nested more than %d "
                            "deep (handler stack limit)\n",
                    node->line, MAX_TRY_HANDLERS);
            eigs_record_first_error(node->line, "'try' nested too deep");
            g_parse_errors++;
            emit(c, OP_NULL, node->line);
            break;
        }
        int catch_jump = emit_jump(c, OP_TRY_BEGIN, node->line);
        c->try_depth++;
        compile_block(c, node->data.trycatch.try_body, node->data.trycatch.try_count);
        c->try_depth--;
        emit(c, OP_TRY_END, node->line);
        int end_jump = emit_jump(c, OP_JUMP, node->line);

        patch_jump(c, catch_jump);
        /* Error message string is on stack, pushed by VM error handler */
        if (node->data.trycatch.err_name) {
            int idx = add_string_constant(c, node->data.trycatch.err_name);
            emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)idx, node->line);
            emit(c, OP_POP, node->line);
        }
        compile_block(c, node->data.trycatch.catch_body, node->data.trycatch.catch_count);
        patch_jump(c, end_jump);
        break;
    }

    case AST_INTERROGATE: {
        int kind = node->data.interrogate.kind;
        ASTNode *expr = node->data.interrogate.expr;
        ASTNode *at_expr = node->data.interrogate.at_expr;

        /* `prev of x` and every `at <line>` form answer from the
         * per-assign history — enable recording. #827: arm only the NAME
         * this query can reach. Both history-reading forms compile to a
         * NAMED opcode carrying a compile-time identifier, so the reachable
         * set is exact; a non-ident operand never reads the history at all
         * (bare OP_INTERROGATE) but arms the wildcard anyway — widening is
         * the safe direction. */
        ASTNode *when_expr = node->data.interrogate.when_expr;

        if (kind == 6 || at_expr || when_expr) {
            if (expr && expr->type == AST_IDENT)
                trace_arm_history_name(expr->data.ident.name);
            else
                trace_arm_history_all();
        }

        /* #868: `when <N>` addresses an occurrence, which needs the ring.
         * Armed per-name and only here — see trace.h on why this tier has no
         * wildcard. A non-name operand has no binding and therefore no
         * occurrence sequence, so it is an error rather than a silently
         * dropped qualifier. */
        if (when_expr) {
            if (expr && expr->type == AST_IDENT) {
                trace_arm_occurrences_name(expr->data.ident.name);
            } else {
                fprintf(stderr,
                    "Compile error line %d: 'when <n>' requires a variable name\n",
                    node->line);
                eigs_record_first_error(node->line,
                    "'when <n>' requires a variable name");
                g_parse_errors++;
            }
        }

        if (when_expr && expr && expr->type == AST_IDENT) {
            /* `<kw> is x when <expr>` — push the ordinal, emit the WHEN op.
             * Same shape as the AT form below: the operand's value is never
             * needed, only its compile-time name. */
            if (kind >= 3 && kind <= 5)
                g_trace_obs_hist = 1;   /* enable observer-state capture */
            compile_node(c, when_expr);
            int name_idx = add_string_constant(c, expr->data.ident.name);
            emit_op_u16_u16(c, OP_INTERROGATE_NAMED_WHEN,
                            (uint16_t)kind, (uint16_t)name_idx, node->line);
            break;
        }

        if (at_expr && expr && expr->type == AST_IDENT) {
            /* `<kw> is x at <expr>` — operand value is not needed; only
             * the name (compile-time known). Push line, emit AT op. */
            if (kind >= 3 && kind <= 5)
                g_trace_obs_hist = 1;   /* enable observer-state capture */
            compile_node(c, at_expr);
            int name_idx = add_string_constant(c, expr->data.ident.name);
            emit_op_u16_u16(c, OP_INTERROGATE_NAMED_AT,
                            (uint16_t)kind, (uint16_t)name_idx, node->line);
            break;
        }

        compile_node(c, expr);
        /* #262 Phase-3 A: where/why/how (3/4/5) on a bare ident also go named,
         * so they read the binding's slot — but only under the compile-time
         * flag, so flag-off bytecode is byte-identical. */
        int named_obs = 0;
        if (kind >= 3 && kind <= 5 && expr->type == AST_IDENT) {
            named_obs = 1;
        }
        if (((kind == 1 || kind == 2 || kind == 6) || named_obs) && expr->type == AST_IDENT) {
            /* who/when/prev (always) + where/why/how (flagged) with known
             * binding name: emit name index */
            int name_idx = add_string_constant(c, expr->data.ident.name);
            emit_op_u16_u16(c, OP_INTERROGATE_NAMED, (uint16_t)kind, (uint16_t)name_idx, node->line);
        } else {
            emit_op_u16(c, OP_INTERROGATE, (uint16_t)kind, node->line);
        }
        break;
    }

    case AST_PREDICATE: {
        emit_op_u16(c, OP_PREDICATE, (uint16_t)node->data.predicate.kind, node->line);
        break;
    }

    case AST_UNOBSERVED: {
        /* Module-level slot promotion (Part B): if we're at module scope and
         * the optimization is enabled, find names assigned inside this block
         * that never escape it, and promote them to frame slots. */
        if (g_compile_module_slots && !c->enclosing && c->root_ast) {
            NameSet assigned = {0};
            NameSet outside  = {0};
            NameSet captured_here = {0};
            NameSet interrogated_here = {0};

            for (int i = 0; i < node->data.block.count; i++)
                collect_module_names_walk(node->data.block.stmts[i], &assigned);
            collect_referenced_names_skip(c->root_ast, node, &outside);
            for (int i = 0; i < node->data.block.count; i++) {
                scan_for_captures(node->data.block.stmts[i], &captured_here);
                scan_for_interrogated(node->data.block.stmts[i], &interrogated_here);
            }

            for (int i = 0; i < assigned.count; i++) {
                const char *nm = assigned.names[i];
                if (name_set_has(&outside, nm)) continue;
                if (name_set_has(&captured_here, nm)) continue;
                if (name_set_has(&interrogated_here, nm)) continue;
                if (name_set_has(&c->module_slot_names, nm)) continue; /* already promoted */
                uint32_t h = env_hash_name(nm);
                if (c->env && env_get_hashed(c->env, nm, h)) continue;
                if (resolve_local(c, nm, h) >= 0) continue;
                int slot = add_local(c, nm, h);
                if (slot >= 0) name_set_add(&c->module_slot_names, nm);
            }

            name_set_free(&assigned);
            name_set_free(&outside);
            name_set_free(&captured_here);
            name_set_free(&interrogated_here);
        }
        emit(c, OP_UNOBSERVED_BEGIN, node->line);
        c->unobs_depth++;                                     /* #871 */
        /* Unobserved block body is stored as block.stmts */
        compile_block(c, node->data.block.stmts, node->data.block.count);
        c->unobs_depth--;
        emit(c, OP_UNOBSERVED_END, node->line);
        break;
    }

    case AST_MATCH: {
        compile_node(c, node->data.match.expr);
        int end_jumps[256];
        int end_count = 0;

        for (int i = 0; i < node->data.match.case_count; i++) {
            ASTNode *pattern = node->data.match.patterns[i];
            if (pattern == NULL) {
                /* Wildcard — always matches */
                emit(c, OP_POP, node->line); /* discard match expr */
                compile_block(c, node->data.match.bodies[i], node->data.match.body_counts[i]);
                if (end_count < 256)
                    end_jumps[end_count++] = emit_jump(c, OP_JUMP, node->line);
                break;
            }
            emit(c, OP_DUP, node->line);
            compile_node(c, pattern);
            emit(c, OP_EQ, node->line);
            int next_case = emit_jump(c, OP_JUMP_IF_FALSE, node->line);
            /* JUMP_IF_FALSE popped the comparison result. Match expr dup is still on stack. */
            emit(c, OP_POP, node->line); /* pop match expr dup */
            compile_block(c, node->data.match.bodies[i], node->data.match.body_counts[i]);
            if (end_count < 256)
                end_jumps[end_count++] = emit_jump(c, OP_JUMP, node->line);
            patch_jump(c, next_case);
            /* JUMP_IF_FALSE already popped comparison result. DUP'd match expr still on stack for next case. */
        }
        /* No match — pop expr, push null */
        emit(c, OP_POP, node->line);
        emit(c, OP_NULL, node->line);

        for (int i = 0; i < end_count; i++)
            patch_jump(c, end_jumps[i]);
        break;
    }

    /* ---- Module system (Stage 8) ---- */

    case AST_IMPORT: {
        int idx = add_string_constant(c, node->data.import.module_name);
        emit_op_u16(c, OP_IMPORT, (uint16_t)idx, node->line);
        /* Bind the result dict to the module name */
        emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)idx, node->line);
        break;
    }

    /* No `default:` on purpose: every ASTType is handled above, so the arm
     * could only ever run for an out-of-range value, while its presence
     * disabled -Wswitch for the main compile dispatch — the one switch where
     * a silently uncompiled new node type is most expensive. */
    }
}

/* #869: a statement whose value is about to be thrown away. For an
 * interrogative that is always a mistake — `what is 42` reads as an
 * assignment, parses as a question about the literal 42, and had NO effect at
 * all: the program ran to completion, rc=0, with no diagnostic on stderr.
 * Only lint caught it. Every neighbouring mistake in the language is loud (an
 * unresolved name is fatal, `break` outside a loop is a compile error), so
 * this was the odd one out.
 *
 * The DISCARD is the signal, which is why the check lives here and not in the
 * parser: the REPL and `eval` compile a unit whose LAST statement is the
 * result, so `what is x` typed at the REPL still answers, and only a value
 * nobody can read is refused. (A discarded interrogative as a unit's final
 * statement is therefore not caught here — lint's W019 still flags it.)
 *
 * Called from both statement loops: AST_PROGRAM (a script's or REPL line's top
 * level) and compile_block (every nested body). */
static void check_discarded_interrogative(ASTNode *stmt) {
    if (!stmt || stmt->type != AST_INTERROGATE) return;
    int k = stmt->data.interrogate.kind;
    if (k < 0 || k > 5) return;          /* `prev of x` — lint W019 covers it */
    char msg[256];
    snprintf(msg, sizeof(msg),
        "'%s is ...' is an interrogative, not an assignment — question words "
        "cannot be assigned with 'is', and this statement's result is discarded",
        eigs_interrogative_word(k));
    fprintf(stderr, "Compile error line %d: %s\n", stmt->line, msg);
    eigs_record_first_error(stmt->line, msg);
    g_parse_errors++;
}

static void compile_block(Compiler *c, ASTNode **stmts, int count) {
    if (count == 0) {
        emit(c, OP_NULL, 0);
        return;
    }
    for (int i = 0; i < count; i++) {
        int depth_before = c->stack_depth;
        compile_node(c, stmts[i]);
        int depth_after = c->stack_depth;
        if (depth_after != depth_before + 1) {
            fprintf(stderr, "[compiler] stmt %d/%d at line %d: expected stack +1, got %+d (depth %d->%d)\n",
                    i + 1, count, stmts[i]->line,
                    depth_after - depth_before, depth_before, depth_after);
        }
        if (i + 1 < count) {
            check_discarded_interrogative(stmts[i]);
            emit(c, OP_POP, stmts[i]->line);
        }
    }
}

/* ---- Public API ---- */

/* ---- #915: eagerly compile the literal `load_file` targets of a unit ------
 *
 * The observer bit is monotonic and set by compile_ast, so a module compiled at
 * RUNTIME flips it only after the parent's assignments have already executed.
 * That ordering hazard is the whole reason `load_file` used to force the gate
 * off, and why EigenMiniSat — four literal loads at the top of the file —
 * gated 0 of 6 units. Compiling the literal targets HERE, with the real
 * compiler, lands their verdict before line 1 of the parent runs.
 *
 * The recursion is the existing one: compile_ast on the module runs this same
 * tail, so a module's own literal loads are resolved transitively with no
 * extra machinery. `depth` bounds it and doubles as the cycle guard — a mutual
 * load (a loads b, b loads a) would otherwise recurse to a C-stack SIGSEGV,
 * the same failure #496 fixed for the runtime path. Hitting the bound is not a
 * silent give-up: it sets the bit, which is the conservative answer.
 *
 * EVERY failure path sets the bit. Unresolvable path, unreadable file, parse
 * error, compile error, depth exceeded — each means "this scan did not get to
 * see what will run", and the only safe answer to that is "observes".
 *
 * This runs in a THROWAWAY env (env_new over the global, the same shape
 * CASE(IMPORT) uses for a real module) and the chunk is freed immediately. The
 * only thing kept is the side effect on g_obs_needed — fd 2 is muted and the
 * trace-arming state is snapshotted/restored, which are the pass's two other
 * output channels. Compiling against the
 * live env instead would let a scan create bindings and perturb the parent's
 * own slot numbering. The throwaway env can change WHICH reader opcode variant
 * is emitted (SLOT vs NAME) but never WHETHER one is — both are readers — so
 * the answer this is asked for is env-independent.
 *
 * AND IT MUST BE SILENT. A pre-pass that speaks is a pre-pass that changes the
 * program's output. Measured, not reasoned: a module containing `break` outside
 * a loop printed "Compile error line 1: 'break' outside a loop" TWICE under the
 * gate — once here and once when load_file compiled it for real. The 417-program
 * corpus differential was byte-identical across both arms and could not see it,
 * because no corpus program load_file's a module that fails to compile. A green
 * differential is evidence about the corpus, not about the change.
 *
 * Suppression is at the FILE DESCRIPTOR, not per-site. The diagnostics reachable
 * from tokenize/parse/compile_ast are 48 raw fprintf(stderr) calls across three
 * files with no helper to hook; gating each is exactly the "touch all N sites"
 * change that silently misses the 49th. Redirecting fd 2 needs no enumeration
 * and cannot drift as sites are added. Its cost is that it is process-global, so
 * it is taken ONLY when this is provably safe:
 *   - hosted profile only (freestanding has no resolver, so no eager compile);
 *   - single-threaded only. Under g_vm_multithreaded another thread could be
 *     writing stderr, so the eager compile is skipped entirely and the bit is
 *     set instead — conservative, and MT+observer is the shape that already
 *     produced #915's worst silent bug.
 * Nesting is fine: each level saves and restores its own dup of fd 2.
 */
enum { OBS_GATE_MAX_LOADS = 64, OBS_GATE_MAX_DEPTH = 8 };
/* Ceiling on a SPECULATIVELY read module. This pass reads on behalf of code that
 * may never run, so an unbounded read is unbounded cost for no benefit. 8 MiB is
 * far above any real .eigs module; over it the pass declines and the gate stays
 * conservatively open. */
#define OBS_GATE_MAX_MODULE_BYTES (8L * 1024 * 1024)
/* CUMULATIVE ceiling on ALL speculative reading by this thread. The per-file
 * ceiling above bounds one read; nothing bounded the TREE, and the pass compiles
 * every literally-loaded module TWICE — once here, once for real (load_file has
 * no module cache by design, #496).
 *
 * Measured by a blind critic: 60 modules loaded from an UNCALLED function took
 * 0.00s -> 14.2s and 2.9 MB -> 61 MB RSS for a program whose only executed
 * statement is `print of "hi"`. The existing limits PERMIT 64 loads x 8 MiB at
 * depth 1 of 8 — roughly nine minutes of startup before the second level. And
 * on this repo's own stdlib, `load_file of "lib/ui.eigs"` (20 units) measured
 * 0.12-0.15s gated against 0.05-0.07s for the identical program written with a
 * computed path, i.e. THE ARM THAT GATES ITSELF CLOSED WAS 2.3x SLOWER. A
 * perf feature that loses to its own fallback on a real module tree has failed
 * on its own terms, whatever its answers are.
 *
 * Once the budget is spent the pass declines and the gate stays conservatively
 * open, so the worst case becomes "no win", never "slower than before". The
 * budget is per-thread and never refills: total speculative work over a
 * program's life is then bounded absolutely.
 *
 * This bounds the damage; it does not recover the win for big trees. That needs
 * the eagerly-compiled chunk to be REUSED by the real load rather than thrown
 * away — filed rather than attempted here, because chunk lifetime and the
 * staleness guard both key off recompiling. */
/* Cumulative per-thread ceiling on bytes this pass may read SPECULATIVELY, on
 * behalf of code the program may never run. Once spent the pass declines and
 * the gate stays conservatively open, so the cost of a hostile or merely huge
 * module tree is bounded (60 modules behind an UNCALLED function: 14.2s/61MB
 * unbounded, 0.13s/35MB with this).
 *
 * PICKED AGAINST A POPULATION, not chosen round. Transitive literal-load
 * closures of all 86 multi-unit trees across the 13 ecosystem repos: the
 * largest is EigenScript/lib/ui.eigs at 287 KiB (19 units), then
 * DeslanStudio/src/client/studio 252, Tidepool 201, EigenMiniSat 179 — a tight
 * band, and NOTHING above 1 MiB. The first value tried here was 256 KiB, which
 * lands INSIDE that band: it bit ui.eigs by 12% (so the repo's own largest tree
 * paid a quarter-megabyte of speculative compiling AND lost the gate) and
 * cleared studio.eigs by under 2%. This clears the whole measured population
 * 3.5x over and still stops the pathological case at ~7% of its work.
 *
 * Cost at the ceiling is ~0.6s of startup (measured: the pass costs ~0.6s per
 * MiB speculatively read, which is issue #1031 — every literally-loaded module
 * is compiled twice, once here and once for real). That is what bounds the
 * choice from above; the population bounds it from below.
 *
 * The floor is asserted, not just documented: suite [99u] requires lib/ui.eigs
 * to still gate CLOSED, so a tree growing past this budget fails a check and
 * forces a deliberate re-pick instead of silently losing the win. That check
 * covers this repo only — the consumer trees above are why the headroom is
 * 3.5x rather than the 1.8x that would suffice for lib/ alone. */
#define OBS_GATE_SPECULATIVE_BUDGET (1024L * 1024)
typedef struct { char **paths; int count; int cap; int overflow; } ObsLoadList;

static void obs_gate_note_load(const char *path, void *ud) {
    /* Collect into a bounded, owned list; resolving here would re-enter the
     * compiler while chunk_scan_static_loads is still walking the chunk. */
    ObsLoadList *L = ud;
    if (L->count >= L->cap) { L->overflow = 1; return; }  /* caller treats as opaque */
    L->paths[L->count++] = xstrdup(path);
}

/* Silence fd 2 for the duration of one eager compile. Returns the saved dup, or
 * -1 if suppression could not be established — in which case the caller does NOT
 * compile, because an eager compile that can speak is worse than no gate.
 *
 * TEST THE VALUE, NOT THE DEFINEDNESS. eigenscript.h does
 * `#ifndef EIGENSCRIPT_FREESTANDING / #define EIGENSCRIPT_FREESTANDING 0`, so the
 * macro is ALWAYS defined and every other site in the tree tests it with `#if`.
 * The first draft here used `#ifdef` / `#ifndef`, which made this function an
 * unconditional `return -1`, made the unmute a no-op, and excluded <unistd.h>
 * and <fcntl.h> entirely — and it still COMPILED, because nothing in the
 * surviving branch referenced dup() or open().
 *
 * The failure that produced was silent and total: every literal load took the
 * `muted < 0` path, set the observer bit, and the whole feature reverted to the
 * conservative pre-#915 behaviour. The 417-program corpus differential passed
 * byte-identical (conservative IS the baseline), and seven of the eight new
 * suite probes passed VACUOUSLY, because they assert the gate stays OPEN and it
 * was always open. Exactly one check caught it: the positive control asserting
 * the gate CLOSES on a literal load of an observer-free module. A control with
 * only the negative half is satisfied by a feature that never runs. */
/* #915: the fd this thread saved while stderr is muted, or -1. A fatal path
 * inside the muted window (x_oom's abort, chunk_verify_self_check's exit) would
 * otherwise die with stderr pointed at /dev/null — executed: a 7 MB module
 * under `ulimit -v` printed "out of memory" when loaded via a COMPUTED path and
 * printed NOTHING via a literal one, same rc 134. The spelling of a load path
 * decided whether a fatal error was reported. */
__thread int g_obs_mute_saved_fd = -1;

void eigs_obs_unmute_for_fatal(void) {
#if !EIGENSCRIPT_FREESTANDING
    if (g_obs_mute_saved_fd < 0) return;
    fflush(stderr);
    dup2(g_obs_mute_saved_fd, STDERR_FILENO);
    close(g_obs_mute_saved_fd);
    g_obs_mute_saved_fd = -1;
#endif
}

static int obs_gate_mute_stderr(void) {
#if EIGENSCRIPT_FREESTANDING
    return -1;
#else
    int saved = dup(STDERR_FILENO);
    if (saved < 0) return -1;
    int devnull = open("/dev/null", O_WRONLY);
    if (devnull < 0) { close(saved); return -1; }
    fflush(stderr);
    if (dup2(devnull, STDERR_FILENO) < 0) { close(devnull); close(saved); return -1; }
    close(devnull);
    /* Only the OUTERMOST mute records here: that is the one holding the real
     * stderr, and it is what a fatal path must restore. Recording every level
     * meant the inner unmute cleared the flag and the OUTER unmute then saw it
     * negative and returned WITHOUT restoring — leaking its fd and leaving
     * stderr pointed at the inner target. Mutual/nested literal loads recurse,
     * so the suite caught it immediately. */
    if (g_obs_mute_saved_fd < 0) g_obs_mute_saved_fd = saved;
    return saved;
#endif
}

static void obs_gate_unmute_stderr(int saved) {
#if !EIGENSCRIPT_FREESTANDING
    if (saved < 0) return;
    fflush(stderr);
    dup2(saved, STDERR_FILENO);
    /* Clear the fatal-path pointer only when THIS level owned it. */
    if (g_obs_mute_saved_fd == saved) g_obs_mute_saved_fd = -1;
    close(saved);
#else
    (void)saved;
#endif
}

/* Memo of resolved paths this top-level compile has already scanned.
 *
 * Without it the eager pass is EXPONENTIAL in a module DAG, not linear: it walks
 * the load graph as a TREE, so a diamond re-compiles the shared leaf once per
 * distinct path to it. Measured by a blind critic on a synthetic 8-file DAG
 * (7 levels, fanout 4, all observer-free): 131,072 re-compiles of one 12-byte
 * leaf, 313,122 file opens, 145,636 fd-2 mute cycles, and 8.5 s wall against
 * 1.2 s for the same program with the gate off — a 7x REGRESSION delivered by a
 * feature whose entire purpose is speed. The runtime path has eigs_loading_enter
 * (#496) as its memo; the eager path had only the depth cap, which bounds depth
 * and not breadth.
 *
 * Thread-local, and it persists for the LIFE OF THE THREAD rather than for one
 * top-level compile. Clearing per-compile still left the pass re-resolving every
 * module on every runtime `load_file` — measured on the DAG above at 38,228 leaf
 * opens against the program's own 16,384, i.e. the pass roughly DOUBLED the file
 * I/O of module-heavy code. `load_file` has no module cache by design (#496: "it
 * re-executes every call"), so without a persistent memo the eager pass inherits
 * that multiplier.
 *
 * Staleness is not a soundness question here: skipping a re-scan can only make
 * the eager pass MISS a module that has since become observing, and that is
 * exactly the condition builtin_load_file raises on (the bit flipping 0 -> 1 at
 * the load). The memo can make the gate conservative-late, never silently wrong.
 * Released by eigs_obs_memo_release() at thread detach. */
static __thread char **g_obs_memo = NULL;
static __thread int g_obs_memo_n = 0, g_obs_memo_cap = 0;
static __thread long g_obs_spec_bytes = 0;   /* see OBS_GATE_SPECULATIVE_BUDGET */

static int obs_memo_seen(const char *path) {
    for (int i = 0; i < g_obs_memo_n; i++)
        if (strcmp(g_obs_memo[i], path) == 0) return 1;
    return 0;
}
static void obs_memo_add(const char *path) {
    if (g_obs_memo_n == g_obs_memo_cap) {
        int nc = g_obs_memo_cap ? g_obs_memo_cap * 2 : 16;
        char **np = realloc(g_obs_memo, (size_t)nc * sizeof(char *));
        if (!np) return;                 /* out of memory: lose the memo, not correctness */
        g_obs_memo = np; g_obs_memo_cap = nc;
    }
    g_obs_memo[g_obs_memo_n++] = xstrdup(path);
}
void eigs_obs_memo_release(void);
static void obs_memo_clear(void) {
    for (int i = 0; i < g_obs_memo_n; i++) free(g_obs_memo[i]);
    free(g_obs_memo);
    g_obs_memo = NULL; g_obs_memo_n = 0; g_obs_memo_cap = 0;
}
void eigs_obs_memo_release(void) { obs_memo_clear(); g_obs_spec_bytes = 0; }

static void obs_gate_resolve_static_loads(EigsChunk *chunk) {
    ObsLoadList L;
    char *slots[OBS_GATE_MAX_LOADS];
    char *resolved = NULL;
    L.paths = slots; L.count = 0; L.cap = OBS_GATE_MAX_LOADS; L.overflow = 0;

    /* The eager pass informs a RUNTIME decision. Entry points that compile
     * without ever executing — `--lint` and the LSP, which recompiles on every
     * didChange — must not reach out to the filesystem on its behalf.
     * src/lint_host.c documents "import and load_file are executed by the VM,
     * not resolved here, so lint still touches nothing but the file in front of
     * it"; a blind critic caught this pass making that false, and an editor
     * stat/read/compiling a file's load targets on every keystroke with it. */
    if (!g_obs_gate_scan_enabled) return;

    if (g_obs_gate_depth >= OBS_GATE_MAX_DEPTH) { eigs_obs_enable(); return; }

    if (chunk_scan_static_loads(chunk, obs_gate_note_load, &L)) { eigs_obs_enable(); goto done; }
    if (L.overflow) { eigs_obs_enable(); goto done; }   /* more loads than slots — see above */

    /* See the comment above: fd-level suppression is process-global, so the
     * eager compile is not taken at all while another thread could be writing
     * stderr. Placed AFTER the scan deliberately — a unit with no loads has
     * nothing to compile eagerly and must not lose its gate just for running
     * in a process that happens to have spawned a worker. */
    /* PROCESS-wide, not per-state. `g_vm_multithreaded` is
     * eigs_current->state->multithreaded and cannot see a sibling state;
     * ext_http runs a fresh EigsState per connection on its own OS thread, so
     * that flag was 0 on every worker while this pass mutated process-global
     * memory (trace.c's arming sets) and process-global fd 2. A blind critic
     * captured a heap-use-after-free on g_arm_names between two connection
     * threads, and showed the fd-2 mute swallowing other requests' stderr and
     * then destroying the server's real stderr permanently. See
     * eigs_process_thread_count. */
    if (L.count > 0 && (g_vm_multithreaded || eigs_process_thread_count() > 1)) {
        eigs_obs_enable(); goto done;
    }

    /* HEAP, not stack. As `char resolved[8192]` inside the loop this frame
     * measured 8,864 bytes (gcc -fstack-usage) on EVERY compile_ast, and this
     * function recurses to OBS_GATE_MAX_DEPTH — 8 x 8,864 = 70,912 bytes of
     * `resolved` alone, more than the whole 64 KiB budget that
     * tools/embed_stack_soak.sh enforces, before tokenize/parse/compile_node
     * frames are counted. .claude/rules/c-runtime-memory.md calls >= ~2 KiB in a
     * recursive path suspect; that rule was bought on exactly this shape. */
    if (L.count > 0) {
        resolved = malloc(8192);
        if (!resolved) { eigs_obs_enable(); goto done; }
    }

    for (int i = 0; i < L.count && !g_obs_needed; i++) {
        long size = 0;
        char *source = NULL;
#if !EIGENSCRIPT_FREESTANDING
        /* Guarded on the VALUE, and the guard must cover the CALLEES, not only
         * the helpers. builtins_host.c is a whole-TU carve-out in this profile,
         * so read_file_util does not exist to link against; leaving these two
         * calls outside the guard broke `make freestanding-check` and
         * tools/embed_stack_soak.sh at the LINK step. Both are CI-only, which is
         * why a green release suite and a green ASan suite could not see it —
         * and it is the same defect class as the #ifdef-vs-#if mistake this file
         * already records, made a second time while fixing the first. */
        int resolved_ok = resolve_eigenscript_file(L.paths[i], resolved, 8192);
#else
        int resolved_ok = 0;
#endif
        if (!resolved_ok) { eigs_obs_enable(); break; }

        /* Memo BEFORE the read. Resolving is an access(2) probe; reading pulls
         * the whole file and then throws it away. Checking after the read left
         * 32,772 opens of one leaf on the DAG above against the program's own
         * 16,384 — the pass still doubled the file I/O even though it compiled
         * each module exactly once. */
        if (obs_memo_seen(resolved)) continue;

#if !EIGENSCRIPT_FREESTANDING
        /* STAT BEFORE OPEN. This pass reads files on behalf of code the program
         * may never run — a literal load inside an uncalled function or a dead
         * branch is still scanned, because chunk_scan_static_loads recurses into
         * chunk->functions. try_resolve_path admits anything access(F_OK)
         * accepts, including a FIFO, and read_file_util's S_ISREG rejection
         * happens AFTER fopen, so it cannot prevent the block.
         *
         * Executed: `define maybe() as: return load_file of "fifo.eigs"` with
         * maybe() NEVER CALLED hung the compiler indefinitely (rc 124 under
         * timeout, nothing printed, dead before vm_execute); the same program
         * with a computed path ran fine. A 120 MB target referenced only from an
         * uncalled function took peak RSS from 2.8 MB to 248 MB.
         *
         * A real load_file that executes is unaffected — this bounds only the
         * SPECULATIVE read. Anything rejected here is simply unresolvable to the
         * pass, which is already its conservative answer.
         *
         * AFTER the memo check, not before. Charging on the way past a memo HIT
         * bills a shared module once per reference while reading it once, so a
         * DAG exhausts the budget on bytes it never reads — the same defect the
         * memo above was added to fix, re-committed in the accounting instead
         * of the I/O. Executed: six thin parents sharing ONE 59 KiB leaf (59 KiB
         * unique, under a quarter of the budget) opened the gate, while that
         * leaf loaded once closed it. The budget must count bytes READ. */
        {
            struct stat st;
            if (stat(resolved, &st) != 0 || !S_ISREG(st.st_mode) ||
                st.st_size > OBS_GATE_MAX_MODULE_BYTES ||
                g_obs_spec_bytes + st.st_size > OBS_GATE_SPECULATIVE_BUDGET) {
                eigs_obs_enable(); break;
            }
            g_obs_spec_bytes += st.st_size;
        }
        source = read_file_util(resolved, &size);
#endif
        if (!source) { eigs_obs_enable(); break; }
        obs_memo_add(resolved);

        int muted = obs_gate_mute_stderr();
        if (muted < 0) { free(source); eigs_obs_enable(); break; }

        /* BEFORE tokenize, not after. lexer.c zeroes all five first_error
         * fields unconditionally at tokenize depth 0, so a snapshot taken after
         * it saved the ZEROES and the "restore" then wiped the parent's recorded
         * error — and the parse-error path below exited without restoring at
         * all, leaving the MODULE's error installed in the parent. The previous
         * placement was a fix that did not work; found by enumerating the
         * compile path, not by a test, because the only readers (lint, LSP)
         * disable this pass. */
        int saved_fe_line = g_first_error_line, saved_fe_col = g_first_error_col;
        int saved_fe_len = g_first_error_len, saved_fe_known = g_first_error_col_known;
        char saved_fe_msg[256];
        snprintf(saved_fe_msg, sizeof saved_fe_msg, "%s", g_first_error_msg);
        int saved_errors = g_parse_errors;
        g_parse_errors = 0;
        TokenList tl = tokenize(source);
        ASTNode *mast = parse(&tl);
        if (g_parse_errors > 0 || !mast) {
            g_parse_errors = saved_errors;
            free_ast(mast); free_tokenlist(&tl); free(source);
            g_first_error_line = saved_fe_line; g_first_error_col = saved_fe_col;
            g_first_error_len = saved_fe_len;   g_first_error_col_known = saved_fe_known;
            snprintf(g_first_error_msg, sizeof(((EigsThread *)0)->first_error_msg),
                     "%s", saved_fe_msg);
            obs_gate_unmute_stderr(muted);   /* every exit from here unmutes */
            eigs_obs_enable(); break;
        }

        Env *scan_env = env_new(g_global_env);
        int saved_boundary = g_compile_module_boundary;
        g_compile_module_boundary = 1;                    /* #373, as load_file does */
        /* The pass has TWO output channels, not one. fd 2 is muted above; this
         * is the other. compile_node arms the trace-history channel as a side
         * effect, so scanning a module used to switch per-assignment recording
         * on in the PARENT and change its temporal answers — making the
         * SPELLING of a load path semantically load-bearing (a literal armed
         * `prev of x`, a computed one did not) and the behaviour non-monotone
         * (adding an observer read opened the gate, skipped the pass, and
         * un-armed the name). See trace_arm_snapshot. */
        TraceArmState saved_arm;
        trace_arm_snapshot(&saved_arm);
        g_obs_gate_depth++;
        EigsChunk *mchunk = compile_ast(mast, scan_env, source);   /* ORs its own verdict */
        g_obs_gate_depth--;
        trace_arm_restore(&saved_arm);
        g_first_error_line = saved_fe_line; g_first_error_col = saved_fe_col;
        g_first_error_len = saved_fe_len;   g_first_error_col_known = saved_fe_known;
        snprintf(g_first_error_msg, sizeof(((EigsThread *)0)->first_error_msg),
                 "%s", saved_fe_msg);
        g_compile_module_boundary = saved_boundary;
        if (g_parse_errors > 0) eigs_obs_enable();
        g_parse_errors = saved_errors;

        if (mchunk) chunk_free(mchunk);
        env_decref(scan_env);
        free_ast(mast); free_tokenlist(&tl); free(source);
        obs_gate_unmute_stderr(muted);
    }

done:
    free(resolved);
    for (int i = 0; i < L.count; i++) free(L.paths[i]);
}

EigsChunk *compile_ast(ASTNode *ast, Env *env, const char *src) {
    EigsChunk *chunk = chunk_new("<module>");
    /* #830: the arming below is compile-time evidence about THIS chunk, so
     * only this chunk (and the fn chunks compiled under it) may use the
     * armed-name filter. See EigsChunk.compiler_scanned in vm.h. */
    chunk->compiler_scanned = 1;
    /* #407: retain the unit's source for runtime-error caret excerpts.
     * Owned copy — callers free their buffers while closures can keep
     * chunks alive indefinitely. Nested fn chunks share the blob. */
    chunk->src = srcbuf_new(src);

    Compiler compiler;
    memset(&compiler, 0, sizeof(compiler));
    compiler.locals = xcalloc_array(MAX_LOCALS, sizeof(Local));
    compiler.chunk = chunk;
    compiler.env = env;
    compiler.last_line = -1;  /* #174: force first OP_LINE at module entry */
    compiler.root_ast = ast;

    /* Pre-pass: collect names defined at module scope so function bodies can
     * distinguish "update a global" (slow name path) from "fresh local" (fast slot). */
    NameSet module_names = {0};
    if (ast) collect_module_names_walk(ast, &module_names);
    compiler.module_names = &module_names;

    /* #459: OP_DISPATCH must not hijack a user-rebound `dispatch`. Static
     * half: the unit binds the name somewhere or references eval. Dynamic
     * half: a PRIOR unit in this env (REPL line, embed eval) already rebound
     * it — visible at compile time as a non-builtin_dispatch binding. */
    compiler.dispatch_rebound = ast ? scan_dispatch_rebind(ast) : 0;
    if (!compiler.dispatch_rebound && env) {
        Value *dv = env_get(env, "dispatch");
        if (dv && !(dv->type == VAL_BUILTIN && dv->data.builtin == builtin_dispatch))
            compiler.dispatch_rebound = 1;
    }

    g_parse_depth = 0;  /* reuse the parse-depth counter as the compile-depth guard */
    g_compile_depth_reported = 0;   /* #912: one report per compile */

    /* For module-level slot promotion: seed local_count past existing env entries
     * so SET_LOCAL slot indices don't collide with builtins/globals already there. */
    int slot_base = 0;
    if (g_compile_module_slots && env) {
        slot_base = env->count;
        compiler.local_count = slot_base;
    }

    compile_node(&compiler, ast);
    emit(&compiler, OP_RETURN, ast ? ast->line : 0);

    /* If any module slots were promoted, write back the total local_count so the
     * VM knows to reserve env slots at module run-time. */
    if (g_compile_module_slots && compiler.local_count > slot_base) {
        chunk->local_count = compiler.local_count;
    }

    name_set_free(&module_names);
    name_set_free(&compiler.module_slot_names);
    free(compiler.locals);

    /* Opt-in self-check: every chunk this compiler emits must satisfy the
     * verifier that gates untrusted chunks. Off unless EIGS_VERIFY_SELF=1 (the
     * suite sets it for one full pass), so the normal compile path is untouched
     * bar one cached getenv. */
    static int verify_self = -1;
    if (verify_self < 0) {
        const char *e = getenv("EIGS_VERIFY_SELF");
        verify_self = (e && *e && strcmp(e, "0") != 0) ? 1 : 0;
    }
    /* Only assert on a CLEAN compile: a unit that already failed to parse or
     * compile can carry a patched-to-0 jump or a truncated tail by design, and
     * the entry paths abort before running it. Verifying that is checking the
     * error path, not the table. */
    if (verify_self && g_parse_errors == 0)
        chunk_verify_self_check(chunk, chunk->name ? chunk->name : "?");

    /* #915 observer gate. compile_ast is the ONE choke point every compilation
     * path funnels through — the main script (main.c), eval (builtins.c),
     * load_file (builtins_host.c), import (vm.c), the REPL (repl.c), the embed
     * API (eigs_embed.c) and ext_http's dynamic handlers — so OR-ing here needs
     * no hand-maintained caller list, which is the drift failure #921/#925 are
     * open on. Monotonic: a later unit that reads the observer turns it on for
     * good; nothing turns it back off.
     *
     * Residual, deliberately accepted: a unit compiled AFTER assignments have
     * already run (a load_file partway through a program, a REPL line) flips
     * the bit late, so bindings assigned before the flip have no history and
     * read as unobserved. The full-corpus differential (tools/observer_gate_diff.sh)
     * is what polices this — if any tracked program exhibits it, the diff goes
     * red. Force-on sites cover the cases where it is not merely possible but
     * expected (REPL, embed). */
    /* #915 escape hatch. Any non-empty, non-"0" value arms it — the same rule
     * as EIGS_STRICT (state.c) and EIGS_VERIFY_SELF above, and NOT a bare
     * getenv. A bare getenv made `EIGS_OBS_FORCE=0` and `EIGS_OBS_FORCE=` force
     * the gate OPEN, i.e. do exactly what `=1` does, inverting a documented
     * control for anyone who spells "off" the obvious way.
     *
     * It also silently laundered the corpus oracle. tools/observer_gate_diff.sh
     * records `force=${EIGS_OBS_FORCE:-0}` in each capture's manifest, which
     * collapses "unset" and "=0" — two settings that behaved OPPOSITELY — so a
     * "gated" arm captured with EIGS_OBS_FORCE=0 actually ran the BASELINE while
     * the manifest recorded force=0, and compare printed a provenance line
     * byte-identical to an honest run. Executed on a build with
     * `case OP_REPORT_NAME:` deleted from opcode_is_observer_reader(): the
     * honest three-capture run reports 3 mismatches and rc=1; the laundered one
     * reports `415 programs byte-identical` and rc=0. */
    {
        const char *ef = getenv("EIGS_OBS_FORCE");
        if (!g_obs_needed && ef && ef[0] && ef[0] != '0') eigs_obs_enable();
    }
    if (!g_obs_needed && chunk_reads_observer(chunk)) eigs_obs_enable();
    if (!g_obs_needed) obs_gate_resolve_static_loads(chunk);
    /* Same convention as EIGS_OBS_FORCE above — these two are documented as
     * adjacent rows of one table in docs/OBSERVER.md, and read with a bare
     * getenv this one printed its stats for EIGS_OBS_GATE_STATS=0. Found by
     * sweeping every getenv site after fixing the FORCE flag, rather than
     * assuming that defect was isolated. */
    {
        const char *gs = getenv("EIGS_OBS_GATE_STATS");
        if (gs && gs[0] && gs[0] != '0')
            fprintf(stderr, "obs-gate: %s %s\n",
                    g_obs_needed ? "observed" : "unobserved", chunk->name);
    }

    return chunk;
}
