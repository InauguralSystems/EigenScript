/* ================================================================
 * EigenScript Bytecode Chunk — allocation, emit, disassemble
 * ================================================================ */

#include "eigenscript.h"
#include "vm.h"
#include "jit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Chunk lifecycle ---- */

EigsChunk *chunk_new(const char *name) {
    EigsChunk *c = xcalloc(1, sizeof(EigsChunk));
    c->code_cap = 256;
    c->code = xcalloc(c->code_cap, 1);
    c->const_cap = 32;
    c->constants = xcalloc(c->const_cap, sizeof(Value *));
    c->const_hashes = xcalloc(c->const_cap, sizeof(uint32_t));
    c->const_interns = xcalloc(c->const_cap, sizeof(char *));
    c->env_ic = xcalloc(c->const_cap, sizeof(EnvIC));
    c->lines_cap = 256;
    c->lines = xcalloc(c->lines_cap, sizeof(int));
    c->fn_cap = 8;
    c->functions = xcalloc(c->fn_cap, sizeof(EigsChunk *));
    c->name = name ? strdup(name) : strdup("<module>");
    c->jit_stop_op = OP_COUNT;  /* sentinel: scan never ran */
    c->jit_osr_stop_op = OP_COUNT;
    c->refcount = 1;            /* creator's ref */
    return c;
}

void chunk_incref(EigsChunk *chunk) {
    if (!chunk) return;
    if (__builtin_expect(g_vm_multithreaded, 0))
        __atomic_add_fetch(&chunk->refcount, 1, __ATOMIC_RELAXED);
    else
        chunk->refcount++;
}

void chunk_decref(EigsChunk *chunk) {
    if (!chunk) return;
    int rc;
    if (__builtin_expect(g_vm_multithreaded, 0))
        rc = __atomic_sub_fetch(&chunk->refcount, 1, __ATOMIC_ACQ_REL);
    else
        rc = --chunk->refcount;
    if (rc > 0) return;
    jit_unregister_chunk(chunk);   /* drop the hotness registry's bare ptr */
    free(chunk->code);
    for (int i = 0; i < chunk->const_count; i++)
        val_decref(chunk->constants[i]);
    free(chunk->constants);
    free(chunk->const_hashes);
    free(chunk->const_interns);
    free(chunk->env_ic);
    free(chunk->lines);
    for (int i = 0; i < chunk->fn_count; i++)
        chunk_decref(chunk->functions[i]);   /* release creator refs */
    free(chunk->functions);
    for (int i = 0; i < chunk->local_count; i++)
        free(chunk->local_names[i]);
    free(chunk->local_names);
    free(chunk->name);
    free(chunk);
}

/* Kept as the public "release the creator's ref" entry point. */
void chunk_free(EigsChunk *chunk) {
    chunk_decref(chunk);
}

/* ---- Emit helpers ---- */

void chunk_emit(EigsChunk *chunk, uint8_t byte, int line) {
    if (chunk->code_len >= chunk->code_cap) {
        chunk->code_cap *= 2;
        chunk->code = realloc(chunk->code, chunk->code_cap);
    }
    if (chunk->lines_len >= chunk->lines_cap) {
        chunk->lines_cap *= 2;
        chunk->lines = realloc(chunk->lines, chunk->lines_cap * sizeof(int));
    }
    chunk->code[chunk->code_len] = byte;
    chunk->lines[chunk->lines_len] = line;
    chunk->code_len++;
    chunk->lines_len++;
}

void chunk_emit_u16(EigsChunk *chunk, uint16_t val, int line) {
    chunk_emit(chunk, (uint8_t)(val & 0xFF), line);
    chunk_emit(chunk, (uint8_t)((val >> 8) & 0xFF), line);
}

/* Emit a jump instruction with a placeholder 16-bit offset.
 * Returns the offset of the placeholder for later patching. */
int chunk_emit_jump(EigsChunk *chunk, uint8_t op, int line) {
    chunk_emit(chunk, op, line);
    int patch = chunk->code_len;
    chunk_emit_u16(chunk, 0xFFFF, line);
    return patch;
}

/* Patch a previously emitted jump placeholder to jump to the current position. */
void chunk_patch_jump(EigsChunk *chunk, int offset) {
    int jump = chunk->code_len - offset - 2;
    if (jump > 0xFFFF) {
        fprintf(stderr, "Bytecode jump too large at offset %d\n", offset);
        return;
    }
    chunk->code[offset] = (uint8_t)(jump & 0xFF);
    chunk->code[offset + 1] = (uint8_t)((jump >> 8) & 0xFF);
}

/* ---- Constant pool ---- */

int chunk_add_constant(EigsChunk *chunk, Value *val) {
    /* Deduplicate numbers and strings */
    for (int i = 0; i < chunk->const_count; i++) {
        Value *existing = chunk->constants[i];
        if (val->type == VAL_NUM && existing->type == VAL_NUM &&
            val->data.num == existing->data.num)
            return i;
        if (val->type == VAL_STR && existing->type == VAL_STR &&
            strcmp(val->data.str, existing->data.str) == 0)
            return i;
    }
    if (chunk->const_count >= chunk->const_cap) {
        int old_cap = chunk->const_cap;
        chunk->const_cap *= 2;
        chunk->constants = realloc(chunk->constants,
                                   chunk->const_cap * sizeof(Value *));
        chunk->const_hashes = realloc(chunk->const_hashes,
                                      chunk->const_cap * sizeof(uint32_t));
        chunk->const_interns = realloc(chunk->const_interns,
                                       chunk->const_cap * sizeof(char *));
        chunk->env_ic = realloc(chunk->env_ic,
                                chunk->const_cap * sizeof(EnvIC));
        memset(chunk->const_hashes + old_cap, 0,
               (chunk->const_cap - old_cap) * sizeof(uint32_t));
        memset(chunk->const_interns + old_cap, 0,
               (chunk->const_cap - old_cap) * sizeof(char *));
        memset(chunk->env_ic + old_cap, 0,
               (chunk->const_cap - old_cap) * sizeof(EnvIC));
    }
    val_incref(val);
    chunk->constants[chunk->const_count] = val;
    if (val->type == VAL_STR)
        chunk->const_interns[chunk->const_count] = env_intern_name(val->data.str);
    return chunk->const_count++;
}

/* ---- Nested functions ---- */

int chunk_add_function(EigsChunk *chunk, EigsChunk *fn) {
    if (chunk->fn_count >= chunk->fn_cap) {
        chunk->fn_cap *= 2;
        chunk->functions = realloc(chunk->functions,
                                   chunk->fn_cap * sizeof(EigsChunk *));
    }
    chunk->functions[chunk->fn_count] = fn;
    return chunk->fn_count++;
}

/* ---- Disassembler ---- */

const char *op_name(uint8_t op) {
    /* Explicit [OP_COUNT] size keeps designated initializers from
     * shrinking the array — otherwise any opcode above the highest
     * designator would read out of bounds. */
    static const char *names[OP_COUNT] = {
        [OP_CONST] = "CONST", [OP_NULL] = "NULL",
        [OP_NUM_ZERO] = "NUM_ZERO", [OP_NUM_ONE] = "NUM_ONE",
        [OP_ADD] = "ADD", [OP_SUB] = "SUB", [OP_MUL] = "MUL",
        [OP_DIV] = "DIV", [OP_MOD] = "MOD",
        [OP_BAND] = "BAND", [OP_BOR] = "BOR", [OP_BXOR] = "BXOR",
        [OP_SHL] = "SHL", [OP_SHR] = "SHR",
        [OP_NEG] = "NEG", [OP_NOT] = "NOT", [OP_BNOT] = "BNOT",
        [OP_EQ] = "EQ", [OP_NE] = "NE", [OP_LT] = "LT",
        [OP_GT] = "GT", [OP_LE] = "LE", [OP_GE] = "GE",
        [OP_GET_LOCAL] = "GET_LOCAL", [OP_SET_LOCAL] = "SET_LOCAL",
        [OP_GET_NAME] = "GET_NAME", [OP_SET_NAME] = "SET_NAME",
        [OP_SET_NAME_LOCAL] = "SET_NAME_LOCAL",
        [OP_SET_FN_NAME_LOCAL] = "SET_FN_NAME_LOCAL",
        [OP_JUMP] = "JUMP", [OP_JUMP_BACK] = "JUMP_BACK",
        [OP_JUMP_IF_FALSE] = "JUMP_IF_FALSE",
        [OP_JUMP_IF_TRUE] = "JUMP_IF_TRUE",
        [OP_JUMP_IF_FALSE_PEEK] = "JUMP_IF_FALSE_PEEK",
        [OP_JUMP_IF_TRUE_PEEK] = "JUMP_IF_TRUE_PEEK",
        [OP_POP] = "POP", [OP_DUP] = "DUP", [OP_DUP2] = "DUP2",
        [OP_CLOSURE] = "CLOSURE", [OP_CALL] = "CALL",
        [OP_RETURN] = "RETURN", [OP_RETURN_NULL] = "RETURN_NULL",
        [OP_LIST] = "LIST", [OP_DICT] = "DICT",
        [OP_INDEX_GET] = "INDEX_GET", [OP_INDEX_SET] = "INDEX_SET",
        [OP_DOT_GET] = "DOT_GET", [OP_DOT_SET] = "DOT_SET",
        [OP_ITER_SETUP] = "ITER_SETUP", [OP_ITER_NEXT] = "ITER_NEXT",
        [OP_LOOP_ENV_FRESH] = "LOOP_ENV_FRESH",
        [OP_LOOP_ENV_END] = "LOOP_ENV_END",
        [OP_BREAK] = "BREAK", [OP_CONTINUE] = "CONTINUE",
        [OP_TRY_BEGIN] = "TRY_BEGIN", [OP_TRY_END] = "TRY_END",
        [OP_OBSERVE_ASSIGN] = "OBSERVE_ASSIGN",
        [OP_OBSERVE_ASSIGN_LOCAL] = "OBSERVE_ASSIGN_LOCAL",
        [OP_INTERROGATE] = "INTERROGATE", [OP_PREDICATE] = "PREDICATE",
        [OP_UNOBSERVED_BEGIN] = "UNOBSERVED_BEGIN",
        [OP_UNOBSERVED_END] = "UNOBSERVED_END",
        [OP_LOOP_STALL_CHECK] = "LOOP_STALL_CHECK",
        [OP_IMPORT] = "IMPORT", [OP_MATCH] = "MATCH",
        [OP_LISTCOMP_BEGIN] = "LISTCOMP_BEGIN",
        [OP_LISTCOMP_APPEND] = "LISTCOMP_APPEND",
        [OP_LINE] = "LINE", [OP_WIDE] = "WIDE",
        [OP_DISPATCH] = "DISPATCH",
        [OP_LOCAL_DOT_GET] = "LOCAL_DOT_GET",
        [OP_LOCAL_DOT_SET] = "LOCAL_DOT_SET",
        [OP_LOCAL_IDX_GET] = "LOCAL_IDX_GET",
        [OP_LOCAL_IDX_DOT_GET] = "LOCAL_IDX_DOT_GET",
        [OP_LOCAL_IDX_DOT_SET] = "LOCAL_IDX_DOT_SET",
        [OP_INTERROGATE_NAMED] = "INTERROGATE_NAMED",
        [OP_INTERROGATE_NAMED_AT] = "INTERROGATE_NAMED_AT",
    };
    if (op < OP_COUNT && names[op]) return names[op];
    return "???";
}

/* Returns 1 if opcode has a 16-bit operand */
static int op_has_u16(uint8_t op) {
    switch (op) {
    case OP_CONST: case OP_GET_LOCAL: case OP_SET_LOCAL:
    case OP_GET_NAME: case OP_SET_NAME: case OP_SET_NAME_LOCAL:
    case OP_SET_FN_NAME_LOCAL:
    case OP_JUMP: case OP_JUMP_BACK:
    case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE:
    case OP_JUMP_IF_FALSE_PEEK: case OP_JUMP_IF_TRUE_PEEK:
    case OP_CLOSURE: case OP_CALL:
    case OP_LIST: case OP_DICT:
    case OP_DOT_GET: case OP_DOT_SET:
    case OP_ITER_NEXT:
    case OP_TRY_BEGIN: case OP_LOOP_STALL_CHECK:
    case OP_OBSERVE_ASSIGN: case OP_OBSERVE_ASSIGN_LOCAL:
    case OP_IMPORT: case OP_MATCH:
    case OP_LINE:
        return 1;
    case OP_INTERROGATE: case OP_PREDICATE:
        return 1; /* kind:8 but padded to 16 for uniformity */
    default:
        return 0;
    }
}

void chunk_disassemble(EigsChunk *chunk, const char *label) {
    fprintf(stderr, "=== %s (%s, %d bytes, %d constants) ===\n",
            label, chunk->name, chunk->code_len, chunk->const_count);
    int i = 0;
    while (i < chunk->code_len) {
        int line = (i < chunk->lines_len) ? chunk->lines[i] : 0;
        uint8_t op = chunk->code[i];
        fprintf(stderr, "%04d [L%d] %-20s", i, line, op_name(op));
        i++;
        if (op_has_u16(op) && i + 1 < chunk->code_len) {
            uint16_t arg = chunk->code[i] | (chunk->code[i + 1] << 8);
            fprintf(stderr, " %d", arg);
            if (op == OP_CONST && arg < (uint16_t)chunk->const_count) {
                Value *v = chunk->constants[arg];
                if (v->type == VAL_NUM)
                    fprintf(stderr, " (%.6g)", v->data.num);
                else if (v->type == VAL_STR)
                    fprintf(stderr, " (\"%s\")", v->data.str);
            }
            i += 2;
        }
        fprintf(stderr, "\n");
    }
    for (int f = 0; f < chunk->fn_count; f++) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s.fn[%d]", label, f);
        chunk_disassemble(chunk->functions[f], buf);
    }
}
