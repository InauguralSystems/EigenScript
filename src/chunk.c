/* ================================================================
 * EigenScript Bytecode Chunk — allocation, emit, disassemble
 * ================================================================ */

#include "eigenscript.h"
#include "vm.h"
#include "jit.h"
#include "trace.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Chunk lifecycle ---- */

/* #407: caret-excerpt source blob — see EigsSrcBuf in vm.h. */
EigsSrcBuf *srcbuf_new(const char *text) {
    if (!text) return NULL;
    EigsSrcBuf *sb = xcalloc(1, sizeof(EigsSrcBuf));
    sb->text = strdup(text);
    sb->refcount = 1;
    return sb;
}

void srcbuf_incref(EigsSrcBuf *sb) {
    if (!sb) return;
    if (__builtin_expect(g_vm_multithreaded, 0))
        __atomic_add_fetch(&sb->refcount, 1, __ATOMIC_RELAXED);
    else
        sb->refcount++;
}

void srcbuf_decref(EigsSrcBuf *sb) {
    if (!sb) return;
    int rc;
    if (__builtin_expect(g_vm_multithreaded, 0))
        rc = __atomic_sub_fetch(&sb->refcount, 1, __ATOMIC_ACQ_REL);
    else
        rc = --sb->refcount;
    if (rc > 0) return;
    free(sb->text);
    free(sb);
}

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
    c->cols = xcalloc(c->lines_cap, sizeof(int));
    c->fn_cap = 8;
    c->functions = xcalloc(c->fn_cap, sizeof(EigsChunk *));
    c->name = name ? strdup(name) : strdup("<module>");
    c->jit_stop_op = OP_COUNT;  /* sentinel: scan never ran */
    for (int k = 0; k < JIT_OSR_SLOTS; k++)
        c->jit_osr[k].stop_op = OP_COUNT;
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
    free(chunk->const_dedup);
    free(chunk->env_ic);
    /* Stage 5i: release the parked call env (not captured, all slots
     * already null; the chunk holds its single ref — env_decref destroys
     * it and drops its owned parent ref). */
    env_decref(chunk->env_cache);
    free(chunk->lines);
    free(chunk->cols);
    srcbuf_decref(chunk->src);
    for (int i = 0; i < chunk->fn_count; i++)
        chunk_decref(chunk->functions[i]);   /* release creator refs */
    free(chunk->functions);
    /* Module chunks can carry promoted local slots (local_count > 0)
     * without a local_names array — only fn/lambda chunks build one. */
    if (chunk->local_names) {
        for (int i = 0; i < chunk->local_count; i++)
            free(chunk->local_names[i]);
        free(chunk->local_names);
    }
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
        chunk->cols  = realloc(chunk->cols,  chunk->lines_cap * sizeof(int));
    }
    chunk->code[chunk->code_len] = byte;
    chunk->lines[chunk->lines_len] = line;
    chunk->cols[chunk->lines_len]  = chunk->cur_col;
    chunk->code_len++;
    chunk->lines_len++;
}

void chunk_emit_u16(EigsChunk *chunk, uint16_t val, int line) {
    chunk_emit(chunk, (uint8_t)(val & 0xFF), line);
    chunk_emit(chunk, (uint8_t)((val >> 8) & 0xFF), line);
}

/* #630: little-endian 32-bit operand — currently only OP_LINE, whose line
 * number legitimately exceeds 65535 in generated programs. Read by read_u32. */
void chunk_emit_u32(EigsChunk *chunk, uint32_t val, int line) {
    chunk_emit(chunk, (uint8_t)(val & 0xFF), line);
    chunk_emit(chunk, (uint8_t)((val >> 8) & 0xFF), line);
    chunk_emit(chunk, (uint8_t)((val >> 16) & 0xFF), line);
    chunk_emit(chunk, (uint8_t)((val >> 24) & 0xFF), line);
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
        /* Operand is u16; a larger forward jump can't be encoded. Flag a
         * parse/compile error so the entry paths abort before executing, and
         * write a safe in-bounds 0 (jump-to-next) rather than leaving the
         * 0xFFFF placeholder — the old code returned with 0xFFFF in place and
         * no error flag, so the VM later jumped 65535 bytes out of bounds. */
        fprintf(stderr, "Bytecode jump too large at offset %d\n", offset);
        g_parse_errors++;
        jump = 0;
    }
    chunk->code[offset] = (uint8_t)(jump & 0xFF);
    chunk->code[offset + 1] = (uint8_t)((jump >> 8) & 0xFF);
}

/* ---- Constant pool ---- */

/* ---- Constant-pool dedup index (#341) ----
 * Equality is EXACTLY the old linear scan's tests, so pools stay
 * byte-identical (the AOT oracle depends on that): NaN never equals
 * itself (each NaN appends), and -0.0 merges with +0.0 (they hash the
 * same and compare ==). Non-NUM/STR constants are never deduped. */
static uint32_t const_hash_value(const Value *v) {
    if (v->type == VAL_NUM) {
        double d = v->data.num;
        if (d == 0.0) d = 0.0;   /* fold -0.0 into +0.0, matching == */
        uint64_t bits;
        memcpy(&bits, &d, sizeof bits);
        bits ^= bits >> 33;
        bits *= 0xff51afd7ed558ccdULL;
        bits ^= bits >> 33;
        return (uint32_t)bits;
    }
    uint32_t h = 2166136261u;    /* FNV-1a */
    for (const char *p = v->data.str; *p; p++) {
        h ^= (unsigned char)*p;
        h *= 16777619u;
    }
    return h;
}

static int const_equal(const Value *a, const Value *b) {
    if (a->type == VAL_NUM && b->type == VAL_NUM)
        return a->data.num == b->data.num;
    if (a->type == VAL_STR && b->type == VAL_STR)
        return strcmp(a->data.str, b->data.str) == 0;
    return 0;
}

static void const_dedup_insert(EigsChunk *c, uint32_t h, int idx) {
    uint32_t mask = (uint32_t)c->const_dedup_cap - 1;
    uint32_t s = h & mask;
    while (c->const_dedup[s]) s = (s + 1) & mask;
    c->const_dedup[s] = idx + 1;
}

static void const_dedup_grow(EigsChunk *c) {
    int new_cap = c->const_dedup_cap ? c->const_dedup_cap * 2 : 64;
    free(c->const_dedup);
    c->const_dedup = xcalloc(new_cap, sizeof(int));
    c->const_dedup_cap = new_cap;
    for (int i = 0; i < c->const_count; i++) {
        Value *v = c->constants[i];
        if (v->type == VAL_NUM || v->type == VAL_STR)
            const_dedup_insert(c, const_hash_value(v), i);
    }
}

static int chunk_add_constant_ex(EigsChunk *chunk, Value *val, int dedup) {
    /* Deduplicate numbers and strings via the hash index — the linear
     * scan here was O(pool) per add: 92% of compile time on a 12k-name
     * generated program (#341). */
    int hashable = (val->type == VAL_NUM || val->type == VAL_STR);
    uint32_t h = 0;
    if (hashable) {
        if ((chunk->const_count + 1) * 2 > chunk->const_dedup_cap)
            const_dedup_grow(chunk);
        h = const_hash_value(val);
        uint32_t mask = (uint32_t)chunk->const_dedup_cap - 1;
        uint32_t s = h & mask;
        while (chunk->const_dedup[s]) {
            int idx = chunk->const_dedup[s] - 1;
            if (dedup && const_equal(val, chunk->constants[idx]))
                return idx;
            s = (s + 1) & mask;
        }
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
    if (val->type == VAL_STR) {
        chunk->const_interns[chunk->const_count] = env_intern_name(val->data.str);
        /* #297: precompute the name hash here (compile time, single-threaded)
         * instead of lazily caching it on first use in the VM name handlers —
         * that `if (h==0) const_hashes[idx]=h` lazy write raced when parallel
         * workers ran the same chunk. Eager + idempotent + a tiny perf win
         * (no runtime hashing). Matches env_hash_name(const_interns[idx]). */
        if (chunk->const_hashes)
            chunk->const_hashes[chunk->const_count] = env_hash_name(val->data.str);
    }
    if (hashable)
        const_dedup_insert(chunk, h, chunk->const_count);
    return chunk->const_count++;
}

int chunk_add_constant(EigsChunk *chunk, Value *val) {
    return chunk_add_constant_ex(chunk, val, 1);
}

/* Append without dedup, so the returned index always equals the value's
 * position in the order it was added. For pools that arrive already indexed
 * by position — a bytecode DESCRIPTOR, whose code stream refers to constants
 * positionally. Routing those through the deduplicating add collapsed a
 * repeated number/string, shifted every later index down, and the code then
 * loaded the wrong constant with no error anywhere (#721).
 * (Leaving duplicates in the dedup index is harmless: a later lookup can
 * return either copy, and const_equal guarantees they are interchangeable.) */
int chunk_add_constant_positional(EigsChunk *chunk, Value *val) {
    return chunk_add_constant_ex(chunk, val, 0);
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

/* #737: an exhaustive switch on OpCode with NO default arm —
 * -Werror=switch (already in CFLAGS) turns a missing opcode into a build
 * error instead of a silent "???". The strings are derived from the enum
 * spellings themselves (#o + 3 strips "OP_"), so a name can't drift from
 * its opcode either. The old designated-initializer array was missing
 * four opcodes and nothing could notice. */
const char *op_name(uint8_t op) {
    if (op >= OP_COUNT) return "???";
    switch ((OpCode)op) {
#define N(o) case o: return #o + 3;
    N(OP_CONST) N(OP_NULL) N(OP_NUM_ZERO) N(OP_NUM_ONE)
    N(OP_ADD) N(OP_SUB) N(OP_MUL) N(OP_DIV) N(OP_MOD)
    N(OP_BAND) N(OP_BOR) N(OP_BXOR) N(OP_SHL) N(OP_SHR)
    N(OP_NEG) N(OP_NOT) N(OP_BNOT)
    N(OP_EQ) N(OP_NE) N(OP_LT) N(OP_GT) N(OP_LE) N(OP_GE)
    N(OP_GET_LOCAL) N(OP_SET_LOCAL) N(OP_GET_NAME) N(OP_SET_NAME)
    N(OP_SET_NAME_LOCAL) N(OP_SET_FN_NAME_LOCAL)
    N(OP_JUMP) N(OP_JUMP_BACK) N(OP_JUMP_IF_FALSE) N(OP_JUMP_IF_TRUE)
    N(OP_JUMP_IF_FALSE_PEEK) N(OP_JUMP_IF_TRUE_PEEK)
    N(OP_POP) N(OP_DUP) N(OP_DUP2)
    N(OP_CLOSURE) N(OP_CALL) N(OP_RETURN) N(OP_RETURN_NULL)
    N(OP_LIST) N(OP_DICT) N(OP_INDEX_GET) N(OP_INDEX_SET)
    N(OP_DOT_GET) N(OP_DOT_SET)
    N(OP_ITER_SETUP) N(OP_ITER_NEXT)
    N(OP_LOOP_ENV_FRESH) N(OP_LOOP_ENV_END) N(OP_LOOP_ENV_CLEAR)
    N(OP_BREAK) N(OP_CONTINUE)
    N(OP_TRY_BEGIN) N(OP_TRY_END)
    N(OP_OBSERVE_ASSIGN) N(OP_OBSERVE_ASSIGN_LOCAL) N(OP_OBSERVE_NAME_POST)
    N(OP_INTERROGATE) N(OP_PREDICATE)
    N(OP_UNOBSERVED_BEGIN) N(OP_UNOBSERVED_END)
    N(OP_LOOP_STALL_CHECK) N(OP_LOOP_CAP_CHECK)
    N(OP_IMPORT) N(OP_MATCH)
    N(OP_LISTCOMP_BEGIN) N(OP_LISTCOMP_APPEND)
    N(OP_LINE) N(OP_WIDE) N(OP_DISPATCH)
    N(OP_LOCAL_DOT_GET) N(OP_LOCAL_DOT_SET) N(OP_LOCAL_IDX_GET)
    N(OP_LOCAL_IDX_DOT_GET) N(OP_LOCAL_IDX_DOT_SET)
    N(OP_INTERROGATE_NAMED) N(OP_INTERROGATE_NAMED_AT)
    N(OP_INTERROGATE_NAMED_WHEN)
    N(OP_DEFAULT_PARAM) N(OP_DESTRUCTURE_UNPACK) N(OP_SLICE_GET)
    N(OP_REPORT_SLOT)
    N(OP_REPORT_NAME) N(OP_OBSERVE_VALUE_SLOT) N(OP_OBSERVE_VALUE_NAME)
    N(OP_PREDICATE_SLOT) N(OP_PREDICATE_NAME)
    N(OP_REPORT_VALUE_SLOT) N(OP_REPORT_VALUE_NAME)
    N(OP_TRAJECTORY_SLOT) N(OP_TRAJECTORY_NAME)
#undef N
    case OP_COUNT: break;   /* unreachable: bounds-checked above */
    }
    return "???";
}

/* Forward decls: the operand-layout table lives with the verifier below;
 * the disassembler is driven off the SAME table (#737 — the old separate
 * op_has_u16 boolean had drifted on 8 single-operand opcodes and could not
 * express the multi-operand superinstructions at all, so chunk_disassemble
 * desynchronized on 15 opcodes). */
typedef enum {
    VR_RAW = 0,   /* count / kind / line / runtime-guarded slot — no bound */
    VR_CONST,     /* constant-pool index — any value type (OP_CONST push) */
    VR_NAME,      /* constant-pool index that MUST be a string: the VM derefs it
                   * as an interned name (const_interns[idx]), which is NULL for
                   * a non-string constant → NULL deref. Bound AND type-check. */
    VR_FN,        /* index into nested functions[] */
    VR_JFWD,      /* forward jump: target = end_of_instruction + offset */
    VR_JBACK      /* backward jump: target = end_of_instruction - offset */
} VerifyRole;
static int op_verify_operands(uint8_t op8, VerifyRole roles[3]);

void chunk_disassemble(EigsChunk *chunk, const char *label) {
    fprintf(stderr, "=== %s (%s, %d bytes, %d constants) ===\n",
            label, chunk->name, chunk->code_len, chunk->const_count);
    int i = 0;
    while (i < chunk->code_len) {
        int line = (i < chunk->lines_len) ? chunk->lines[i] : 0;
        uint8_t op = chunk->code[i];
        fprintf(stderr, "%04d [L%d] %-20s", i, line, op_name(op));
        i++;
        if (op == OP_LINE && i + 3 < chunk->code_len) {
            /* #630: 32-bit operand. */
            uint32_t arg = (uint32_t)chunk->code[i] |
                           ((uint32_t)chunk->code[i + 1] << 8) |
                           ((uint32_t)chunk->code[i + 2] << 16) |
                           ((uint32_t)chunk->code[i + 3] << 24);
            fprintf(stderr, " %u", arg);
            i += 4;
        } else if (op < OP_COUNT) {
            VerifyRole roles[3];
            int nops = op_verify_operands(op, roles);
            for (int k = 0; k < nops && i + 1 < chunk->code_len; k++) {
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
        }
        fprintf(stderr, "\n");
    }
    for (int f = 0; f < chunk->fn_count; f++) {
        char buf[128];
        snprintf(buf, sizeof(buf), "%s.fn[%d]", label, f);
        chunk_disassemble(chunk->functions[f], buf);
    }
}

/* ---- Bytecode verifier (for untrusted assembled chunks) ----
 *
 * vm_run_bytecode / sandbox_run build a chunk from caller-supplied values and
 * run it on the same VM the C compiler's output uses. The VM trusts operand
 * indices, so a hand-crafted descriptor carrying an out-of-range constant,
 * function, or jump operand drove an out-of-bounds read (segfault) straight
 * past the sandbox's name-deny-list and loop cap. This one-pass verifier
 * rejects such a chunk before it can run.
 *
 * Checked: every opcode is known (< OP_COUNT) and its operands fit in code;
 * constant/name indices are < const_count; function indices are < fn_count;
 * every jump target lands on an instruction boundary inside code; and (pass 4)
 * the operand stack cannot underflow along any path. NOT checked:
 * local/observer slot operands — the VM already guards every slot access
 * (slot < env->count; observer slots auto-grow), so they cannot fault. */
/* Fill roles[] for op; return its operand count (0..3). Mirrors the operand
 * layout the VM decodes in vm.c — keep in lockstep if an opcode changes.
 *
 * #737: this is now an EXHAUSTIVE switch on OpCode with NO default arm, so
 * -Werror=switch turns a missing opcode into a build error. The old
 * `default: return 0` silently walked an unknown 3-byte instruction as
 * 1 byte, which marked its operand bytes as valid instruction boundaries —
 * a crafted jump could land mid-instruction and still pass pass 2 (the
 * #721 surface; OP_TRAJECTORY_SLOT had already drifted out this way while
 * its NAME sibling was present). Callers must bounds-check op < OP_COUNT
 * first (chunk_verify pass 1 and the disassembler both do). This is also
 * the disassembler's stepping table — one layout source, not two. */
static int op_verify_operands(uint8_t op8, VerifyRole roles[3]) {
    switch ((OpCode)op8) {
    case OP_CONST:
        roles[0] = VR_CONST; return 1;
    case OP_GET_NAME: case OP_SET_NAME: case OP_SET_NAME_LOCAL:
    case OP_SET_FN_NAME_LOCAL: case OP_DOT_GET: case OP_DOT_SET:
    case OP_REPORT_NAME: case OP_OBSERVE_VALUE_NAME: case OP_OBSERVE_NAME_POST:
    case OP_REPORT_VALUE_NAME: case OP_TRAJECTORY_NAME:
    case OP_IMPORT:
        roles[0] = VR_NAME; return 1;
    case OP_CLOSURE:
        roles[0] = VR_FN; return 1;
    case OP_JUMP: case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE:
    case OP_JUMP_IF_FALSE_PEEK: case OP_JUMP_IF_TRUE_PEEK:
    case OP_ITER_NEXT: case OP_TRY_BEGIN:
    case OP_LOOP_STALL_CHECK: case OP_LOOP_CAP_CHECK:
        roles[0] = VR_JFWD; return 1;
    case OP_JUMP_BACK:
        roles[0] = VR_JBACK; return 1;
    case OP_GET_LOCAL: case OP_SET_LOCAL: case OP_CALL:
    case OP_LIST: case OP_DICT:
    case OP_OBSERVE_ASSIGN: case OP_OBSERVE_ASSIGN_LOCAL:
    case OP_REPORT_SLOT: case OP_OBSERVE_VALUE_SLOT:
    case OP_REPORT_VALUE_SLOT:
    case OP_TRAJECTORY_SLOT:   /* #737: was missing — the drift this fixes */
    case OP_INTERROGATE: case OP_PREDICATE:
    case OP_MATCH: case OP_DESTRUCTURE_UNPACK:
        roles[0] = VR_RAW; return 1;
    case OP_LOCAL_DOT_GET: case OP_LOCAL_DOT_SET:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;    /* slot, name */
    case OP_LOCAL_IDX_GET:
        roles[0] = VR_RAW; roles[1] = VR_RAW; return 2;     /* slot, list idx */
    case OP_INTERROGATE_NAMED: case OP_INTERROGATE_NAMED_AT:
    case OP_INTERROGATE_NAMED_WHEN:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;    /* kind, name */
    case OP_PREDICATE_SLOT:
        roles[0] = VR_RAW; roles[1] = VR_RAW; return 2;     /* kind, slot (runtime-guarded) */
    case OP_PREDICATE_NAME:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;    /* kind, name */
    case OP_DEFAULT_PARAM:
        roles[0] = VR_RAW; roles[1] = VR_JFWD; return 2;    /* slot, skip */
    case OP_LOCAL_IDX_DOT_GET: case OP_LOCAL_IDX_DOT_SET:
        roles[0] = VR_RAW; roles[1] = VR_RAW; roles[2] = VR_NAME; return 3;
    /* Operand-free opcodes — every one listed, so a new opcode cannot
     * silently walk wrong. */
    case OP_NULL: case OP_NUM_ZERO: case OP_NUM_ONE:
    case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
    case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
    case OP_NEG: case OP_NOT: case OP_BNOT:
    case OP_EQ: case OP_NE: case OP_LT: case OP_GT: case OP_LE: case OP_GE:
    case OP_POP: case OP_DUP: case OP_DUP2:
    case OP_RETURN: case OP_RETURN_NULL:
    case OP_INDEX_GET: case OP_INDEX_SET:
    case OP_ITER_SETUP:
    case OP_LOOP_ENV_FRESH: case OP_LOOP_ENV_END: case OP_LOOP_ENV_CLEAR:
    case OP_BREAK: case OP_CONTINUE:
    case OP_TRY_END:
    case OP_UNOBSERVED_BEGIN: case OP_UNOBSERVED_END:
    case OP_LISTCOMP_BEGIN: case OP_LISTCOMP_APPEND:
    case OP_WIDE:      /* placeholder — the VM decodes no operand either */
    case OP_DISPATCH:
    case OP_SLICE_GET:
        return 0;
    /* OP_LINE's operand is 32-bit (#630); chunk_verify and the
     * disassembler both special-case it BEFORE consulting this u16-strided
     * table, so this arm is unreachable — listed for the exhaustiveness
     * gate, not for behavior. */
    case OP_LINE:
        return 0;
    case OP_COUNT:     /* sentinel — callers bounds-check first */
        return 0;
    }
    return 0;   /* unreachable; silences non-GCC fallthrough warnings */
}

/* ---- Stack-height model (pass 4) ----
 *
 * How much operand stack an instruction requires, and what it leaves behind on
 * each outgoing edge. The interpreter's fast paths index g_vm.stack[sp - 1] /
 * [sp - 2] directly (ARITH_FAST and friends, vm.c) instead of going through the
 * guarded vm_pop(), so an opcode reached with too few operands reads — and for
 * the in-place num-reuse arms, WRITES — below the base of the VM stack. That is
 * a heap-buffer-overflow off a calloc'd EigsSlot[65536], reported against
 * sandbox_run with a two-byte chunk (`[OP_ADD, OP_RETURN]`), and the guarded pop
 * is exactly the path those opcodes skip for speed. Bounds-checking ~90 direct
 * accesses in the hottest loop in the runtime is the wrong trade; the height is
 * a static property of the code, so verify it once at the gate and the fast
 * paths keep their invariant for free.
 *
 * The model has to be EXACT, not merely conservative: the height it predicts is
 * what the next instruction's requirement is checked against, so a row that is
 * off by one anywhere corrupts every check downstream of it.
 *
 *   need    minimum height required before the instruction executes
 *   pops    operands consumed
 *   pushes  results pushed on the fall-through edge; bpushes on the branch edge
 *           (they differ only for ITER_NEXT and TRY_BEGIN)
 *
 * Heights are relative to the frame's base pointer: a call pops its args and
 * callee before pushing the frame (CASE(CALL), vm.c), so every chunk starts at
 * height 0 and OP_RETURN's drain (`while (sp > frame->bp)`) bounds the window
 * from below.
 *
 * THE FRAME BASE IS WHY `need` EQUALS `pops` EVEN FOR THE "GUARDED" OPCODES.
 * It is tempting to let the handlers that pop through vm_pop() (DIV, MOD,
 * DOT_GET, ITER_SETUP, the interrogatives) ask for nothing, since vm_pop
 * returns null instead of reading off the end — but its guard is `sp <= 0`, the
 * bottom of the WHOLE VM stack, not the bottom of this frame's window. A chunk
 * run by sandbox_run from inside a host expression has bp > 0, so an
 * under-fed pop there quietly takes the CALLER's operand, hands it to the chunk,
 * and decrefs it on the way out: the host's own value is freed underneath it —
 * "double free or corruption (out)" again, one frame up, with no sanitizer
 * report at the moment of the pop. OP_LIST/OP_DICT clamp their base at 0 and
 * OP_CALL bails when under-fed, both against the same wrong floor. Only
 * OP_RETURN compares against frame->bp, and it is the only row here that may
 * ask for nothing.
 *
 * Like op_verify_operands this is an EXHAUSTIVE switch with NO default arm, so
 * -Werror=switch makes a new opcode a build error here (#737) rather than a
 * silently unmodelled one — an unmodelled opcode defaulting to "needs nothing"
 * is precisely the hole this pass exists to close. Keep it in lockstep with the
 * handler in vm.c; run_all_tests.sh runs the C compiler's own output through
 * this pass over the whole suite (EIGS_VERIFY_SELF=1), so a row that drifts in
 * either direction fails there.
 *
 * compiler.c has a NET-DELTA twin (its own op_stack_effect, sizing max_stack
 * during compilation). It is not interchangeable with this one — it carries no
 * `need` and no control flow, which is the entire content of a safety check —
 * but the two must agree where they overlap: for every opcode, that function's
 * delta is this one's pushes - pops on the fall-through edge. Keep the names
 * distinct: the embed/LSP builds amalgamate every source into ONE translation
 * unit (build/eigenscript_all.c), so two file-static functions sharing a name
 * is a build error there and nowhere else — CI's embed-smoke is the only gate
 * that sees it. */
typedef enum {
    FL_NEXT,     /* falls through only */
    FL_BRANCH,   /* falls through OR takes the jump operand */
    FL_JUMP,     /* takes the jump operand, never falls through */
    FL_END       /* leaves the frame — no successor in this chunk */
} VerifyFlow;

typedef struct { int need, pops, pushes, bpushes; VerifyFlow flow; } StackEffect;

/* operand0 is the instruction's first 16-bit operand (0 when it has none) —
 * argc/count/n for the variable-arity opcodes. */
static StackEffect op_verify_stack_effect(uint8_t op8, int operand0) {
    /* need, pops, pushes */
    #define EFF(n_, p_, u_)        ((StackEffect){ (n_), (p_), (u_), 0, FL_NEXT })
    /* need, pops, pushes on fall-through, pushes on the branch edge */
    #define EFF_BR(n_, p_, u_, b_) ((StackEffect){ (n_), (p_), (u_), (b_), FL_BRANCH })
    switch ((OpCode)op8) {
    /* Pushes, consuming nothing. */
    case OP_CONST: case OP_NULL: case OP_NUM_ZERO: case OP_NUM_ONE:
    case OP_GET_LOCAL: case OP_GET_NAME: case OP_CLOSURE:
    case OP_LOCAL_DOT_GET: case OP_LOCAL_IDX_GET: case OP_LOCAL_IDX_DOT_GET:
    case OP_IMPORT: case OP_MATCH: case OP_LISTCOMP_BEGIN:
    case OP_PREDICATE: case OP_PREDICATE_SLOT: case OP_PREDICATE_NAME:
    case OP_REPORT_SLOT: case OP_REPORT_NAME:
    case OP_REPORT_VALUE_SLOT: case OP_REPORT_VALUE_NAME:
    case OP_OBSERVE_VALUE_SLOT: case OP_OBSERVE_VALUE_NAME:
    case OP_TRAJECTORY_SLOT: case OP_TRAJECTORY_NAME:
        return EFF(0, 0, 1);

    /* Reads TOS in place and leaves it there (an assignment opcode keeps the
     * assigned value as the expression's result). Every one of these takes an
     * unguarded g_vm.stack[sp - 1] — in the observer cases through
     * vm_trace_assign / the slot-observe helpers, which index it the same way. */
    case OP_SET_LOCAL: case OP_SET_NAME: case OP_SET_NAME_LOCAL:
    case OP_SET_FN_NAME_LOCAL: case OP_LOCAL_DOT_SET: case OP_LOCAL_IDX_DOT_SET:
    case OP_OBSERVE_ASSIGN: case OP_OBSERVE_ASSIGN_LOCAL: case OP_OBSERVE_NAME_POST:
        return EFF(1, 0, 0);

    /* Direct-index unary: [sp - 1] read and overwritten in place. */
    case OP_NEG: case OP_NOT: case OP_BNOT:
        return EFF(1, 1, 1);

    /* ARITH_FAST and its comparison/bitwise twins: [sp-1] and [sp-2] read, and
     * in the num-reuse arms WRITTEN, before any guard. The reported hole. */
    case OP_ADD: case OP_SUB: case OP_MUL:
    case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
    case OP_EQ: case OP_NE: case OP_LT: case OP_GT: case OP_LE: case OP_GE:
    case OP_INDEX_GET: case OP_DOT_SET:
        return EFF(2, 2, 1);

    /* DIV and MOD have no fast path — both operands come off vm_pop(). Same for
     * DOT_GET, ITER_SETUP and the interrogatives. They still require their
     * operands: see the frame-base note above — vm_pop()'s guard is the bottom
     * of the whole VM stack, not the bottom of this frame's window. */
    case OP_DIV: case OP_MOD:
        return EFF(2, 2, 1);
    case OP_DOT_GET: case OP_ITER_SETUP:
    case OP_INTERROGATE: case OP_INTERROGATE_NAMED:
    case OP_INTERROGATE_NAMED_AT: case OP_INTERROGATE_NAMED_WHEN:
        return EFF(1, 1, 1);

    /* Three direct-index reads before the type checks. */
    case OP_INDEX_SET: case OP_SLICE_GET: case OP_DISPATCH:
        return EFF(3, 3, 1);

    case OP_POP:                       /* stack[--sp], unguarded */
        return EFF(1, 1, 0);
    case OP_DUP:
        return EFF(1, 0, 1);
    case OP_DUP2:
        return EFF(2, 0, 2);

    /* Variable arity. LIST/DICT clamp their own base and CALL bails when
     * under-fed, so none of these reads past the VM stack — but the clamp is
     * again against 0, not this frame's base, so an over-claimed count consumes
     * the CALLER's operands. Require what they consume. */
    case OP_LIST:
        return EFF(operand0, operand0, 1);
    case OP_DICT:
        return EFF(2 * operand0, 2 * operand0, 1);
    case OP_CALL:
        return EFF(operand0 + 1, operand0 + 1, 1);
    /* Pops the list through a direct index, then pushes its n elements. */
    case OP_DESTRUCTURE_UNPACK:
        return EFF(1, 1, operand0);
    /* Item via vm_pop(); the accumulator two below is read under an explicit
     * `sp >= 2` guard — which, being relative to sp, says nothing about bp. */
    case OP_LISTCOMP_APPEND:
        return EFF(2, 1, 0);

    /* Conditional control flow. The non-PEEK conditionals pop on BOTH edges via
     * stack[--sp]; the PEEK pair leaves the tested value in place for the
     * short-circuit `and`/`or` shape. Both index directly. */
    case OP_JUMP_IF_FALSE: case OP_JUMP_IF_TRUE:
        return EFF_BR(1, 1, 0, 0);
    case OP_JUMP_IF_FALSE_PEEK: case OP_JUMP_IF_TRUE_PEEK:
        return EFF_BR(1, 0, 0, 0);
    /* vm_peek(0) on the iterator state is an unguarded stack[sp - 1]. Falling
     * through advances and pushes the element; the taken edge is loop exit with
     * the state still on the stack, for the POP the loop epilogue emits. */
    case OP_ITER_NEXT:
        return EFF_BR(1, 0, 1, 0);
    /* Jump operand is the loop-exit / skip target; neither edge touches the
     * stack. TRY_BEGIN's "branch" is its catch handler: an unwind drains back to
     * the height recorded here (catch_bp) and pushes the error value, so the
     * handler is entered exactly one deeper — see CHECK_ERROR in vm.c. */
    case OP_LOOP_STALL_CHECK: case OP_LOOP_CAP_CHECK: case OP_DEFAULT_PARAM:
        return EFF_BR(0, 0, 0, 0);
    case OP_TRY_BEGIN:
        return EFF_BR(0, 0, 0, 1);

    case OP_JUMP: case OP_JUMP_BACK:
        return (StackEffect){ 0, 0, 0, 0, FL_JUMP };
    /* RETURN needs nothing: its own read is height-guarded (`sp > frame->bp`)
     * and yields null when the frame window is empty. */
    case OP_RETURN: case OP_RETURN_NULL:
        return (StackEffect){ 0, 0, 0, 0, FL_END };

    /* Stack-neutral. BREAK/CONTINUE set a flag nothing reads — the compiler
     * lowers both to jumps — so they are pure no-ops here too. */
    case OP_LINE: case OP_WIDE:
    case OP_TRY_END: case OP_BREAK: case OP_CONTINUE:
    case OP_LOOP_ENV_FRESH: case OP_LOOP_ENV_END: case OP_LOOP_ENV_CLEAR:
    case OP_UNOBSERVED_BEGIN: case OP_UNOBSERVED_END:
        return EFF(0, 0, 0);

    case OP_COUNT:   /* sentinel — callers bounds-check first */
        return EFF(0, 0, 0);
    }
    return EFF(0, 0, 0);   /* unreachable; silences non-GCC fallthrough warnings */
    #undef EFF
    #undef EFF_BR
}

/* why/whyn: optional diagnostic buffer — the EIGS_VERIFY_SELF gate reports WHICH
 * instruction a chunk was rejected at, so a stack-effect row that drifts out of
 * lockstep with vm.c names itself instead of just failing the suite. NULL for
 * the production callers, which only need the verdict. */
static int chunk_verify_impl(EigsChunk *chunk, char *why, size_t whyn) {
    #define WHY(...) do { if (why) snprintf(why, whyn, __VA_ARGS__); } while (0)
    if (!chunk || chunk->code_len <= 0) { WHY("empty code"); return 0; }
    int n = chunk->code_len;
    const uint8_t *code = chunk->code;
    unsigned char *is_start = calloc((size_t)n + 1, 1);
    int *targets = malloc((size_t)n * sizeof(int));
    if (!is_start || !targets) { free(is_start); free(targets); return 0; }
    int ntargets = 0, ok = 1, i = 0;
    uint8_t last_op = OP_NULL;   /* opcode of the instruction ending at code_len */

    /* Pass 1: validate opcodes/operands/pool indices; mark instruction starts;
     * stash jump targets (validated in pass 2 once is_start[] is complete). */
    while (i < n) {
        uint8_t op = code[i];
        if (op >= OP_COUNT) { ok = 0; break; }
        is_start[i] = 1;
        last_op = op;
        /* #630: OP_LINE has a single 32-bit operand — outside the u16-strided
         * role machinery below. No index to validate; just skip 4 bytes. */
        if (op == OP_LINE) {
            int end = i + 1 + 4;
            if (end > n) { ok = 0; break; }
            i = end;
            continue;
        }
        VerifyRole roles[3];
        int nops = op_verify_operands(op, roles);
        int end = i + 1 + 2 * nops;
        if (end > n) { ok = 0; break; }   /* truncated operand */
        for (int k = 0; k < nops && ok; k++) {
            int pos = i + 1 + 2 * k;
            int operand = code[pos] | (code[pos + 1] << 8);
            switch (roles[k]) {
            case VR_CONST: if (operand >= chunk->const_count) ok = 0; break;
            case VR_NAME:  if (operand >= chunk->const_count ||
                               chunk->constants[operand]->type != VAL_STR) ok = 0;
                           break;
            case VR_FN:    if (operand >= chunk->fn_count)    ok = 0; break;
            case VR_JFWD:  targets[ntargets++] = end + operand; break;
            case VR_JBACK: targets[ntargets++] = end - operand; break;
            default: break;
            }
        }
        if (!ok) break;
        i = end;
    }

    /* Pass 2: every jump must land on an in-range instruction boundary. */
    for (int t = 0; ok && t < ntargets; t++) {
        int tgt = targets[t];
        if (tgt < 0 || tgt >= n || !is_start[tgt]) ok = 0;
    }

    /* Pass 3: execution must not be able to run off the end. Pass 2 pins every
     * jump inside the code, and every other instruction falls through to the
     * next instruction start — so the ONLY escape is the last instruction
     * falling through past code_len, into the zeroed slack of the code buffer.
     * Byte 0 decodes as OP_CONST[0], which the VM pushes with no NULL check,
     * and from there ip marches through unowned heap. `chunk ends in RETURN`
     * was documented as a caller obligation (builtins.c), but for
     * vm_run_bytecode — and above all sandbox_run, the advertised containment
     * boundary since #717 — removing exactly that trust is this function's
     * job. Require a terminator: return, or an unconditional jump (a bare
     * infinite loop is stall-capped by the VM, not a memory-safety fault). */
    if (ok && last_op != OP_RETURN && last_op != OP_RETURN_NULL &&
        last_op != OP_JUMP && last_op != OP_JUMP_BACK)
        ok = 0;
    if (!ok) WHY("malformed code, opcode/operand/jump/terminator (passes 1-3)");

    /* Pass 4: the operand stack must not underflow along any path. Abstract
     * interpretation over the CFG passes 1-2 just validated: walk from entry
     * (height 0) propagating the height to each successor, and reject a chunk
     * that reaches an instruction with fewer operands than it consumes. The
     * height at a given instruction must AGREE on every incoming edge — the
     * JVM/Wasm rule. That is what keeps this linear (each instruction is visited
     * once, so a hostile chunk cannot make verification itself the DoS), and it
     * is the contract a producer already meets: every path reaching a join in
     * compiler output arrives balanced, which the EIGS_VERIFY_SELF gate holds
     * us to over the whole suite.
     *
     * A height above VM_STACK_MAX is rejected rather than left to fault later:
     * it is exact, not conservative (heights agree at joins), so such a chunk
     * could only ever hit the runtime's stack-overflow guard, and bounding the
     * height keeps this pass's own arithmetic in range.
     *
     * Unreachable code is not verified — it cannot execute. Pass 1 already
     * pinned every opcode and operand in bounds, so the decode below is a
     * re-walk of validated bytes. */
    int *height = NULL, *work = NULL;
    if (ok) {
        height = malloc((size_t)n * sizeof(int));
        work   = malloc((size_t)n * sizeof(int));
        if (!height || !work) ok = 0;
    }
    if (ok) {
        for (int k = 0; k < n; k++) height[k] = -1;
        int wn = 0;
        height[0] = 0;
        work[wn++] = 0;
        /* dst is an instruction start (pass 2 for jump targets, the decode
         * stride for fall-through); h is its height on this edge. Each offset
         * enters the worklist at most once — when it first gets a height — so
         * wn stays under n. */
        #define VISIT(dst, hh) do { \
            int _d = (dst), _h = (hh); \
            if (_d < 0 || _d >= n || !is_start[_d] || _h < 0 || _h > VM_STACK_MAX) { \
                WHY("bad edge to offset %d at height %d", _d, _h); ok = 0; \
            } else if (height[_d] < 0) { \
                height[_d] = _h; work[wn++] = _d; \
            } else if (height[_d] != _h) { \
                WHY("stack height %d != %d where paths join at offset %d", \
                    _h, height[_d], _d); \
                ok = 0; \
            } \
        } while (0)
        while (wn > 0 && ok) {
            int off = work[--wn];
            int h = height[off];
            uint8_t op = code[off];
            int end, operand0 = 0, target = -1;
            if (op == OP_LINE) {
                end = off + 1 + 4;
            } else {
                VerifyRole roles[3];
                int nops = op_verify_operands(op, roles);
                end = off + 1 + 2 * nops;
                if (nops > 0) operand0 = code[off + 1] | (code[off + 2] << 8);
                for (int k = 0; k < nops; k++) {
                    int pos = off + 1 + 2 * k;
                    int operand = code[pos] | (code[pos + 1] << 8);
                    if (roles[k] == VR_JFWD)       target = end + operand;
                    else if (roles[k] == VR_JBACK) target = end - operand;
                }
            }
            StackEffect e = op_verify_stack_effect(op, operand0);
            if (h < e.need) {   /* underflow — the whole point */
                WHY("opcode %d at offset %d needs %d operand(s), stack height %d",
                    (int)op, off, e.need, h);
                ok = 0; break;
            }
            int left = h - e.pops;   /* need >= pops, so this stays >= 0 */
            switch (e.flow) {
            case FL_NEXT:   VISIT(end, left + e.pushes); break;
            case FL_BRANCH: VISIT(end, left + e.pushes);
                            if (ok) VISIT(target, left + e.bpushes);
                            break;
            case FL_JUMP:   VISIT(target, left + e.bpushes); break;
            case FL_END:    break;
            }
        }
        #undef VISIT
    }
    free(height);
    free(work);

    free(is_start);
    free(targets);
    return ok;
    #undef WHY
}

int chunk_verify(EigsChunk *chunk) {
    return chunk_verify_impl(chunk, NULL, 0);
}

/* Self-check gate (EIGS_VERIFY_SELF=1): hold the C compiler's OWN output to the
 * untrusted-chunk verifier, over whatever the process compiles. Pass 4's
 * stack-effect table has to mirror ~90 handlers in vm.c, and the failure mode of
 * a table that drifts is silent: too strict rejects legitimate bytecode from the
 * self-hosting compiler in `ouroboros`, too lax reopens the underflow. Compiler
 * output is the one bytecode corpus we can generate by the thousand — so
 * run_all_tests.sh exports EIGS_VERIFY_SELF=1 for the whole suite (every .eigs
 * it already runs becomes a sample, for one O(code_len) walk per compile), and
 * an opcode whose row is wrong fails at the first program that emits it, naming
 * the chunk and the offset. Exits rather than returning a verdict: this is a
 * build-time assertion, not a runtime path. Recurses into nested function
 * chunks — each is entered at height 0 (CASE(CALL) pops args and callee before
 * pushing the frame), exactly as verified here. */
void chunk_verify_self_check(EigsChunk *chunk, const char *unit) {
    if (!chunk) return;
    char why[192] = "";
    if (!chunk_verify_impl(chunk, why, sizeof why)) {
        fprintf(stderr,
                "EIGS_VERIFY_SELF: compiler output failed chunk_verify\n"
                "  unit:  %s\n  chunk: %s\n  why:   %s\n",
                unit ? unit : "?", chunk->name ? chunk->name : "?", why);
        exit(70);
    }
    for (int f = 0; f < chunk->fn_count; f++)
        chunk_verify_self_check(chunk->functions[f], unit);
}

/* #831: descriptor-assembled chunks bypass the compiler's source scan — the
 * only thing that turns history recording on (g_trace_hist) and arms the
 * queried names — so an assembled chunk's own `prev of` / `at` reads answered
 * null unless the HOST program's text happened to contain a temporal query,
 * a relationship no bytecode producer can reason about. This walk is the
 * assembler's twin of that scan: it steps the code stream (chunk_verify has
 * already pinned every opcode and operand in bounds — call this only on a
 * verified chunk) and arms exactly what compiling the same program would:
 *   OP_INTERROGATE_NAMED, kind 6 (`prev`)  -> arm that name
 *   OP_INTERROGATE_NAMED_AT, any kind      -> arm that name; the observer
 *     kinds (3-5: where/why/how) also need observer-state capture
 *   OP_INTERROGATE_NAMED_WHEN, any kind    -> arm that name AND its occurrence
 *     ring (#868); same observer-kind rule
 *   OP_GET_NAME of "state_at"              -> wildcard (queries every name)
 * Pay-for-what-you-use: a chunk with no temporal opcode arms nothing, so
 * temporal-free vm_run_bytecode users keep recording off. */
void chunk_arm_temporal(const EigsChunk *chunk) {
    const uint8_t *code = chunk->code;
    int n = chunk->code_len, i = 0;
    while (i < n) {
        uint8_t op = code[i];
        if (op == OP_LINE) { i += 1 + 4; continue; }
        VerifyRole roles[3];
        int nops = op_verify_operands(op, roles);
        if (op == OP_INTERROGATE_NAMED || op == OP_INTERROGATE_NAMED_AT ||
            op == OP_INTERROGATE_NAMED_WHEN) {
            int kind = code[i + 1] | (code[i + 2] << 8);
            int name_idx = code[i + 3] | (code[i + 4] << 8);
            /* VR_NAME (verified) guarantees a string constant. */
            if (op == OP_INTERROGATE_NAMED_AT || op == OP_INTERROGATE_NAMED_WHEN ||
                kind == 6) {
                const char *nm = chunk->constants[name_idx]->data.str;
                if (op == OP_INTERROGATE_NAMED_WHEN) trace_arm_occurrences_name(nm);
                else                                 trace_arm_history_name(nm);
                if (op != OP_INTERROGATE_NAMED && kind >= 3 && kind <= 5)
                    g_trace_obs_hist = 1;
            }
        } else if (op == OP_GET_NAME) {
            int name_idx = code[i + 1] | (code[i + 2] << 8);
            if (strcmp(chunk->constants[name_idx]->data.str, "state_at") == 0)
                trace_arm_history_all();
        }
        i += 1 + 2 * nops;
    }
    for (int f = 0; f < chunk->fn_count; f++)
        chunk_arm_temporal(chunk->functions[f]);
}

/* ---- #366: leaf-accessor scan ----
 *
 * Marks a function chunk whose body is one pure expression over its own
 * params — field gets (LOCAL_DOT_GET), list/buffer index gets, numeric
 * arithmetic, numeric constants — ending in RETURN. Such chunks qualify
 * for the frameless call fast path in vm.c (vm_leaf_accessor_exec):
 * no env take/rebind/park, no frame push, no chunk refcount traffic.
 *
 * The whitelist is deliberately side-effect-free: no SET ops, no calls,
 * no jumps, no observer/temporal ops. Anything else rejects the chunk,
 * so the fast path can bail at any point without unwinding. Static
 * stack depth is tracked so the runtime mini-stack is provably bounded.
 */
#define LEAF_ACCESSOR_MAX_CODE  128
#define LEAF_ACCESSOR_MAX_DEPTH 8

void chunk_scan_leaf_accessor(EigsChunk *c) {
    c->leaf_accessor = 0;
    if (c->param_count > LEAF_ACCESSOR_MAX_DEPTH) return;
    if (c->first_default < c->param_count) return;   /* defaulted params */
    if (c->code_len > LEAF_ACCESSOR_MAX_CODE) return;
    int depth = 0;
    const uint8_t *ip = c->code, *end = c->code + c->code_len;
    while (ip < end) {
        uint8_t op = *ip++;
        switch (op) {
        case OP_LINE:
            if (ip + 4 > end) return;   /* #630: 32-bit operand */
            ip += 4;
            break;
        case OP_CONST: {
            if (ip + 2 > end) return;
            uint16_t idx = (uint16_t)(ip[0] | (ip[1] << 8)); ip += 2;
            if (idx >= (uint16_t)c->const_count) return;
            if (c->constants[idx]->type != VAL_NUM) return;
            depth++;
            break;
        }
        case OP_NUM_ZERO:
        case OP_NUM_ONE:
            depth++;
            break;
        case OP_GET_LOCAL: {
            if (ip + 2 > end) return;
            uint16_t slot = (uint16_t)(ip[0] | (ip[1] << 8)); ip += 2;
            if (slot >= (uint16_t)c->param_count) return;
            depth++;
            break;
        }
        case OP_LOCAL_DOT_GET: {
            if (ip + 4 > end) return;
            uint16_t slot = (uint16_t)(ip[0] | (ip[1] << 8));
            uint16_t name_idx = (uint16_t)(ip[2] | (ip[3] << 8));
            ip += 4;
            if (slot >= (uint16_t)c->param_count) return;
            if (name_idx >= (uint16_t)c->const_count) return;
            if (!c->const_interns[name_idx]) return;
            depth++;
            break;
        }
        case OP_INDEX_GET:
        case OP_ADD:
        case OP_SUB:
        case OP_MUL:
            if (depth < 2) return;
            depth--;
            break;
        case OP_RETURN:
            /* First RETURN ends execution (no branches in the whitelist,
             * so it is always reached with the single result on top). */
            if (depth != 1) return;
            c->leaf_accessor = 1;
            return;
        default:
            return;
        }
        if (depth > LEAF_ACCESSOR_MAX_DEPTH) return;
    }
}

/* ---- #915: does this chunk READ observer state? ------------------------
 *
 * The observer computes the entropy of every assigned value, walking the whole
 * reachable container graph. On a consumer that never interrogates a binding
 * that is 88% of wall time (#915: 8.50x ceiling on EigenMiniSat 4x4). The gate
 * skips that bookkeeping for programs nothing can ever ask.
 *
 * The whole risk is SILENT-WRONG: a program that DOES reach the observer, but
 * is classified here as one that does not, still runs and still prints — with a
 * dead observer channel and no crash, leak, or failing assert to show for it.
 * So this scan is built to be conservative in one direction only. Every unclear
 * case must answer 1 ("observes"), never 0.
 *
 * WHY THE BYTECODE AND NOT THE AST. The obvious implementation is an AST walker
 * like cond_is_observer_based / scan_dispatch_rebind. Those switch over ~30 node
 * kinds, and a kind the switch forgets falls to the default — which for this
 * question means "does not observe", the silent-wrong answer. Bytecode is the
 * ground truth of what will actually execute: a new AST node that compiles down
 * to a reader opcode is caught here with no change to this function. The
 * instruction walk is driven off op_verify_operands, the SAME operand-layout
 * table the verifier and disassembler use — per #737, which was opened because a
 * hand-written second copy of that table had drifted on 15 opcodes.
 *
 * Two populations are checked:
 *   1. Reader OPCODES — the direct forms (`report of x`, a bare predicate,
 *      `trajectory of x`, `where is x`, an observer-conditioned loop).
 *   2. Reader BUILTIN NAMES in the constant pool — the indirect forms. These
 *      are ordinary bindings, so `local r is report` then `r of x` compiles to
 *      GET_NAME "report" + CALL and emits no reader opcode at all. Matching the
 *      name catches the alias. It also matches an unrelated string that merely
 *      spells "report", which costs a program its gate and is the safe way to
 *      be wrong.
 */
static int const_pool_names_observer(const EigsChunk *chunk) {
    /* Anchored to the observer-READ builtins registered in builtins.c (the
     * sandbox allowlist marks them as a group). Names only reachable as
     * builtins — the opcode forms are covered by the opcode scan above. */
    static const char *OBS_BUILTINS[] = {
        "observe", "report", "report_value", "trajectory", "classify",
        "state_at", "get_observer_thresholds", NULL
    };
    for (int i = 0; i < chunk->const_count; i++) {
        const char *s = chunk->const_interns ? chunk->const_interns[i] : NULL;
        if (!s) continue;
        for (int k = 0; OBS_BUILTINS[k]; k++)
            if (strcmp(s, OBS_BUILTINS[k]) == 0) return 1;
    }
    return 0;
}

int chunk_reads_observer(const EigsChunk *chunk) {
    if (!chunk) return 1;            /* unknown -> observe */
    /* #830's flag: a chunk assembled from a descriptor (vm_run_bytecode /
     * sandbox_run) never went through the compiler, so nothing scanned it and
     * its opcode stream is caller-supplied. Do not gate it. */
    if (!chunk->compiler_scanned) return 1;

    int i = 0;
    while (i < chunk->code_len) {
        uint8_t op = chunk->code[i];
        switch ((OpCode)op) {
            /* Direct interrogation forms. */
            case OP_INTERROGATE:
            case OP_INTERROGATE_NAMED:
            case OP_INTERROGATE_NAMED_AT:
            case OP_INTERROGATE_NAMED_WHEN:
            case OP_PREDICATE:
            case OP_PREDICATE_SLOT:
            case OP_PREDICATE_NAME:
            case OP_REPORT_SLOT:
            case OP_REPORT_NAME:
            case OP_REPORT_VALUE_SLOT:
            case OP_REPORT_VALUE_NAME:
            case OP_TRAJECTORY_SLOT:
            case OP_TRAJECTORY_NAME:
            case OP_OBSERVE_VALUE_SLOT:
            case OP_OBSERVE_VALUE_NAME:
            /* An observer-conditioned loop consults the slot to decide halting
             * (cond_is_observer_based, compiler.c). A plain loop emits
             * OP_LOOP_CAP_CHECK instead and does not read the observer. */
            case OP_LOOP_STALL_CHECK:
                return 1;
            default: break;
        }
        i++;
        if (op == OP_LINE) {
            i += 4;                          /* #630: 32-bit operand */
        } else if (op < OP_COUNT) {
            VerifyRole roles[3];
            i += 2 * op_verify_operands(op, roles);
        }
    }
    if (const_pool_names_observer(chunk)) return 1;
    for (int f = 0; f < chunk->fn_count; f++)
        if (chunk_reads_observer(chunk->functions[f])) return 1;
    return 0;
}
