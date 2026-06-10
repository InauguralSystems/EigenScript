/* ================================================================
 * EigenScript Bytecode Compiler — AST to bytecode
 * ================================================================ */

#include "eigenscript.h"
#include "vm.h"
#include "trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Compiler state ---- */

#define MAX_LOCALS 512
#define MAX_LOOP_DEPTH 32
#define MAX_BREAK_JUMPS 64

typedef struct {
    char    *name;
    uint32_t hash;
    int      depth;     /* scope depth (0 = function-level) */
    int      slot;
    int      captured;
} Local;

typedef struct {
    int break_jumps[MAX_BREAK_JUMPS];
    int break_count;
    int continue_target;
    int scope_depth;
    int has_fresh_env;  /* 1 if loop emits OP_LOOP_ENV_FRESH per iteration (for-loops) */
} LoopCtx;

/* Dynamic set of name pointers used for escape analysis & module-name tracking.
 * Strings are NOT owned (point into AST nodes); only the array is malloc'd. */
typedef struct {
    const char **names;
    int          count;
    int          cap;
} NameSet;

typedef struct Compiler {
    EigsChunk        *chunk;
    struct Compiler  *enclosing;
    Local             locals[MAX_LOCALS];
    int               local_count;
    int               scope_depth;
    LoopCtx           loops[MAX_LOOP_DEPTH];
    int               loop_depth;
    Env              *env;          /* for resolving globals at compile time */
    int               stack_depth;  /* tracked stack depth for validation */
    int               max_stack;    /* high-water mark */
    int               param_count;  /* number of function params (for local opt) */
    NameSet           captured;     /* names captured by nested closures (slow path) */
    NameSet           interrogated; /* names used in `who/when is x` (slow path for assign_counts) */
    NameSet          *module_names; /* root-compiler-owned: names defined at module scope */
    NameSet           module_slot_names; /* root-compiler-owned: names promoted to module slots */
    ASTNode          *root_ast;     /* root-compiler-owned: full AST for escape analysis */
} Compiler;

int g_compile_module_slots = 0;

/* ---- NameSet helpers ---- */

static int name_set_has(const NameSet *s, const char *name) {
    if (!s) return 0;
    for (int i = 0; i < s->count; i++)
        if (s->names[i] == name || strcmp(s->names[i], name) == 0) return 1;
    return 0;
}

static void name_set_add(NameSet *s, const char *name) {
    if (!name || name_set_has(s, name)) return;
    if (s->count >= s->cap) {
        s->cap = s->cap ? s->cap * 2 : 8;
        s->names = realloc(s->names, s->cap * sizeof(const char *));
    }
    s->names[s->count++] = name;
}

static void name_set_free(NameSet *s) {
    free(s->names);
    s->names = NULL;
    s->count = s->cap = 0;
}

/* ---- Forward declarations ---- */
static void compile_node(Compiler *c, ASTNode *node);
static void compile_block(Compiler *c, ASTNode **stmts, int count);

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

/* Stack effect of each opcode */
static int op_stack_effect(uint8_t op) {
    switch (op) {
    /* Push 1 */
    case OP_CONST: case OP_NULL: case OP_NUM_ZERO: case OP_NUM_ONE:
    case OP_GET_LOCAL: case OP_GET_NAME: case OP_DUP:
    case OP_PREDICATE: case OP_LISTCOMP_BEGIN:
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
    case OP_INTERROGATE_NAMED_AT:  /* pop line, push result = 0 */
        return 0;
    /* Index set: pop value, pop index, pop target, push value = -2 */
    case OP_INDEX_SET:
        return -2;
    /* Return: special */
    case OP_RETURN: case OP_RETURN_NULL:
        return 0;
    /* Loop env: no stack change */
    case OP_LOOP_ENV_FRESH: case OP_LOOP_ENV_END:
        return 0;
    /* Iterator: SETUP pops iterable pushes state = 0; NEXT pushes elem = +1 */
    case OP_ITER_SETUP:
        return 0;
    case OP_ITER_NEXT:
        return 1; /* on non-exit path */
    /* Try: no stack change */
    case OP_TRY_BEGIN: case OP_TRY_END:
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
    /* CALL, LIST, DICT: dynamic — handled separately */
    default:
        return 0;
    }
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
}

static void emit_loop(Compiler *c, int loop_start, int line) {
    chunk_emit(c->chunk, OP_JUMP_BACK, line);
    int offset = c->chunk->code_len - loop_start + 2;
    chunk_emit_u16(c->chunk, (uint16_t)offset, line);
}

/* ---- Constant helpers ---- */

static int add_string_constant(Compiler *c, const char *str) {
    Value *v = make_str(str);
    int idx = chunk_add_constant(c->chunk, v);
    val_decref(v);
    return idx;
}

static int add_num_constant(Compiler *c, double num) {
    Value *v = make_num(num);
    int idx = chunk_add_constant(c->chunk, v);
    val_decref(v);
    return idx;
}

/* ---- Local variable tracking ---- */

static int resolve_local(Compiler *c, const char *name, uint32_t hash) {
    for (int i = c->local_count - 1; i >= 0; i--) {
        if (c->locals[i].hash == hash && strcmp(c->locals[i].name, name) == 0)
            return c->locals[i].slot;
    }
    return -1;
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
    case AST_PROGRAM:
        for (int i = 0; i < node->data.program.count; i++)
            collect_referenced_names_skip(node->data.program.stmts[i], skip, out);
        break;
    default:
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
    case AST_PROGRAM:
        for (int i = 0; i < node->data.program.count; i++)
            collect_referenced_names(node->data.program.stmts[i], out);
        break;
    default:
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
    default:
        break;
    }
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
    default:
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
    case AST_PROGRAM:
        collect_module_names_block(node->data.program.stmts, node->data.program.count, out);
        break;
    default:
        break;
    }
}
static void collect_module_names_block(ASTNode **stmts, int count, NameSet *out) {
    for (int i = 0; i < count; i++) collect_module_names_walk(stmts[i], out);
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

/* ---- AST compilation ---- */

static void compile_node(Compiler *c, ASTNode *node) {
    if (!node) { emit(c, OP_NULL, 0); return; }

    emit_op_u16(c, OP_LINE, (uint16_t)node->line, node->line);

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
            g_trace_hist = 1;
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
        const char *name = node->data.assign.name;
        uint32_t h = node->name_hash;
        if (h == 0) h = env_hash_name(name);

        /* Decide the SET path first, then emit the matching OBSERVE op so it
         * knows where the prior binding lives. OBSERVE_ASSIGN walks the env
         * by name (works for SET_NAME/SET_NAME_LOCAL); OBSERVE_ASSIGN_LOCAL
         * reads from a function-env slot (works for SET_LOCAL). Picking the
         * wrong variant lets observer history reset on every write — see #129. */
        uint8_t  set_op   = 0;
        uint16_t set_arg  = 0;
        uint8_t  obs_op   = 0;
        uint16_t obs_arg  = 0;

        if (c->enclosing) {
            int slot = resolve_local(c, name, h);
            if (slot >= 0) {
                set_op  = OP_SET_LOCAL;  set_arg = (uint16_t)slot;
                obs_op  = OP_OBSERVE_ASSIGN_LOCAL; obs_arg = (uint16_t)slot;
            } else {
                int captured     = name_set_has(&c->captured, name);
                int interrogated = name_set_has(&c->interrogated, name);
                int in_outer     = name_in_enclosing(c, name);
                int in_module    = c->module_names && name_set_has(c->module_names, name);
                int in_globals   = c->env && env_get_hashed(c->env, name, h) != NULL;
                int local_eligible = !captured && !interrogated && !in_outer && !in_module && !in_globals;

                if (local_eligible) {
                    int new_slot = add_local(c, name, h);
                    if (new_slot >= 0) {
                        set_op  = OP_SET_LOCAL;  set_arg = (uint16_t)new_slot;
                        obs_op  = OP_OBSERVE_ASSIGN_LOCAL; obs_arg = (uint16_t)new_slot;
                    } else {
                        /* Slot table full — fall back to the function-env path
                         * (not loop-local), so nested writes still find the
                         * binding. */
                        int idx = add_string_constant(c, name);
                        set_op  = OP_SET_FN_NAME_LOCAL; set_arg = (uint16_t)idx;
                        obs_op  = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
                    }
                } else if (node->data.assign.local_only || captured || interrogated) {
                    /* Anchored in this function's env: SET_FN_NAME_LOCAL pins
                     * the write to frame->fn_env even when frame->env is a
                     * nested loop/try scope. SET_NAME_LOCAL targets frame->env
                     * and would silently shadow the function binding for the
                     * remainder of the iteration (see #129b: unobserved+for+
                     * interrogated accumulator never updates). */
                    int idx = add_string_constant(c, name);
                    set_op  = OP_SET_FN_NAME_LOCAL; set_arg = (uint16_t)idx;
                    obs_op  = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
                } else {
                    int idx = add_string_constant(c, name);
                    set_op  = OP_SET_NAME; set_arg = (uint16_t)idx;
                    obs_op  = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
                }
            }
        } else {
            /* Module level — slot promotion if eligible (Part B), else name-based */
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
                if (node->data.assign.local_only) {
                    set_op = OP_SET_NAME_LOCAL; set_arg = (uint16_t)idx;
                } else {
                    set_op = OP_SET_NAME; set_arg = (uint16_t)idx;
                }
                obs_op = OP_OBSERVE_ASSIGN; obs_arg = (uint16_t)idx;
            }
        }

        emit_op_u16(c, obs_op, obs_arg, node->line);
        emit_op_u16(c, set_op, set_arg, node->line);
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
            if (i + 1 < node->data.program.count)
                emit(c, OP_POP, node->line);
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
        LoopCtx *lp = NULL;
        if (c->loop_depth < MAX_LOOP_DEPTH) {
            lp = &c->loops[c->loop_depth++];
            lp->break_count = 0;
            lp->scope_depth = c->scope_depth;
            lp->has_fresh_env = 0; /* while-loops don't allocate per-iter envs */
        }

        int loop_start = c->chunk->code_len;
        if (lp) lp->continue_target = loop_start;

        int depth_at_loop = c->stack_depth;
        compile_node(c, node->data.loop.cond);
        int exit_jump = emit_jump(c, OP_JUMP_IF_FALSE, node->line);
        /* condition popped by JUMP_IF_FALSE */

        compile_block(c, node->data.loop.body, node->data.loop.body_count);
        emit(c, OP_POP, node->line); /* discard body result before next iteration */

        /* Observer stall check — jump to exit if stalled */
        int stall_jump = emit_jump(c, OP_LOOP_STALL_CHECK, node->line);

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
        if (lp) {
            for (int i = 0; i < lp->break_count; i++)
                patch_jump(c, lp->break_jumps[i]);
            c->loop_depth--;
        }

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

        LoopCtx *lp = NULL;
        if (c->loop_depth < MAX_LOOP_DEPTH) {
            lp = &c->loops[c->loop_depth++];
            lp->break_count = 0;
            lp->scope_depth = c->scope_depth;
            lp->has_fresh_env = can_skip_env ? 0 : 1;
        }

        int depth_before_loop = c->stack_depth;
        int loop_start = c->chunk->code_len;
        if (lp) lp->continue_target = loop_start;

        int exit_jump = emit_jump(c, OP_ITER_NEXT, node->line);
        /* ITER_NEXT pushes element on non-exit (+1) */

        if (can_skip_env) {
            /* Bind loop var to a function-env slot. SET_LOCAL leaves the
             * value on the stack (matching SET_NAME_LOCAL's convention),
             * so the POP below still applies. */
            emit_op_u16(c, OP_SET_LOCAL, (uint16_t)loop_var_slot, node->line);
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

        if (!can_skip_env)
            emit(c, OP_LOOP_ENV_END, node->line);

        /* Reset depth for back-edge (same as loop start) */
        c->stack_depth = depth_before_loop;
        emit_loop(c, loop_start, node->line);

        /* Break lands here — env already cleaned by break's LOOP_ENV_END
         * when has_fresh_env=1; in the env-skip path AST_BREAK saw
         * has_fresh_env=0 and skipped the cleanup. */
        if (lp) {
            for (int i = 0; i < lp->break_count; i++)
                patch_jump(c, lp->break_jumps[i]);
        }

        /* Exit path: ITER_NEXT jumped here (no element pushed), or break jumped here */
        patch_jump(c, exit_jump);
        c->stack_depth = depth_before_loop; /* iterator state still on stack */
        emit(c, OP_POP, node->line); /* pop iterator state */
        emit(c, OP_NULL, node->line); /* for-loop result */

        if (lp) c->loop_depth--;
        break;
    }

    case AST_BREAK: {
        if (c->loop_depth > 0) {
            LoopCtx *lp = &c->loops[c->loop_depth - 1];
            /* Clean up loop env before jumping out, but ONLY if the loop allocated
             * a per-iteration env. While-loops don't — emitting OP_LOOP_ENV_END
             * there would free the surrounding env (often the global one). */
            if (lp->has_fresh_env)
                emit(c, OP_LOOP_ENV_END, node->line);
            if (lp->break_count < MAX_BREAK_JUMPS) {
                lp->break_jumps[lp->break_count++] = emit_jump(c, OP_JUMP, node->line);
            }
            /* Phantom +1 for stack accounting (dead code follows jump) */
            adjust_stack(c, 1);
        } else {
            /* Break outside loop: emit null (no-op, maintains stack balance) */
            emit(c, OP_NULL, node->line);
        }
        break;
    }

    case AST_CONTINUE: {
        if (c->loop_depth > 0) {
            LoopCtx *lp = &c->loops[c->loop_depth - 1];
            emit_loop(c, lp->continue_target, node->line);
            /* Phantom +1 for stack accounting (dead code follows jump) */
            adjust_stack(c, 1);
        } else {
            /* Continue outside loop: emit null */
            emit(c, OP_NULL, node->line);
        }
        break;
    }

    /* ---- Functions (Stage 5) ---- */

    case AST_FUNC: {
        /* Compile function body into nested chunk */
        EigsChunk *fn_chunk = chunk_new(node->data.func.name);
        fn_chunk->param_count = node->data.func.param_count;

        Compiler fn_compiler;
        memset(&fn_compiler, 0, sizeof(fn_compiler));
        fn_compiler.chunk = fn_chunk;
        fn_compiler.enclosing = c;
        fn_compiler.env = c->env;
        fn_compiler.param_count = node->data.func.param_count;
        fn_compiler.module_names = c->module_names;

        /* Escape analysis: find names captured by nested closures + names that
         * are interrogated (who/when is x). These stay on the slow name path. */
        for (int i = 0; i < node->data.func.body_count; i++) {
            scan_for_captures(node->data.func.body[i], &fn_compiler.captured);
            scan_for_interrogated(node->data.func.body[i], &fn_compiler.interrogated);
        }
        /* Function's own params are never "captured by themselves" */
        for (int i = 0; i < node->data.func.param_count; i++) {
            for (int j = 0; j < fn_compiler.captured.count; j++) {
                if (strcmp(fn_compiler.captured.names[j], node->data.func.params[i]) == 0) {
                    fn_compiler.captured.names[j] = fn_compiler.captured.names[--fn_compiler.captured.count];
                    break;
                }
            }
        }

        /* Store param names in chunk AND add as compiler locals.
         * Params are at env slots 0..param_count-1, bound by OP_CALL. */
        fn_chunk->local_names = xcalloc(node->data.func.param_count, sizeof(char *));
        fn_chunk->local_count = node->data.func.param_count;
        for (int i = 0; i < node->data.func.param_count; i++) {
            fn_chunk->local_names[i] = strdup(node->data.func.params[i]);
            uint32_t h = env_hash_name(node->data.func.params[i]);
            add_local(&fn_compiler, node->data.func.params[i], h);
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

        int fn_idx = chunk_add_function(c->chunk, fn_chunk);
        emit_op_u16(c, OP_CLOSURE, (uint16_t)fn_idx, node->line);

        /* Bind function name in current scope */
        int name_idx = add_string_constant(c, node->data.func.name);
        emit_op_u16(c, OP_SET_NAME_LOCAL, (uint16_t)name_idx, node->line);
        break;
    }

    case AST_LAMBDA: {
        EigsChunk *fn_chunk = chunk_new("<lambda>");
        fn_chunk->param_count = node->data.lambda.param_count;

        Compiler fn_compiler;
        memset(&fn_compiler, 0, sizeof(fn_compiler));
        fn_compiler.chunk = fn_chunk;
        fn_compiler.enclosing = c;
        fn_compiler.env = c->env;
        fn_compiler.param_count = node->data.lambda.param_count;
        fn_compiler.module_names = c->module_names;

        scan_for_captures(node->data.lambda.body, &fn_compiler.captured);
        scan_for_interrogated(node->data.lambda.body, &fn_compiler.interrogated);
        for (int i = 0; i < node->data.lambda.param_count; i++) {
            for (int j = 0; j < fn_compiler.captured.count; j++) {
                if (strcmp(fn_compiler.captured.names[j], node->data.lambda.params[i]) == 0) {
                    fn_compiler.captured.names[j] = fn_compiler.captured.names[--fn_compiler.captured.count];
                    break;
                }
            }
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

        int fn_idx = chunk_add_function(c->chunk, fn_chunk);
        emit_op_u16(c, OP_CLOSURE, (uint16_t)fn_idx, node->line);
        break;
    }

    case AST_RETURN: {
        if (node->data.ret.expr) {
            compile_node(c, node->data.ret.expr);
            emit(c, OP_RETURN, node->line);
        } else {
            emit(c, OP_RETURN_NULL, node->line);
        }
        break;
    }

    case AST_RELATION: {
        /* Function call: f of [a, b] or f of arg */
        ASTNode *fn_node = node->data.relation.left;
        ASTNode *arg_node = node->data.relation.right;

        /* Optimize: dispatch of [table, key, arg] → OP_DISPATCH */
        if (fn_node && fn_node->type == AST_IDENT &&
            strcmp(fn_node->data.ident.name, "dispatch") == 0 &&
            arg_node && arg_node->type == AST_LIST &&
            arg_node->data.list.count == 3) {
            compile_node(c, arg_node->data.list.elems[0]); /* table */
            compile_node(c, arg_node->data.list.elems[1]); /* key */
            compile_node(c, arg_node->data.list.elems[2]); /* arg */
            emit(c, OP_DISPATCH, node->line);
            break;
        }

        compile_node(c, fn_node);

        if (arg_node && arg_node->type == AST_LIST && arg_node->data.list.count > 1) {
            /* Multi-arg: compile each element as separate stack value */
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

        int loop_start = c->chunk->code_len;
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
        int catch_jump = emit_jump(c, OP_TRY_BEGIN, node->line);
        compile_block(c, node->data.trycatch.try_body, node->data.trycatch.try_count);
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
         * per-assign history — enable recording. */
        if (kind == 6 || at_expr)
            g_trace_hist = 1;

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
        if ((kind == 1 || kind == 2 || kind == 6) && expr->type == AST_IDENT) {
            /* who/when/prev with known binding name: emit name index */
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
        /* Unobserved block body is stored as block.stmts */
        compile_block(c, node->data.block.stmts, node->data.block.count);
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

    default:
        fprintf(stderr, "compiler: unhandled AST type %d at line %d\n", node->type, node->line);
        emit(c, OP_NULL, node->line);
        break;
    }
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
        if (i + 1 < count)
            emit(c, OP_POP, stmts[i]->line);
    }
}

/* ---- Public API ---- */

EigsChunk *compile_ast(ASTNode *ast, Env *env) {
    EigsChunk *chunk = chunk_new("<module>");

    Compiler compiler;
    memset(&compiler, 0, sizeof(compiler));
    compiler.chunk = chunk;
    compiler.env = env;
    compiler.root_ast = ast;

    /* Pre-pass: collect names defined at module scope so function bodies can
     * distinguish "update a global" (slow name path) from "fresh local" (fast slot). */
    NameSet module_names = {0};
    if (ast) collect_module_names_walk(ast, &module_names);
    compiler.module_names = &module_names;

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
    return chunk;
}
