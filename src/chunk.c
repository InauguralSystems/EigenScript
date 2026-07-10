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

int chunk_add_constant(EigsChunk *chunk, Value *val) {
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
            if (const_equal(val, chunk->constants[idx]))
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
        [OP_LOOP_ENV_CLEAR] = "LOOP_ENV_CLEAR",
        [OP_PREDICATE_SLOT] = "PREDICATE_SLOT",
        [OP_PREDICATE_NAME] = "PREDICATE_NAME",
        [OP_REPORT_VALUE_SLOT] = "REPORT_VALUE_SLOT",
        [OP_REPORT_VALUE_NAME] = "REPORT_VALUE_NAME",
        [OP_TRAJECTORY_SLOT] = "TRAJECTORY_SLOT",
        [OP_TRAJECTORY_NAME] = "TRAJECTORY_NAME",
        [OP_BREAK] = "BREAK", [OP_CONTINUE] = "CONTINUE",
        [OP_TRY_BEGIN] = "TRY_BEGIN", [OP_TRY_END] = "TRY_END",
        [OP_OBSERVE_ASSIGN] = "OBSERVE_ASSIGN",
        [OP_OBSERVE_ASSIGN_LOCAL] = "OBSERVE_ASSIGN_LOCAL",
        [OP_OBSERVE_NAME_POST] = "OBSERVE_NAME_POST",
        [OP_INTERROGATE] = "INTERROGATE", [OP_PREDICATE] = "PREDICATE",
        [OP_UNOBSERVED_BEGIN] = "UNOBSERVED_BEGIN",
        [OP_UNOBSERVED_END] = "UNOBSERVED_END",
        [OP_LOOP_STALL_CHECK] = "LOOP_STALL_CHECK",
        [OP_LOOP_CAP_CHECK] = "LOOP_CAP_CHECK",
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
        [OP_DEFAULT_PARAM] = "DEFAULT_PARAM",
        [OP_DESTRUCTURE_UNPACK] = "DESTRUCTURE_UNPACK",
        [OP_SLICE_GET] = "SLICE_GET",
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
    case OP_TRY_BEGIN: case OP_LOOP_STALL_CHECK: case OP_LOOP_CAP_CHECK:
    case OP_OBSERVE_ASSIGN: case OP_OBSERVE_ASSIGN_LOCAL:
    case OP_IMPORT: case OP_MATCH:
    case OP_LINE:
    case OP_REPORT_VALUE_SLOT: case OP_REPORT_VALUE_NAME:
    case OP_TRAJECTORY_SLOT: case OP_TRAJECTORY_NAME:
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
 * every jump target lands on an instruction boundary inside code. NOT checked:
 * local/observer slot operands — the VM already guards every slot access
 * (slot < env->count; observer slots auto-grow), so they cannot fault. */
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

/* Fill roles[] for op; return its operand count (0..3). Mirrors the operand
 * layout the VM decodes in vm.c — keep in lockstep if an opcode changes. */
static int op_verify_operands(uint8_t op, VerifyRole roles[3]) {
    switch (op) {
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
    case OP_INTERROGATE: case OP_PREDICATE:
    case OP_MATCH: case OP_LINE: case OP_DESTRUCTURE_UNPACK:
        roles[0] = VR_RAW; return 1;
    case OP_LOCAL_DOT_GET: case OP_LOCAL_DOT_SET:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;    /* slot, name */
    case OP_LOCAL_IDX_GET:
        roles[0] = VR_RAW; roles[1] = VR_RAW; return 2;     /* slot, list idx */
    case OP_INTERROGATE_NAMED: case OP_INTERROGATE_NAMED_AT:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;    /* kind, name */
    case OP_PREDICATE_SLOT:
        roles[0] = VR_RAW; roles[1] = VR_RAW; return 2;     /* kind, slot (runtime-guarded) */
    case OP_PREDICATE_NAME:
        roles[0] = VR_RAW; roles[1] = VR_NAME; return 2;    /* kind, name */
    case OP_DEFAULT_PARAM:
        roles[0] = VR_RAW; roles[1] = VR_JFWD; return 2;    /* slot, skip */
    case OP_LOCAL_IDX_DOT_GET: case OP_LOCAL_IDX_DOT_SET:
        roles[0] = VR_RAW; roles[1] = VR_RAW; roles[2] = VR_NAME; return 3;
    default:
        return 0;   /* no operand */
    }
}

int chunk_verify(EigsChunk *chunk) {
    if (!chunk || chunk->code_len <= 0) return 0;
    int n = chunk->code_len;
    const uint8_t *code = chunk->code;
    unsigned char *is_start = calloc((size_t)n + 1, 1);
    int *targets = malloc((size_t)n * sizeof(int));
    if (!is_start || !targets) { free(is_start); free(targets); return 0; }
    int ntargets = 0, ok = 1, i = 0;

    /* Pass 1: validate opcodes/operands/pool indices; mark instruction starts;
     * stash jump targets (validated in pass 2 once is_start[] is complete). */
    while (i < n) {
        uint8_t op = code[i];
        if (op >= OP_COUNT) { ok = 0; break; }
        is_start[i] = 1;
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

    free(is_start);
    free(targets);
    return ok;
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
            if (ip + 2 > end) return;
            ip += 2;
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
