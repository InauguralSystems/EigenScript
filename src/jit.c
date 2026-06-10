#include "jit.h"
#include "eigenscript.h"
#include "vm.h"

#include <inttypes.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

struct EigsJitCache {
    uint8_t *base;
    size_t   capacity;
    size_t   used;
    int      sealed;
};

EigsJitCache *jit_cache_new(size_t page_count) {
    if (page_count == 0) page_count = 1;
    long ps = sysconf(_SC_PAGESIZE);
    if (ps <= 0) ps = 4096;
    size_t cap = page_count * (size_t)ps;
    void *p = mmap(NULL, cap, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) return NULL;
    EigsJitCache *jc = calloc(1, sizeof *jc);
    if (!jc) {
        munmap(p, cap);
        return NULL;
    }
    jc->base = (uint8_t *)p;
    jc->capacity = cap;
    return jc;
}

void jit_cache_free(EigsJitCache *jc) {
    if (!jc) return;
    if (jc->base) munmap(jc->base, jc->capacity);
    free(jc);
}

void *jit_cache_alloc(EigsJitCache *jc, size_t bytes) {
    if (!jc || jc->sealed) return NULL;
    if (jc->used + bytes > jc->capacity) return NULL;
    void *p = jc->base + jc->used;
    jc->used += bytes;
    return p;
}

int jit_cache_seal(EigsJitCache *jc) {
    if (!jc) return -1;
    if (jc->sealed) return 0;
    if (mprotect(jc->base, jc->capacity, PROT_READ | PROT_EXEC) != 0) return -1;
    __builtin___clear_cache((char *)jc->base, (char *)jc->base + jc->capacity);
    jc->sealed = 1;
    return 0;
}

int jit_cache_unseal(EigsJitCache *jc) {
    if (!jc) return -1;
    if (!jc->sealed) return 0;
    if (mprotect(jc->base, jc->capacity, PROT_READ | PROT_WRITE) != 0) return -1;
    jc->sealed = 0;
    return 0;
}

size_t jit_cache_used(const EigsJitCache *jc) {
    return jc ? jc->used : 0;
}

/* x86-64 SysV: int64 return goes in %rax.
 *
 *   48 B8 <imm64>   movabs $imm64, %rax
 *   C3              ret
 *
 * 11 bytes total. */
JitConstFn jit_emit_const_return(EigsJitCache *jc, int64_t value) {
#if defined(__x86_64__)
    uint8_t *code = jit_cache_alloc(jc, 11);
    if (!code) return NULL;
    code[0] = 0x48;
    code[1] = 0xB8;
    memcpy(&code[2], &value, 8);
    code[10] = 0xC3;
    return (JitConstFn)(void *)code;
#else
    (void)jc;
    (void)value;
    return NULL;
#endif
}

/* ---- In-VM integration ---- */

/* Per-thread cache so each interpreter thread compiles into its own
 * pages. Lazily initialized on first compile attempt. */
static __thread EigsJitCache *g_jit_cache = NULL;
static __thread int g_jit_compiled_chunks = 0;
static __thread int g_jit_scanned_chunks = 0;

/* Stop-opcode histogram. Indexed by OP code (0..OP_COUNT-1) plus an
 * extra OP_COUNT slot used for "ran off the end" — those chunks fit
 * the supported set entirely but were short. Counter rules in
 * jit_try_compile_chunk: every bail bumps g_jit_stop_counts[stop_op];
 * if prefix==0 we also bump g_jit_stop_at_zero. Compiled chunks bump
 * g_jit_compiled_count and ALSO record their trailing stop_op (the op
 * that would unlock further extension). */
static __thread uint32_t g_jit_stop_counts[256];
static __thread uint32_t g_jit_stop_at_zero = 0;
static __thread uint32_t g_jit_compiled_count = 0;

/* Per-thread chunk registry for the EIGS_JIT_HOT dump. Chunks self-
 * register via jit_register_chunk on first JIT visit (CALL paths) and
 * on top-level entry (vm_run). Idempotent via a linear scan — only
 * called once per chunk lifetime so the O(n²) registration is fine. */
static __thread struct EigsChunk **g_chunks = NULL;
static __thread int g_chunks_count = 0;
static __thread int g_chunks_cap = 0;

void jit_register_chunk(struct EigsChunk *chunk) {
    if (!chunk) return;
    for (int i = 0; i < g_chunks_count; i++) {
        if (g_chunks[i] == chunk) return;
    }
    if (g_chunks_count == g_chunks_cap) {
        int new_cap = g_chunks_cap ? g_chunks_cap * 2 : 64;
        struct EigsChunk **p = realloc(g_chunks, new_cap * sizeof(*p));
        if (!p) return;
        g_chunks = p;
        g_chunks_cap = new_cap;
    }
    g_chunks[g_chunks_count++] = chunk;
}

/* Called from chunk_decref when a chunk dies, so the hotness registry
 * (and its EIGS_JIT_HOT shutdown dump) never dereferences a freed chunk.
 * The registry is thread-local; a chunk registered on one thread and
 * freed on another stays in the registering thread's array — that only
 * matters for the debug dump, and only main's registry is dumped. */
void jit_unregister_chunk(struct EigsChunk *chunk) {
    if (!chunk) return;
    for (int i = 0; i < g_chunks_count; i++) {
        if (g_chunks[i] == chunk) {
            g_chunks[i] = g_chunks[--g_chunks_count];
            return;
        }
    }
}

void jit_module_init(void) {
    /* Defer cache creation until the first compile request. */
}

__attribute__((constructor))
static void jit_register_atexit(void) {
    atexit(jit_module_shutdown);
}

void jit_module_shutdown(void) {
    if (getenv("EIGS_JIT_STATS")) {
        fprintf(stderr, "[jit] scanned=%d compiled=%d cache_used=%zu\n",
                g_jit_scanned_chunks, g_jit_compiled_chunks,
                g_jit_cache ? jit_cache_used(g_jit_cache) : 0);
    }
    if (getenv("EIGS_JIT_STOPS")) {
        uint32_t total_stops = 0;
        for (int i = 0; i < 256; i++) total_stops += g_jit_stop_counts[i];
        fprintf(stderr, "=== JIT compile stops ===\n");
        fprintf(stderr, "compiled:        %u\n", g_jit_compiled_count);
        fprintf(stderr, "total bailouts:  %u\n",
                total_stops - g_jit_compiled_count);
        fprintf(stderr, "  stop_at_zero:  %u\n", g_jit_stop_at_zero);
        /* Split: terminators (RETURN/RETURN_NULL/<end>) are scanner
         * successes — the chunk fit. Bailouts are real blockers — the
         * next opcode to chain to widen native coverage. % for bailouts
         * is computed against bailout total, not total_stops, so the
         * relative magnitudes are decision-grade. */
        uint32_t bailout_total =
            total_stops - g_jit_stop_counts[OP_RETURN]
                        - g_jit_stop_counts[OP_RETURN_NULL]
                        - g_jit_stop_counts[OP_COUNT];
        fprintf(stderr, "\nstop opcode histogram (terminators):\n");
        for (int op = 0; op < 256; op++) {
            int is_term = (op == OP_RETURN || op == OP_RETURN_NULL ||
                           op == OP_COUNT);
            if (!is_term || !g_jit_stop_counts[op]) continue;
            uint32_t c = g_jit_stop_counts[op];
            double pct = total_stops ? (100.0 * c / total_stops) : 0.0;
            const char *name = (op == OP_COUNT) ? "OP_<end-of-chunk>"
                                                : op_name((uint8_t)op);
            fprintf(stderr, "  %6u  %-22s (%.1f%%)\n", c, name, pct);
        }
        fprintf(stderr, "\nstop opcode histogram (bailouts, %% of %u):\n",
                bailout_total);
        /* Selection sort by count, descending. ~256 entries, one-shot. */
        int order[256];
        int order_n = 0;
        for (int i = 0; i < 256; i++) {
            int is_term = (i == OP_RETURN || i == OP_RETURN_NULL ||
                           i == OP_COUNT);
            if (!is_term && g_jit_stop_counts[i]) order[order_n++] = i;
        }
        for (int a = 0; a < order_n; a++) {
            int best = a;
            for (int b = a + 1; b < order_n; b++) {
                if (g_jit_stop_counts[order[b]] >
                    g_jit_stop_counts[order[best]]) best = b;
            }
            int tmp = order[a]; order[a] = order[best]; order[best] = tmp;
        }
        for (int a = 0; a < order_n; a++) {
            int op = order[a];
            uint32_t c = g_jit_stop_counts[op];
            double pct = bailout_total ? (100.0 * c / bailout_total) : 0.0;
            fprintf(stderr, "  %6u  %-22s (%.1f%%)\n",
                    c, op_name((uint8_t)op), pct);
        }
    }
    if (getenv("EIGS_JIT_HOT") && g_chunks_count > 0) {
        /* Selection sort top-N by exec_count. Small registry (~80 on
         * DMG), one-shot at exit, no need for a real sort. */
        int top = g_chunks_count < 30 ? g_chunks_count : 30;
        int *order = malloc(g_chunks_count * sizeof(int));
        if (order) {
            for (int i = 0; i < g_chunks_count; i++) order[i] = i;
            for (int a = 0; a < top; a++) {
                int best = a;
                for (int b = a + 1; b < g_chunks_count; b++) {
                    if (g_chunks[order[b]]->exec_count >
                        g_chunks[order[best]]->exec_count) best = b;
                }
                int tmp = order[a]; order[a] = order[best]; order[best] = tmp;
            }
            uint64_t total_exec = 0;
            for (int i = 0; i < g_chunks_count; i++)
                total_exec += g_chunks[i]->exec_count;
            /* Static native-byte coverage diagnostic: each chunk entry
             * executes some prefix of its bytecode natively (if compiled)
             * and the remainder interpreted. Aggregating exec_count *
             * jit_advance vs exec_count * code_len tells us roughly what
             * fraction of executed bytecode bytes are native — and thus
             * whether extending the JIT prefix further would still pay. */
            uint64_t bytes_native = 0, bytes_total = 0;
            uint64_t bytes_native_top = 0, bytes_total_top = 0;
            fprintf(stderr, "\n=== Hot chunks (top %d of %d) ===\n",
                    top, g_chunks_count);
            fprintf(stderr, "total chunk entries: %" PRIu64 "\n", total_exec);
            fprintf(stderr,
                "%-28s %12s  %3s  %6s  %5s %5s %6s  %4s  %3s %5s %5s  %s\n",
                "chunk", "exec", "jit", "pct", "adv", "len", "nat%", "bked",
                "osr", "oadv", "oent", "stop");
            /* jit_advance == -1 is the Stage 4s OP_RETURN sentinel: the
             * thunk executed a full return, so coverage is "all of the
             * reachable straight-line code from byte 0" — treat it as
             * full-len for both display and aggregate purposes. Without
             * this normalization a -1 reads as a negative percentage in
             * the per-chunk row AND drags the aggregate share down by
             * exec_count bytes per RETURN-terminated hit. */
            #define JIT_EFFECTIVE_ADV(c) \
                ((c)->jit_state == 2 \
                    ? ((c)->jit_advance == -1 ? (c)->code_len : (c)->jit_advance) \
                    : 0)
            #define JIT_OSR_EFFECTIVE_ADV(c) \
                ((c)->jit_osr_state == 2 \
                    ? ((c)->jit_osr_advance == -1 ? (c)->code_len : (c)->jit_osr_advance) \
                    : 0)
            for (int a = 0; a < top; a++) {
                struct EigsChunk *c = g_chunks[order[a]];
                if (c->exec_count == 0) break;
                const char *jstate =
                    c->jit_state == 2 ? "yes" :
                    c->jit_state == 1 ? "no " : "?  ";
                const char *ostate =
                    c->jit_osr_state == 2 ? "yes" :
                    c->jit_osr_state == 1 ? "no " : "?  ";
                double pct = total_exec
                    ? (100.0 * (double)c->exec_count / (double)total_exec)
                    : 0.0;
                int adv  = JIT_EFFECTIVE_ADV(c);
                int oadv = JIT_OSR_EFFECTIVE_ADV(c);
                int oent = (c->jit_osr_state != 0) ? c->jit_osr_entry_offset : 0;
                int len = c->code_len;
                double nat = len ? (100.0 * (double)adv / (double)len) : 0.0;
                const char *stop_name = (c->jit_stop_op == OP_COUNT)
                    ? "<end>" : op_name(c->jit_stop_op);
                /* Display the raw jit_advance with a 'R' tag when it's
                 * the RETURN sentinel, so the reader can distinguish
                 * "compiled to end of straight-line" from "compiled
                 * through a full return". */
                char adv_buf[16];
                if (c->jit_state == 2 && c->jit_advance == -1)
                    snprintf(adv_buf, sizeof adv_buf, "RET");
                else
                    snprintf(adv_buf, sizeof adv_buf, "%d", adv);
                fprintf(stderr,
                        "%-28s %12" PRIu64 "  %s  %5.1f%%  %5s %5d %5.1f%%  %4u  %s %5d %5d  %s\n",
                        c->name ? c->name : "<anon>",
                        c->exec_count, jstate, pct, adv_buf, len, nat,
                        c->back_edge_count, ostate, oadv, oent, stop_name);
                bytes_native_top += c->exec_count * (uint64_t)adv;
                bytes_total_top  += c->exec_count * (uint64_t)len;
            }
            for (int i = 0; i < g_chunks_count; i++) {
                struct EigsChunk *c = g_chunks[i];
                int adv = JIT_EFFECTIVE_ADV(c);
                bytes_native += c->exec_count * (uint64_t)adv;
                bytes_total  += c->exec_count * (uint64_t)c->code_len;
            }
            #undef JIT_EFFECTIVE_ADV
            #undef JIT_OSR_EFFECTIVE_ADV
            double nat_share_top = bytes_total_top
                ? 100.0 * (double)bytes_native_top / (double)bytes_total_top
                : 0.0;
            double nat_share_all = bytes_total
                ? 100.0 * (double)bytes_native / (double)bytes_total
                : 0.0;
            fprintf(stderr,
                "native-byte share (top %d hot): %.1f%%   "
                "(all %d chunks): %.1f%%\n",
                top, nat_share_top, g_chunks_count, nat_share_all);
            fprintf(stderr,
                "  bytes native: %" PRIu64 " / total: %" PRIu64 "\n",
                bytes_native, bytes_total);
            free(order);
        }
    }
    if (g_jit_cache) {
        jit_cache_free(g_jit_cache);
        g_jit_cache = NULL;
    }
}

#if defined(__x86_64__)
/* Stage 3b: layout descriptor captured once via the vm.c-owned probe. */
static int g_layout_inited = 0;
static EigsJitLayout g_layout;

static void ensure_layout(void) {
    if (g_layout_inited) return;
    eigs_jit_get_layout(&g_layout);
    g_layout_inited = 1;
}

/* Scan a chunk-start prefix of opcodes we can natively translate.
 * Returns prefix length in *bytes* (0 = nothing compilable). Sets
 * *needs_env_cache when the prefix touches fn_env->values[]; sets
 * *has_bail_op when the prefix contains an op that can bail at runtime
 * (currently OP_ADD / OP_SUB on non-num or overflowing operands). The
 * emitter uses these to size the prologue and to decide whether to
 * thread an advance-tracker register.
 *
 * Stage 4 supported set:
 *   OP_NULL/NUM_ZERO/NUM_ONE — inline immediate push.
 *   OP_LINE                  — inline 32-bit store to current_line.
 *   OP_CONST [idx:16]        — pre-encoded slot push + inline incref for
 *                              heap (skipped statically when arena==1).
 *   OP_GET_LOCAL [slot:16]   — load fn_env->values[slot]; inline
 *                              conditional incref.
 *   OP_SET_LOCAL [slot:16]   — load old, store new, conditional incref
 *                              of new, conditional decref of old (with
 *                              helper call to free_value on rc<=0).
 *   OP_DUP                   — duplicate TOS, conditional incref.
 *   OP_DUP2                  — duplicate top two slots, conditional
 *                              incref of each.
 *   OP_ADD / OP_SUB /
 *   OP_MUL / OP_DIV          — load both, type-check (immediate-num),
 *                              addsd/subsd/mulsd/divsd, NaN/overflow
 *                              check via abs-bits >|1e308|; bail on any
 *                              check fail. Div-by-zero produces ±Inf
 *                              or NaN, both caught by the overflow
 *                              check — no separate divisor guard.
 *   OP_EQ / OP_NE / OP_LT /
 *   OP_GT / OP_LE / OP_GE    — load both, type-check (immediate-num),
 *                              ucomisd + cmovcc to materialize 0.0 or
 *                              1.0 bits as the result slot. No output
 *                              overflow check needed (bounded). Type-
 *                              check is the only bail.
 *   OP_POP                   — peephole `dec %ecx`, valid only when the
 *                              most recent push was an immediate whose
 *                              slot_decref is a no-op. GET_LOCAL/DUP/
 *                              DUP2/SET_LOCAL/ADD/SUB break the chain.
 */
/* entry_offset: starting byte offset within chunk->code at which the
 * thunk will begin execution. 0 for the existing from-zero compile;
 * non-zero is the OSR entry point (Phase 2+). The returned `last_good`
 * is still an *absolute* bytecode offset (one past the last good op).
 * The "no prefix" sentinel remains a literal 0 return — callers that
 * support entry_offset > 0 must additionally check `prefix > entry_offset`. */
static int jit_supported_prefix(const struct EigsChunk *chunk,
                                int entry_offset,
                                int *needs_env_cache, int *has_bail_op,
                                uint8_t *stop_op, int *stop_offset) {
    int i = entry_offset, ops = 0, non_line_ops = 0;
    int last_good = entry_offset;
    *needs_env_cache = 0;
    *has_bail_op = 0;
    *stop_op = OP_COUNT;   /* sentinel: ran off the end with no break */
    *stop_offset = 0;
    while (i < chunk->code_len) {
        uint8_t op = chunk->code[i];
        if (op == OP_NULL || op == OP_NUM_ZERO || op == OP_NUM_ONE) {
            i += 1; ops++; non_line_ops++;
        } else if (op == OP_CONST) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t idx = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            if (idx >= chunk->const_count) { *stop_op = op; *stop_offset = i; break; }
            Value *v = chunk->constants[idx];
            if (!v) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
        } else if (op == OP_GET_LOCAL) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            *needs_env_cache = 1;
        } else if (op == OP_GET_NAME) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t idx = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            /* Helper needs chunk->env_ic and chunk->const_interns to be
             * non-NULL; the compiler always allocates env_ic when there
             * are any string constants, but guard anyway. */
            if (!chunk->env_ic || !chunk->const_interns ||
                idx >= chunk->const_count) {
                *stop_op = op; *stop_offset = i; break;
            }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result could be any slot type (whatever the binding holds).
             * Subsequent OP_POP cannot use the immediate peephole. */
        } else if (op == OP_LOCAL_IDX_GET) {
            /* 5-byte op: [op][slot:16][idx:16]. Helper handles VAL_BUFFER/
             * VAL_LIST/VAL_STR dispatch; on error it pushes null and
             * sets g_vm.had_error so the interpreter CHECK_ERROR fires
             * once execution resumes after the JIT thunk. */
            if (i + 5 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 5; ops++; non_line_ops++;
        } else if (op == OP_LOCAL_DOT_GET) {
            /* Stage 4m: 5-byte op [op][slot:16][name_idx:16]. Helper needs
             * chunk pointer for const_interns/const_hashes lookup — same
             * shape as OP_GET_NAME. */
            if (i + 5 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t name_idx = (uint16_t)(chunk->code[i + 3] |
                                           ((uint16_t)chunk->code[i + 4] << 8));
            if (!chunk->const_interns || name_idx >= chunk->const_count) {
                *stop_op = op; *stop_offset = i; break;
            }
            i += 5; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_LOCAL_IDX_DOT_GET) {
            /* Stage 4v: 7-byte op [op][slot:16][list_idx:16][name_idx:16].
             * Helper needs chunk pointer (const_interns/const_hashes) —
             * forces has_bail_op=1 so %r14=chunk is set in prologue.
             * Was 48% of DMG bailouts before chaining. */
            if (i + 7 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t name_idx = (uint16_t)(chunk->code[i + 5] |
                                           ((uint16_t)chunk->code[i + 6] << 8));
            if (!chunk->const_interns || name_idx >= chunk->const_count) {
                *stop_op = op; *stop_offset = i; break;
            }
            i += 7; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_DOT_GET) {
            /* Stage 4q-f: 3-byte op [op][name_idx:16]. Pop target, push
             * target.name — sp neutral. Helper needs chunk pointer. */
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t name_idx = (uint16_t)(chunk->code[i + 1] |
                                           ((uint16_t)chunk->code[i + 2] << 8));
            if (!chunk->const_interns || name_idx >= chunk->const_count) {
                *stop_op = op; *stop_offset = i; break;
            }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_LOCAL_DOT_SET) {
            /* Stage 4q-d: 5-byte op [op][slot:16][name_idx:16]. Mirror of
             * LOCAL_DOT_GET on the write side. Helper writes
             * local[slot].name = TOS without popping; TOS slot type is
             * unchanged from the perspective of subsequent ops (the next
             * OP_POP clears it). has_bail_op=1 for the runtime_error path
             * on non-dict target. */
            if (i + 5 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t name_idx = (uint16_t)(chunk->code[i + 3] |
                                           ((uint16_t)chunk->code[i + 4] << 8));
            if (!chunk->const_interns || name_idx >= chunk->const_count) {
                *stop_op = op; *stop_offset = i; break;
            }
            i += 5; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_SET_LOCAL) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            *needs_env_cache = 1;
        } else if (op == OP_DUP) {
            i += 1; ops++; non_line_ops++;
        } else if (op == OP_DUP2) {
            i += 1; ops++; non_line_ops++;
        } else if (op == OP_ADD || op == OP_SUB ||
                   op == OP_MUL || op == OP_DIV ||
                   op == OP_MOD) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result type at runtime is num (when not bailed), so
             * subsequent OP_POP is still a no-op-decref. */
        } else if (op == OP_EQ || op == OP_NE || op == OP_LT ||
                   op == OP_GT || op == OP_LE || op == OP_GE) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result is bit-exact 0.0 or 1.0 (an immediate-num), so
             * OP_POP after a comparison remains a no-op peephole. */
        } else if (op == OP_BAND || op == OP_BOR || op == OP_BXOR ||
                   op == OP_SHL || op == OP_SHR) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result is a double (whole-number-valued), so a subsequent
             * OP_POP stays a no-op peephole. */
        } else if (op == OP_NEG || op == OP_NOT || op == OP_BNOT) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_JUMP || op == OP_JUMP_BACK) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            /* Uses r13d/r14 machinery to either chain into native code at
             * the target or bail with jit_advance = target. */
            *has_bail_op = 1;
            /* Stack TOS at the jump target is whatever the predecessor
             * left — opaque to this scanner. */
        } else if (op == OP_JUMP_IF_FALSE || op == OP_JUMP_IF_TRUE) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* TOS was popped — new TOS is unknown to us. */
        } else if (op == OP_JUMP_IF_FALSE_PEEK || op == OP_JUMP_IF_TRUE_PEEK) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Type-check at runtime proved TOS is immediate-num — so a
             * subsequent OP_POP can use the peephole `dec ecx`. */
        } else if (op == OP_ITER_NEXT) {
            /* Stage 4q-a: 3-byte op [op][exit_offset:16]. Helper does the
             * iter step against g_vm.stack[sp-1] and returns 1 (exhausted)
             * or 0 (pushed an element). Emitter calls helper, tests eax,
             * conditional-jumps to the exit target on non-zero. Same
             * pending-patch / has_bail_op pattern as OP_JUMP_IF_FALSE.
             * Fall-through TOS may be a heap pointer (VAL_LIST element)
             * or an immediate num (VAL_BUFFER element) — cannot guarantee
             * immediate, so disable the OP_POP peephole. */
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_INDEX_GET) {
            /* Stage 4q-c: 1-byte op. Helper pops 2 (idx, target), pushes
             * 1 result. Can call runtime_error on out-of-range — the
             * dispatch loop's CHECK_ERROR picks it up after the thunk
             * returns. has_bail_op=1 so the per-op advance writeback runs
             * (next op resumes at i+1 if the thunk bails). Pushed value
             * type is opaque to the scanner. */
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_CALL) {
            /* Stage 4r: 3-byte op [op][argc:16]. Helper handles the
             * VAL_BUILTIN case inline; for VAL_FN / VAL_CLOSURE / non-
             * callable, the helper returns 1 without touching the stack
             * and the emitter bails via the standard pre-set %r13d =
             * op_start pattern so the interpreter re-executes the call.
             * has_bail_op=1 because we need the bail-back-to-CALL path. */
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_RETURN) {
            /* Stage 4s: 1-byte op, terminates the function. Helper does
             * the full frame teardown + result push; emitter pre-sets
             * %r13d = (uint32_t)-1 so the epilogue's writeback lands a
             * sentinel in chunk->jit_advance, which vm_run's post-thunk
             * code uses to resync frame/ip/chunk (or return result as
             * Value* when frame_count <= base_frame).
             *
             * has_bail_op=1 to enable the per-op r13d advance writeback
             * machinery (the epilogue branch on has_bail_op). We also
             * stop the scan here — bytes after RETURN are unreachable
             * within this thunk, mirroring how OP_JUMP terminates.
             *
             * Stage 4u: record stop_op = OP_RETURN before break so the
             * histogram distinguishes RETURN-terminated prefixes from
             * scanner-walked-off-end (which keeps stop_op = OP_COUNT). */
            *stop_op = op; *stop_offset = i;
            i += 1; ops++; non_line_ops++;
            last_good = i;
            *has_bail_op = 1;
            break;
        } else if (op == OP_RETURN_NULL) {
            /* Stage 4t: 1-byte op, same sentinel pattern as OP_RETURN
             * but pushes slot_null() rather than the TOS. The DMG hot
             * dump showed this as the #2 single-op blocker (16.5% of
             * stops), affecting write_r8 / cpu_mem_write / alu_xor /
             * push16 / set_hl.
             *
             * Stage 4u: same stop_op fix as OP_RETURN. */
            *stop_op = op; *stop_offset = i;
            i += 1; ops++; non_line_ops++;
            last_good = i;
            *has_bail_op = 1;
            break;
        } else if (op == OP_POP) {
            /* Always supported — emitter picks the path via its local
             * `last_imm` tracker (peephole `dec %ecx` when the prior
             * push was an immediate, else load + conditional decref).
             * Neither path bails, so no has_bail_op tax. */
            i += 1; ops++; non_line_ops++;
        } else if (op == OP_OBSERVE_ASSIGN) {
            /* Stage 4o: 3-byte op [op][name_idx:16]. Helper needs
             * chunk->const_interns (const_hashes may be NULL — helper
             * fills lazily). Forces has_bail_op=1 so %r14=chunk is set
             * in the prologue, same as OP_GET_NAME. The helper may
             * mutate stack[sp-1] (immediate-num → tracked ptr), so any
             * subsequent OP_POP cannot use the immediate peephole. */
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            uint16_t name_idx = (uint16_t)(chunk->code[i + 1] |
                                           ((uint16_t)chunk->code[i + 2] << 8));
            if (!chunk->const_interns || name_idx >= chunk->const_count) {
                *stop_op = op; *stop_offset = i; break;
            }
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
        } else if (op == OP_OBSERVE_ASSIGN_LOCAL) {
            /* Stage 4o: 3-byte op [op][slot:16]. Helper reads prior
             * value directly from frame->fn_env->values[slot] — no
             * chunk pointer needed, so no has_bail_op tax. */
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++; non_line_ops++;
        } else if (op == OP_UNOBSERVED_BEGIN || op == OP_UNOBSERVED_END) {
            /* Stage 4q-e: 1-byte ops, just inc/dec a TLS counter. Emitted
             * inline as 9-byte FS-prefixed inc/dec dword [disp32] — no
             * call, no bail, no sp/env interaction. */
            i += 1; ops++; non_line_ops++;
        } else if (op == OP_LINE) {
            if (i + 3 > chunk->code_len) { *stop_op = op; *stop_offset = i; break; }
            i += 3; ops++;
        } else {
            *stop_op = op; *stop_offset = i;
            break;
        }
        last_good = i;
    }
    if (non_line_ops == 0 || ops < 3) return 0;
    return last_good;
}

/* Upper bound on emitted bytes:
 *   prologue 23 (always) + 35 (env-cache when needs_env_cache) +
 *                          17 (advance tracker init when has_bail_op) +
 *   epilogue 10 (always) +  7 (advance writeback when has_bail_op) +
 *   192 bytes/op worst case + 7 bytes/op advance update when
 *   has_bail_op. The caller advances frame->ip by chunk->jit_advance,
 *   which is initialized at compile time to the full prefix but may be
 *   overwritten by the thunk on bail.
 *
 * The 192-byte budget covers OP_MOD (load + 2 type checks + zero-check
 * + xmm setup + push/movabs/call/pop + extract + overflow check + store
 * ≈ 150 bytes). Smaller ops use a fraction of the slack. */
static size_t jit_estimate_size(int prefix, int needs_env_cache,
                                int has_bail_op) {
    return 25 + (needs_env_cache ? 35 : 0) + (has_bail_op ? 17 : 0) +
           10 + (has_bail_op ? 11 : 0) +
           (size_t)prefix * (192 + (has_bail_op ? 6 : 0));
}

/* ---- x86-64 encoding helpers ---- */

static uint8_t *emit_u8(uint8_t *w, uint8_t b)         { *w++ = b; return w; }
static uint8_t *emit_u32(uint8_t *w, uint32_t v)       { memcpy(w, &v, 4); return w + 4; }
static uint8_t *emit_u64(uint8_t *w, uint64_t v)       { memcpy(w, &v, 8); return w + 8; }

/* mov %fs:0, %rbx  — load TLS base into %rbx (9 bytes) */
static uint8_t *emit_load_fs_zero_rbx(uint8_t *w) {
    *w++ = 0x64; *w++ = 0x48; *w++ = 0x8B;
    *w++ = 0x1C; *w++ = 0x25;
    return emit_u32(w, 0);
}

/* incl %fs:(disp32)  — atomic-safe-on-single-thread inc of TLS i32 (9 bytes).
 * Encoding: 64 (FS prefix) ff /0 04 25 disp32. */
static uint8_t *emit_incl_fs_disp32(uint8_t *w, int32_t disp) {
    *w++ = 0x64; *w++ = 0xFF; *w++ = 0x04; *w++ = 0x25;
    return emit_u32(w, (uint32_t)disp);
}

/* decl %fs:(disp32)  — symmetric to emit_incl_fs_disp32 (9 bytes).
 * Encoding: 64 ff /1 04 25 disp32. */
static uint8_t *emit_decl_fs_disp32(uint8_t *w, int32_t disp) {
    *w++ = 0x64; *w++ = 0xFF; *w++ = 0x0C; *w++ = 0x25;
    return emit_u32(w, (uint32_t)disp);
}

/* lea disp32(%rbx), %rbx  — %rbx += disp32 (7 bytes) */
static uint8_t *emit_lea_rbx_disp32_rbx(uint8_t *w, int32_t disp) {
    *w++ = 0x48; *w++ = 0x8D; *w++ = 0x9B;
    return emit_u32(w, (uint32_t)disp);
}

/* mov disp32(%rbx), %ecx  — load 32-bit (6 bytes) */
static uint8_t *emit_mov_disp32_rbx_to_ecx(uint8_t *w, int32_t disp) {
    *w++ = 0x8B; *w++ = 0x8B;
    return emit_u32(w, (uint32_t)disp);
}

/* mov %ecx, disp32(%rbx)  — store 32-bit (6 bytes) */
static uint8_t *emit_mov_ecx_to_disp32_rbx(uint8_t *w, int32_t disp) {
    *w++ = 0x89; *w++ = 0x8B;
    return emit_u32(w, (uint32_t)disp);
}

/* movabs $imm64, %rax  (10 bytes) */
static uint8_t *emit_movabs_rax(uint8_t *w, uint64_t imm) {
    *w++ = 0x48; *w++ = 0xB8;
    return emit_u64(w, imm);
}

/* mov %rax, disp32(%rbx, %rcx, 8)  — store 64-bit at stack[sp] (8 bytes) */
static uint8_t *emit_store_rax_at_stack(uint8_t *w, int32_t off_stack) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0x84; *w++ = 0xCB;
    return emit_u32(w, (uint32_t)off_stack);
}

/* movl $imm32, disp32(%rbx)  (10 bytes) */
static uint8_t *emit_movl_imm_at_disp32_rbx(uint8_t *w, int32_t disp,
                                            int32_t value) {
    *w++ = 0xC7; *w++ = 0x83;
    w = emit_u32(w, (uint32_t)disp);
    return emit_u32(w, (uint32_t)value);
}

/* inc %ecx (2 bytes) */
static uint8_t *emit_inc_ecx(uint8_t *w) { *w++ = 0xFF; *w++ = 0xC1; return w; }
/* dec %ecx (2 bytes) */
static uint8_t *emit_dec_ecx(uint8_t *w) { *w++ = 0xFF; *w++ = 0xC9; return w; }

/* movabs $imm64, %rdi  (10 bytes) */
static uint8_t *emit_movabs_rdi(uint8_t *w, uint64_t imm) {
    *w++ = 0x48; *w++ = 0xBF;
    return emit_u64(w, imm);
}

/* lock addl $1, disp32(%rdi)  — atomic refcount increment (8 bytes) */
static uint8_t *emit_lock_addl_1_disp32_rdi(uint8_t *w, int32_t disp) {
    *w++ = 0xF0; *w++ = 0x83; *w++ = 0x87;
    w = emit_u32(w, (uint32_t)disp);
    *w++ = 0x01;
    return w;
}

/* mov disp32(%rbx), %eax   — load 32-bit (6 bytes) */
static uint8_t *emit_mov_disp32_rbx_to_eax(uint8_t *w, int32_t disp) {
    *w++ = 0x8B; *w++ = 0x83;
    return emit_u32(w, (uint32_t)disp);
}

/* dec %eax (2 bytes) */
static uint8_t *emit_dec_eax(uint8_t *w) { *w++ = 0xFF; *w++ = 0xC8; return w; }

/* imul $imm32, %rax, %rax  (7 bytes) */
static uint8_t *emit_imul_imm32_rax(uint8_t *w, int32_t imm) {
    *w++ = 0x48; *w++ = 0x69; *w++ = 0xC0;
    return emit_u32(w, (uint32_t)imm);
}

/* lea disp32(%rbx, %rax, 1), %r12   — &g_vm.frames[fc-1] (8 bytes) */
static uint8_t *emit_lea_rbx_rax_to_r12(uint8_t *w, int32_t disp) {
    *w++ = 0x4C; *w++ = 0x8D; *w++ = 0xA4; *w++ = 0x03;
    return emit_u32(w, (uint32_t)disp);
}

/* mov disp32(%r12), %r12   — chase pointer through frame->fn_env then
 * env->values (9 bytes per chase: REX.WRB + opcode + SIB + disp32).
 * We always use disp32 since field offsets may be large. */
static uint8_t *emit_mov_disp32_r12_to_r12(uint8_t *w, int32_t disp) {
    *w++ = 0x4D; *w++ = 0x8B; *w++ = 0xA4; *w++ = 0x24;
    return emit_u32(w, (uint32_t)disp);
}

/* mov disp32(%r12), %rax   — load 8-byte slot from cached values base
 * at compile-time-known offset (9 bytes). */
static uint8_t *emit_mov_disp32_r12_to_rax(uint8_t *w, int32_t disp) {
    *w++ = 0x49; *w++ = 0x8B; *w++ = 0x84; *w++ = 0x24;
    return emit_u32(w, (uint32_t)disp);
}

/* mov %rax, %rdx  (3 bytes) */
static uint8_t *emit_mov_rax_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xC2; return w;
}
/* mov %rax, %rdi  (3 bytes) */
static uint8_t *emit_mov_rax_rdi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xC7; return w;
}
/* shr $48, %rdx  (4 bytes) */
static uint8_t *emit_shr_48_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xC1; *w++ = 0xEA; *w++ = 0x30; return w;
}
/* shl $16, %rdi  (4 bytes) */
static uint8_t *emit_shl_16_rdi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xC1; *w++ = 0xE7; *w++ = 0x10; return w;
}
/* shr $16, %rdi  (4 bytes) */
static uint8_t *emit_shr_16_rdi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xC1; *w++ = 0xEF; *w++ = 0x10; return w;
}
/* cmp $imm32, %edx  (6 bytes) */
static uint8_t *emit_cmp_imm32_edx(uint8_t *w, uint32_t imm) {
    *w++ = 0x81; *w++ = 0xFA;
    return emit_u32(w, imm);
}
/* testb $1, disp32(%rdi)  (7 bytes) */
static uint8_t *emit_testb_1_disp32_rdi(uint8_t *w, int32_t disp) {
    *w++ = 0xF6; *w++ = 0x87;
    w = emit_u32(w, (uint32_t)disp);
    *w++ = 0x01;
    return w;
}
/* jb rel8 (2 bytes); patch second byte to be (target - end_of_jb). */
static uint8_t *emit_jb_rel8(uint8_t *w, uint8_t **patch) {
    *w++ = 0x72; *patch = w; *w++ = 0x00; return w;
}
/* jnz rel8 (2 bytes) */
static uint8_t *emit_jnz_rel8(uint8_t *w, uint8_t **patch) {
    *w++ = 0x75; *patch = w; *w++ = 0x00; return w;
}
/* jg rel8 (2 bytes) — jump if signed greater (skip free_value when rc>0) */
static uint8_t *emit_jg_rel8(uint8_t *w, uint8_t **patch) {
    *w++ = 0x7F; *patch = w; *w++ = 0x00; return w;
}

/* mov disp32(%rbx, %rcx, 8), %rax  — load 8-byte slot from stack at
 * disp32+sp*8 (8 bytes). Pass disp32 = off_stack - k*8 to address
 * stack[sp-k]. */
static uint8_t *emit_load_stack_to_rax(uint8_t *w, int32_t disp) {
    *w++ = 0x48; *w++ = 0x8B; *w++ = 0x84; *w++ = 0xCB;
    return emit_u32(w, (uint32_t)disp);
}

/* mov disp32(%r12), %rsi  — load 8 bytes from values[]+slot (9 bytes) */
static uint8_t *emit_mov_disp32_r12_to_rsi(uint8_t *w, int32_t disp) {
    *w++ = 0x49; *w++ = 0x8B; *w++ = 0xB4; *w++ = 0x24;
    return emit_u32(w, (uint32_t)disp);
}

/* mov %rax, disp32(%r12)  — store 8 bytes to values[]+slot (9 bytes) */
static uint8_t *emit_mov_rax_to_disp32_r12(uint8_t *w, int32_t disp) {
    *w++ = 0x49; *w++ = 0x89; *w++ = 0x84; *w++ = 0x24;
    return emit_u32(w, (uint32_t)disp);
}

/* mov %rsi, %rdx (3 bytes) */
static uint8_t *emit_mov_rsi_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xF2; return w;
}
/* mov %rsi, %rdi (3 bytes) */
static uint8_t *emit_mov_rsi_rdi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xF7; return w;
}

/* lock subl $1, disp32(%rdi)  — atomic refcount decrement (8 bytes) */
static uint8_t *emit_lock_subl_1_disp32_rdi(uint8_t *w, int32_t disp) {
    *w++ = 0xF0; *w++ = 0x83; *w++ = 0xAF;
    w = emit_u32(w, (uint32_t)disp);
    *w++ = 0x01;
    return w;
}

/* push %rcx (1 byte) — also re-aligns %rsp from 8-mod-16 to 0-mod-16. */
static uint8_t *emit_push_rcx(uint8_t *w) { *w++ = 0x51; return w; }
/* pop %rcx (1 byte) */
static uint8_t *emit_pop_rcx(uint8_t *w) { *w++ = 0x59; return w; }
/* call *%rax (2 bytes) */
static uint8_t *emit_call_rax(uint8_t *w) { *w++ = 0xFF; *w++ = 0xD0; return w; }

/* Emit inline conditional incref of a slot held in %rax.
 *
 * Sequence (~32 bytes):
 *   mov %rax, %rdx;  shr $48, %rdx;
 *   cmp $0xFFFB, %edx;  jb .skip       // immediate (num/null/bool)
 *   mov %rax, %rdi;  shl $16, %rdi;  shr $16, %rdi   // mask payload
 *   testb $1, off_arena(%rdi);  jnz .skip            // arena-owned
 *   lock addl $1, off_refcount(%rdi)
 *  .skip:
 *
 * Returns the advanced write pointer; aborts (sets *bail=1) on rel8
 * overflow. */
static uint8_t *emit_conditional_incref_rax(uint8_t *w, int *bail) {
    w = emit_mov_rax_rdx(w);
    w = emit_shr_48_rdx(w);
    w = emit_cmp_imm32_edx(w, 0xFFFB);
    uint8_t *jb_patch;
    w = emit_jb_rel8(w, &jb_patch);
    uint8_t *jb_after = w;
    w = emit_mov_rax_rdi(w);
    w = emit_shl_16_rdi(w);
    w = emit_shr_16_rdi(w);
    w = emit_testb_1_disp32_rdi(w, (int32_t)offsetof(Value, arena));
    uint8_t *jnz_patch;
    w = emit_jnz_rel8(w, &jnz_patch);
    uint8_t *jnz_after = w;
    w = emit_lock_addl_1_disp32_rdi(w, (int32_t)offsetof(Value, refcount));
    int jb_rel = (int)(w - jb_after);
    int jnz_rel = (int)(w - jnz_after);
    if (jb_rel > 127 || jnz_rel > 127) { *bail = 1; return w; }
    *jb_patch = (uint8_t)jb_rel;
    *jnz_patch = (uint8_t)jnz_rel;
    return w;
}

/* ---- Stage 4d: SSE / bail helpers ---- */

/* push %r13 (2 bytes), pop %r13 (2 bytes). Advance tracker. */
static uint8_t *emit_push_r13(uint8_t *w)  { *w++=0x41; *w++=0x55; return w; }
static uint8_t *emit_pop_r13(uint8_t *w)   { *w++=0x41; *w++=0x5D; return w; }
/* push %r14 (2 bytes), pop %r14 (2 bytes). Chunk pointer. */
static uint8_t *emit_push_r14(uint8_t *w)  { *w++=0x41; *w++=0x56; return w; }
static uint8_t *emit_pop_r14(uint8_t *w)   { *w++=0x41; *w++=0x5E; return w; }

/* movabs $imm64, %r14  (10 bytes) — chunk pointer. */
static uint8_t *emit_movabs_r14(uint8_t *w, uint64_t imm) {
    *w++ = 0x49; *w++ = 0xBE;
    return emit_u64(w, imm);
}

/* mov %r14, %rdi  (3 bytes) — pass chunk pointer to a helper. */
static uint8_t *emit_mov_r14_rdi(uint8_t *w) {
    *w++ = 0x4C; *w++ = 0x89; *w++ = 0xF7;
    return w;
}

/* mov $imm32, %esi  (5 bytes) — pass a 32-bit immediate as 2nd helper arg. */
static uint8_t *emit_mov_imm32_esi(uint8_t *w, uint32_t imm) {
    *w++ = 0xBE;
    return emit_u32(w, imm);
}

/* mov $imm32, %edi  (5 bytes) — pass a 32-bit immediate as 1st helper arg. */
static uint8_t *emit_mov_imm32_edi(uint8_t *w, uint32_t imm) {
    *w++ = 0xBF;
    return emit_u32(w, imm);
}

/* mov $imm32, %edx  (5 bytes) — pass a 32-bit immediate as 3rd helper arg. */
static uint8_t *emit_mov_imm32_edx(uint8_t *w, uint32_t imm) {
    *w++ = 0xBA;
    return emit_u32(w, imm);
}

/* mov $imm32, %ecx  (5 bytes) — pass a 32-bit immediate as 4th helper arg.
 * Clobbers the sp cache; caller must have already synced %ecx → g_vm.sp
 * and must reload g_vm.sp → %ecx after the call returns. */
static uint8_t *emit_mov_imm32_ecx(uint8_t *w, uint32_t imm) {
    *w++ = 0xB9;
    return emit_u32(w, imm);
}

/* mov $imm32, %r13d  (6 bytes) — set advance tracker. */
static uint8_t *emit_mov_imm32_r13d(uint8_t *w, uint32_t imm) {
    *w++ = 0x41; *w++ = 0xBD;
    return emit_u32(w, imm);
}

/* mov %r13d, disp32(%r14)  (7 bytes) — write advance to chunk. */
static uint8_t *emit_mov_r13d_to_disp32_r14(uint8_t *w, int32_t disp) {
    *w++ = 0x45; *w++ = 0x89; *w++ = 0xAE;
    return emit_u32(w, (uint32_t)disp);
}

/* movabs $imm64, %rsi  (10 bytes) — generic 64-bit immediate to rsi. */
static uint8_t *emit_movabs_rsi(uint8_t *w, uint64_t imm) {
    *w++ = 0x48; *w++ = 0xBE;
    return emit_u64(w, imm);
}

/* cmp $imm32, %esi  (6 bytes) */
static uint8_t *emit_cmp_imm32_esi(uint8_t *w, uint32_t imm) {
    *w++ = 0x81; *w++ = 0xFE;
    return emit_u32(w, imm);
}

/* shr $48, %rsi  (4 bytes) */
static uint8_t *emit_shr_48_rsi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xC1; *w++ = 0xEE; *w++ = 0x30; return w;
}

/* mov %rax, %rsi  (3 bytes) */
static uint8_t *emit_mov_rax_rsi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xC6; return w;
}
/* mov %rdx, %rsi  (3 bytes) */
static uint8_t *emit_mov_rdx_rsi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xD6; return w;
}

/* mov disp32(%rbx, %rcx, 8), %rdx  (8 bytes) — load stack slot to rdx. */
static uint8_t *emit_load_stack_to_rdx(uint8_t *w, int32_t disp) {
    *w++ = 0x48; *w++ = 0x8B; *w++ = 0x94; *w++ = 0xCB;
    return emit_u32(w, (uint32_t)disp);
}

/* mov %rax, disp32(%rbx, %rcx, 8)  (8 bytes) — store at offset+sp*8. */
static uint8_t *emit_store_rax_at_disp_stack(uint8_t *w, int32_t disp) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0x84; *w++ = 0xCB;
    return emit_u32(w, (uint32_t)disp);
}

/* movq %rax, %xmm0  (5 bytes): 66 48 0F 6E C0 */
static uint8_t *emit_movq_rax_xmm0(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x6E; *w++ = 0xC0; return w;
}
/* movq %rdx, %xmm1  (5 bytes): 66 48 0F 6E CA */
static uint8_t *emit_movq_rdx_xmm1(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x6E; *w++ = 0xCA; return w;
}
/* movq %xmm1, %rax  (5 bytes): 66 48 0F 7E C8 */
static uint8_t *emit_movq_xmm1_rax(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x7E; *w++ = 0xC8; return w;
}
/* addsd %xmm0, %xmm1  (4 bytes): F2 0F 58 C8  (xmm1 = xmm1 + xmm0) */
static uint8_t *emit_addsd_xmm0_xmm1(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x0F; *w++ = 0x58; *w++ = 0xC8; return w;
}
/* subsd %xmm0, %xmm1  (4 bytes): F2 0F 5C C8  (xmm1 = xmm1 - xmm0) */
static uint8_t *emit_subsd_xmm0_xmm1(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x0F; *w++ = 0x5C; *w++ = 0xC8; return w;
}
/* mulsd %xmm0, %xmm1  (4 bytes): F2 0F 59 C8  (xmm1 = xmm1 * xmm0) */
static uint8_t *emit_mulsd_xmm0_xmm1(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x0F; *w++ = 0x59; *w++ = 0xC8; return w;
}
/* divsd %xmm0, %xmm1  (4 bytes): F2 0F 5E C8  (xmm1 = xmm1 / xmm0) */
static uint8_t *emit_divsd_xmm0_xmm1(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x0F; *w++ = 0x5E; *w++ = 0xC8; return w;
}

/* cvttsd2si %xmm0, %rax  (5 bytes: F2 48 0F 2C C0) — truncating
 * double→int64. Used by INT_BINOP arms to mirror `(int64_t)d`. */
static uint8_t *emit_cvttsd2si_xmm0_rax(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x2C; *w++ = 0xC0; return w;
}
/* cvttsd2si %xmm1, %rdx  (5 bytes: F2 48 0F 2C D1) */
static uint8_t *emit_cvttsd2si_xmm1_rdx(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x2C; *w++ = 0xD1; return w;
}
/* cvtsi2sd %rdx, %xmm0  (5 bytes: F2 48 0F 2A C2) — int64→double. */
static uint8_t *emit_cvtsi2sd_rdx_xmm0(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x2A; *w++ = 0xC2; return w;
}
/* movq %xmm0, %rax  (5 bytes: 66 48 0F 7E C0) — extract low qword of
 * xmm0 (which now holds the converted double result) into rax for
 * storage at stack[sp-2]. */
static uint8_t *emit_movq_xmm0_rax(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x7E; *w++ = 0xC0; return w;
}
/* and %rax, %rdx  (3 bytes: 48 21 C2) — rdx &= rax */
static uint8_t *emit_and_rax_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x21; *w++ = 0xC2; return w;
}
/* or %rax, %rdx  (3 bytes: 48 09 C2) — rdx |= rax */
static uint8_t *emit_or_rax_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x09; *w++ = 0xC2; return w;
}
/* xor %rax, %rdx  (3 bytes: 48 31 C2) — rdx ^= rax */
static uint8_t *emit_xor_rax_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x31; *w++ = 0xC2; return w;
}
/* mov %rax, %rcx  (3 bytes: 48 89 C1) — copy rax → rcx so cl carries
 * the shift count for shl/shr by %cl. Caller must push %rcx first
 * (we use %rcx as the sp cache) and pop after. */
static uint8_t *emit_mov_rax_rcx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0xC1; return w;
}
/* shl %cl, %rdx  (3 bytes: 48 D3 E2) — rdx <<= cl */
static uint8_t *emit_shl_cl_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xD3; *w++ = 0xE2; return w;
}
/* sar %cl, %rdx  (3 bytes: 48 D3 FA) — arithmetic right shift, used
 * for OP_SHR. The VM's `INT_BINOP(SHR, >>)` casts to int64_t before
 * shifting, and GCC defines signed `>>` as arithmetic (sign-extending)
 * — so SAR is the correct match, not SHR. */
static uint8_t *emit_sar_cl_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xD3; *w++ = 0xFA; return w;
}

/* xor %rdx, %rax  (3 bytes: 48 31 D0) — rax ^= rdx. Used by OP_NEG to
 * flip the IEEE-754 sign bit (rdx holds 0x8000000000000000). */
static uint8_t *emit_xor_rdx_rax(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x31; *w++ = 0xD0; return w;
}
/* btr $63, %rax  (5 bytes: 48 0F BA F0 3F) — clear sign bit of %rax.
 * Used by OP_NOT so ±0.0 both compare as zero. ModRM /6 = BTR; /7 is
 * BTC (flip), which is a subtle one-bit difference and a tempting trap. */
static uint8_t *emit_btr_63_rax(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x0F; *w++ = 0xBA; *w++ = 0xF0; *w++ = 0x3F;
    return w;
}
/* test %rax, %rax  (3 bytes: 48 85 C0) — sets ZF=1 iff %rax == 0. */
static uint8_t *emit_test_rax_rax(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x85; *w++ = 0xC0; return w;
}
/* cmove %rsi, %rdx  (4 bytes: 48 0F 44 D6) — if ZF=1, rdx ← rsi. */
static uint8_t *emit_cmove_rsi_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x0F; *w++ = 0x44; *w++ = 0xD6; return w;
}
/* not %rax  (3 bytes: 48 F7 D0) — rax = ~rax. */
static uint8_t *emit_not_rax(uint8_t *w) {
    *w++ = 0x48; *w++ = 0xF7; *w++ = 0xD0; return w;
}
/* cvtsi2sd %rax, %xmm0  (5 bytes: F2 48 0F 2A C0) — int64 → double,
 * the inverse of cvttsd2si. Used by OP_BNOT to box the integer back. */
static uint8_t *emit_cvtsi2sd_rax_xmm0(uint8_t *w) {
    *w++ = 0xF2; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x2A; *w++ = 0xC0; return w;
}
/* mov %rdx, disp32(%rbx, %rcx, 8)  — store rdx-typed result at
 * stack[sp-k]. Pair with disp = off_stack - k*8. (8 bytes) */
static uint8_t *emit_store_rdx_at_disp_stack(uint8_t *w, int32_t disp) {
    *w++ = 0x48; *w++ = 0x89; *w++ = 0x94; *w++ = 0xCB;
    return emit_u32(w, (uint32_t)disp);
}
/* xor %rdx, %rdx  (3 bytes: 48 31 D2) — clear %rdx (bits of +0.0). */
static uint8_t *emit_xor_rdx_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x31; *w++ = 0xD2; return w;
}

/* ucomisd %xmm0, %xmm1  (4 bytes: 66 0F 2E C8) — AT&T order: compares
 * %xmm1 (= a) with %xmm0 (= b). Sets ZF/PF/CF per IEEE-754 ordered
 * comparison (PF=1 if either is NaN — accepted imprecision: num_guard
 * prevents NaN from reaching the stack in normal operation). */
static uint8_t *emit_ucomisd_xmm0_xmm1(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x0F; *w++ = 0x2E; *w++ = 0xC8; return w;
}

/* xor %rax, %rax  (3 bytes: 48 31 C0) — clears %rax (bits of +0.0). */
static uint8_t *emit_xor_rax_rax(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x31; *w++ = 0xC0; return w;
}

/* movabs $imm64, %rdx  (10 bytes) */
static uint8_t *emit_movabs_rdx(uint8_t *w, uint64_t imm) {
    *w++ = 0x48; *w++ = 0xBA;
    return emit_u64(w, imm);
}

/* cmovcc %rdx, %rax  (4 bytes: 48 0F 4X C2) — conditional 64-bit move
 * of %rdx into %rax when CC holds. `cc_byte` is the second opcode
 * byte: 0x44=cmove, 0x45=cmovne, 0x42=cmovb, 0x43=cmovae,
 * 0x46=cmovbe, 0x47=cmova. */
static uint8_t *emit_cmovcc_rdx_rax(uint8_t *w, uint8_t cc_byte) {
    *w++ = 0x48; *w++ = 0x0F; *w++ = cc_byte; *w++ = 0xC2; return w;
}

/* jae rel32  (6 bytes): 0F 83 disp32. Returns patch pointer to disp32. */
static uint8_t *emit_jae_rel32(uint8_t *w, uint8_t **patch) {
    *w++ = 0x0F; *w++ = 0x83; *patch = w;
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    return w;
}
/* ja rel32  (6 bytes): 0F 87 disp32 */
static uint8_t *emit_ja_rel32(uint8_t *w, uint8_t **patch) {
    *w++ = 0x0F; *w++ = 0x87; *patch = w;
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    return w;
}
/* jmp rel32  (5 bytes): E9 disp32 — unconditional. */
static uint8_t *emit_jmp_rel32(uint8_t *w, uint8_t **patch) {
    *w++ = 0xE9; *patch = w;
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    return w;
}
/* je rel32  (6 bytes): 0F 84 disp32 — jump if ZF=1 (was zero / equal). */
static uint8_t *emit_je_rel32(uint8_t *w, uint8_t **patch) {
    *w++ = 0x0F; *w++ = 0x84; *patch = w;
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    return w;
}
/* jne rel32  (6 bytes): 0F 85 disp32 — jump if ZF=0 (non-zero). */
static uint8_t *emit_jne_rel32(uint8_t *w, uint8_t **patch) {
    *w++ = 0x0F; *w++ = 0x85; *patch = w;
    *w++ = 0; *w++ = 0; *w++ = 0; *w++ = 0;
    return w;
}
/* Patch a previously-emitted rel32 conditional/unconditional jmp.
 * `patch` is the address of the 4-byte displacement (returned by the
 * emit_* function). `target` is the destination address. */
static void patch_rel32(uint8_t *patch, uint8_t *target) {
    int32_t disp = (int32_t)(target - (patch + 4));
    memcpy(patch, &disp, 4);
}

/* xor %r13d, %r13d  (3 bytes: 45 31 ED) — clear advance tracker. */
static uint8_t *emit_xor_r13d_r13d(uint8_t *w) {
    *w++ = 0x45; *w++ = 0x31; *w++ = 0xED; return w;
}

/* btr $63, %rdx  (5 bytes: 48 0F BA F2 3F) — clear sign bit of %rdx. */
static uint8_t *emit_btr_63_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x0F; *w++ = 0xBA; *w++ = 0xF2; *w++ = 0x3F;
    return w;
}
/* btr $63, %rsi  (5 bytes: 48 0F BA F6 3F) — clear sign bit of %rsi. */
static uint8_t *emit_btr_63_rsi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x0F; *w++ = 0xBA; *w++ = 0xF6; *w++ = 0x3F;
    return w;
}
/* test %rsi, %rsi  (3 bytes: 48 85 F6) — ZF=1 iff %rsi == 0. */
static uint8_t *emit_test_rsi_rsi(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x85; *w++ = 0xF6; return w;
}
/* movq %rdx, %xmm0  (5 bytes: 66 48 0F 6E C2) — int64-to-double-bits
 * transfer used to set up the dividend (a) for fmod(a, b). */
static uint8_t *emit_movq_rdx_xmm0(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x6E; *w++ = 0xC2; return w;
}
/* movq %rax, %xmm1  (5 bytes: 66 48 0F 6E C8) — set up the divisor (b)
 * for fmod(a, b). */
static uint8_t *emit_movq_rax_xmm1(uint8_t *w) {
    *w++ = 0x66; *w++ = 0x48; *w++ = 0x0F; *w++ = 0x6E; *w++ = 0xC8; return w;
}

/* cmp %rsi, %rdx  (3 bytes: 48 39 F2) */
static uint8_t *emit_cmp_rsi_rdx(uint8_t *w) {
    *w++ = 0x48; *w++ = 0x39; *w++ = 0xF2; return w;
}

/* Emit immediate-num type check: copy %rax (or %rdx) to %rsi, shift
 * down 48, compare to QNaN start (0xFFF8), and jae rel32 → bail patch.
 * (3 + 4 + 6 + 6 = 19 bytes.) */
static uint8_t *emit_immediate_num_check_rax(uint8_t *w, uint8_t **patch) {
    w = emit_mov_rax_rsi(w);
    w = emit_shr_48_rsi(w);
    w = emit_cmp_imm32_esi(w, 0xFFF8);
    return emit_jae_rel32(w, patch);
}
static uint8_t *emit_immediate_num_check_rdx(uint8_t *w, uint8_t **patch) {
    w = emit_mov_rdx_rsi(w);
    w = emit_shr_48_rsi(w);
    w = emit_cmp_imm32_esi(w, 0xFFF8);
    return emit_jae_rel32(w, patch);
}

/* Emit overflow/NaN check on result in %rax: copy to %rdx, clear sign
 * bit, compare to bits-of-1e308; ja rel32 → bail. (3+5+10+3+6 = 27 b.) */
static uint8_t *emit_overflow_check_rax(uint8_t *w, uint64_t max_bits,
                                        uint8_t **patch) {
    w = emit_mov_rax_rdx(w);
    w = emit_btr_63_rdx(w);
    w = emit_movabs_rsi(w, max_bits);
    w = emit_cmp_rsi_rdx(w);
    return emit_ja_rel32(w, patch);
}

/* Emit inline conditional decref of a slot held in %rsi.
 *
 * Sequence (~58 bytes worst case, including helper call site):
 *   mov %rsi, %rdx;  shr $48, %rdx;
 *   cmp $0xFFFB, %edx;  jb .skip
 *   mov %rsi, %rdi;  shl $16, %rdi;  shr $16, %rdi
 *   testb $1, off_arena(%rdi);  jnz .skip
 *   lock subl $1, off_refcount(%rdi);  jg .skip
 *   push %rcx                      // save sp cache + align stack
 *   movabs $free_value, %rax;  call *%rax
 *   pop %rcx
 *  .skip:
 *
 * Uses %rax/%rdx/%rdi/%rsi as scratch — caller must not depend on
 * these surviving. Returns advanced write pointer; sets *bail=1 on
 * rel8 overflow. */
static uint8_t *emit_conditional_decref_rsi(uint8_t *w, int *bail) {
    w = emit_mov_rsi_rdx(w);
    w = emit_shr_48_rdx(w);
    w = emit_cmp_imm32_edx(w, 0xFFFB);
    uint8_t *jb_patch;
    w = emit_jb_rel8(w, &jb_patch);
    uint8_t *jb_after = w;
    w = emit_mov_rsi_rdi(w);
    w = emit_shl_16_rdi(w);
    w = emit_shr_16_rdi(w);
    w = emit_testb_1_disp32_rdi(w, (int32_t)offsetof(Value, arena));
    uint8_t *jnz_patch;
    w = emit_jnz_rel8(w, &jnz_patch);
    uint8_t *jnz_after = w;
    w = emit_lock_subl_1_disp32_rdi(w, (int32_t)offsetof(Value, refcount));
    uint8_t *jg_patch;
    w = emit_jg_rel8(w, &jg_patch);
    uint8_t *jg_after = w;
    /* refcount went to 0 (or negative): free_value(%rdi). %rdi already
     * holds the Value*. Save %rcx (caller-saved sp cache) and align. */
    w = emit_push_rcx(w);
    w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&free_value);
    w = emit_call_rax(w);
    w = emit_pop_rcx(w);
    int jb_rel = (int)(w - jb_after);
    int jnz_rel = (int)(w - jnz_after);
    int jg_rel = (int)(w - jg_after);
    if (jb_rel > 127 || jnz_rel > 127 || jg_rel > 127) {
        *bail = 1; return w;
    }
    *jb_patch = (uint8_t)jb_rel;
    *jnz_patch = (uint8_t)jnz_rel;
    *jg_patch = (uint8_t)jg_rel;
    return w;
}
#endif

/* Tiered-JIT hotness thresholds. A chunk qualifies for native code when
 * EITHER signal trips:
 *   - exec_count ≥ ENTRY_THRESHOLD: the chunk is called frequently
 *     (small worker called in a loop pattern). The original gate.
 *   - back_edge_count ≥ ITER_THRESHOLD: the chunk loops heavily internally
 *     even if called only a handful of times. Catches the "one big
 *     function with hot inner loops" shape (common in gauntlet, DMG,
 *     iLambdaAi training step) where the entry-count gate alone leaves
 *     hot work interpreted indefinitely.
 *
 * Caveat: jit_try_compile_chunk only runs at frame-entry sites (OP_CALL
 * and OP_DISPATCH). A back-edge-rich chunk that's never called again
 * after the iterations complete will still miss JIT — true OSR is the
 * fix for that, deferred. The current change unblocks chunks called ≥2
 * times where the first call did substantial loop work.
 *
 * Both thresholds can be overridden at runtime via EIGS_JIT_ENTRY_THRESHOLD
 * / EIGS_JIT_ITER_THRESHOLD for tuning without rebuilds. */
#define EIGS_JIT_ENTRY_THRESHOLD 50
#define EIGS_JIT_ITER_THRESHOLD  500
/* OSR: trigger an OSR compile attempt once a chunk's back_edge_count
 * crosses this. The gate fires mid-execution on the JUMP_BACK itself
 * (cf. the iter gate, which only fires on the *next* chunk entry —
 * useless for top-level / one-shot chunks).
 *
 * Default chosen at 5000 (10x the iter gate) for "hot-loop discovery":
 * back_edge_count is chunk-wide, so a setup loop that runs e.g. 600
 * times then exits will not race a much hotter loop for the OSR slot —
 * the hot loop's back-edges dominate the counter before threshold and
 * win the entry_offset at compile time. Lower thresholds (500) were
 * measured to lock onto small setup loops and regress vs OFF by ~7%
 * on a setup-then-hot probe; 5000 cleanly captures the hot loop. The
 * long-loop case (5M+ iterations) is insensitive to threshold values
 * in [200, 5000] — savings dwarf the 4500 extra interpreted iterations. */
#define EIGS_JIT_OSR_THRESHOLD   5000

static int g_entry_threshold = -1;
static int g_iter_threshold  = -1;
static int g_osr_threshold   = -1;

static void load_thresholds(void) {
    if (g_entry_threshold < 0) {
        const char *e = getenv("EIGS_JIT_ENTRY_THRESHOLD");
        g_entry_threshold = e ? atoi(e) : EIGS_JIT_ENTRY_THRESHOLD;
        if (g_entry_threshold < 1) g_entry_threshold = 1;
    }
    if (g_iter_threshold < 0) {
        const char *e = getenv("EIGS_JIT_ITER_THRESHOLD");
        g_iter_threshold = e ? atoi(e) : EIGS_JIT_ITER_THRESHOLD;
        if (g_iter_threshold < 1) g_iter_threshold = 1;
    }
    if (g_osr_threshold < 0) {
        const char *e = getenv("EIGS_JIT_OSR_THRESHOLD");
        g_osr_threshold = e ? atoi(e) : EIGS_JIT_OSR_THRESHOLD;
        if (g_osr_threshold < 1) g_osr_threshold = 1;
    }
}

/* Exposed so vm.c can read the OSR threshold once per thread on the
 * first back-edge rather than getenv-checking inside the hot loop. */
int eigs_jit_get_osr_threshold(void) {
    load_thresholds();
    return g_osr_threshold;
}

/* Phase 2b: the body of jit_try_compile_chunk is now this static helper,
 * parameterized on entry_offset and on output pointers for the
 * state/code/advance/stop_op slots so the same emitter can drive both
 * the from-zero thunk (chunk->jit_*) and the OSR thunk (chunk->jit_osr_*).
 *
 * The emitted native code itself stores r13d (the advance writeback) at
 * `advance_field_offset` bytes from &chunk via %r14 — the from-zero call
 * passes offsetof(EigsChunk, jit_advance); the OSR call passes
 * offsetof(EigsChunk, jit_osr_advance). All gating and idempotency
 * (state check, EIGS_JIT_OFF, threshold) live in the public wrappers. */
static void jit_compile_to_thunk(struct EigsChunk *chunk,
                                 int entry_offset,
                                 int advance_field_offset,
                                 uint8_t *out_state,
                                 void **out_code,
                                 int *out_advance,
                                 uint8_t *out_stop_op) {
    g_jit_scanned_chunks++;
#if !defined(__x86_64__)
    (void)chunk;
    (void)entry_offset; (void)advance_field_offset; (void)out_advance;
    (void)out_stop_op;
    *out_state = 1;
    *out_code = NULL;
    return;
#else
    ensure_layout();

    int needs_env_cache = 0;
    int has_bail_op = 0;
    uint8_t stop_op = OP_COUNT;
    int stop_offset = 0;
    int prefix = jit_supported_prefix(chunk, entry_offset,
                                      &needs_env_cache, &has_bail_op,
                                      &stop_op, &stop_offset);
    *out_stop_op = stop_op;
    /* Every scanned chunk contributes one stop_op tally, whether it
     * ultimately compiles or not. Compiled chunks also bump
     * g_jit_compiled_count, so total_stops - compiled = bailouts. */
    g_jit_stop_counts[stop_op]++;
    if (getenv("EIGS_JIT_DUMP_BAIL") && prefix == 0 &&
        stop_op != OP_COUNT) {
        fprintf(stderr,
                "JIT bail: chunk='%s' stop_op=%s at offset %d (prefix=0 ops)\n",
                chunk->name ? chunk->name : "<anon>",
                op_name(stop_op), stop_offset);
    }
    /* EIGS_JIT_DUMP_PREFIX="name" dumps full bytecode + the prefix
     * scanner's stop point for chunks matching `name`. Use to see
     * exactly what op the scanner ran into for a partially-compiled
     * hot chunk (e.g. mem_read at 44/1240 bytes). */
    {
        const char *want = getenv("EIGS_JIT_DUMP_PREFIX");
        if (want && chunk->name && strcmp(want, chunk->name) == 0) {
            fprintf(stderr,
                    "=== JIT prefix dump: chunk='%s' len=%d prefix=%d "
                    "stop_op=%s stop_offset=%d ===\n",
                    chunk->name, chunk->code_len, prefix,
                    (stop_op == OP_COUNT) ? "<end>" : op_name(stop_op),
                    stop_offset);
            chunk_disassemble(chunk, chunk->name);
        }
    }
    /* "Didn't compile any ops" sentinel. For the from-zero call this
     * matches `prefix == 0`; for OSR (entry_offset > 0) the scanner
     * returns 0 only when it couldn't make progress past entry_offset
     * either, so the check is identical. */
    if (prefix == 0 || prefix <= entry_offset) {
        g_jit_stop_at_zero++;
        *out_state = 1;
        *out_code = NULL;
        return;
    }

    if (!g_jit_cache) {
        g_jit_cache = jit_cache_new(256); /* 256 pages = 1 MB */
        if (!g_jit_cache) {
            *out_state = 1;
            *out_code = NULL;
            return;
        }
    }
    if (jit_cache_unseal(g_jit_cache) != 0) {
        *out_state = 1;
        *out_code = NULL;
        return;
    }

    size_t size = jit_estimate_size(prefix - entry_offset, needs_env_cache,
                                    has_bail_op);
    uint8_t *code = jit_cache_alloc(g_jit_cache, size);
    if (!code) {
        *out_state = 1;
        *out_code = NULL;
        jit_cache_seal(g_jit_cache);
        return;
    }

    uint8_t *w = code;

    /* Bit pattern of 1e308 — the maximum finite value num_guard allows.
     * Any addsd/subsd result whose magnitude bits exceed this (incl.
     * ±Inf / NaN) bails to the slow interpreter path. */
    uint64_t max_normal_bits;
    { double d = 1e308; memcpy(&max_normal_bits, &d, 8); }

    /* Bail-jump rel32 patch sites collected during body emission and
     * resolved against the epilogue once we know its address. */
    uint8_t *bail_patches[256];
    int bail_count = 0;

    /* Stage 4i: forward/backward intra-prefix jump bookkeeping.
     *   byte_to_native[i] = native offset (from `code`) where bytecode
     *                       byte i begins. -1 means not yet emitted (or
     *                       outside the prefix).
     *   pending[k]         = (target_bytecode_offset, rel32_patch_site).
     *                       Resolved after the body to point either into
     *                       compiled code or to the common epilogue.
     *
     * One entry per intra-prefix jump op. 256 is sufficient: each jump
     * is at least 3 bytecode bytes, so a 256-op prefix caps out before
     * we run out of slots. */
    /* Allocated `prefix` long (absolute indexing). For OSR the
     * [0, entry_offset) entries are never written or read but the
     * over-allocation is small (a few hundred bytes typical). */
    int *byte_to_native = NULL;
    struct { int target; uint8_t *patch; } pending[256];
    int pending_count = 0;
    if (prefix > 0) {
        byte_to_native = malloc((size_t)prefix * sizeof(int));
        if (!byte_to_native) {
            *out_state = 1; *out_code = NULL;
            jit_cache_seal(g_jit_cache); return;
        }
        for (int k = 0; k < prefix; k++) byte_to_native[k] = -1;
    }
    /* Bail-out helper for the compile path so all the seal/free dance
     * stays in one place. */
    #define JIT_BAIL_AND_RETURN() do { \
        free(byte_to_native); \
        *out_state = 1; *out_code = NULL; \
        jit_cache_seal(g_jit_cache); return; \
    } while (0)

    /* Prologue: preserve %rbx + %r12 (+ %r13/%r14 when has_bail_op),
     * point %rbx at &g_vm, cache sp.
     *
     * Register allocation across the thunk:
     *   %rbx = &g_vm                 (callee-saved, set once)
     *   %ecx = g_vm.sp               (live, mutates with pushes/pops)
     *   %r12 = current_frame->fn_env->values  (when needs_env_cache)
     *   %r13d = advance tracker      (when has_bail_op): bytecode offset
     *           just past last successful op. Written to
     *           chunk->jit_advance in the common epilogue.
     *   %r14 = &chunk                (when has_bail_op)
     *
     * %rdx/%rdi/%rsi/%rax are scratch for incref/decref/SSE logic.
     *
     * Stack alignment: on entry %rsp = 8 mod 16. We push 2 or 4 callee-
     * saved regs (16 or 32 bytes), so the body sees %rsp = 8 mod 16 in
     * both cases — `push %rcx` re-aligns to 0 mod 16 before external
     * calls (free_value via emit_conditional_decref_rsi). */
    w = emit_u8(w, 0x53);                                       /* push %rbx */
    w = emit_u8(w, 0x41); w = emit_u8(w, 0x54);                 /* push %r12 */
    if (has_bail_op) {
        w = emit_push_r13(w);
        w = emit_push_r14(w);
    }
    w = emit_load_fs_zero_rbx(w);                               /* mov %fs:0, %rbx */
    w = emit_lea_rbx_disp32_rbx(w, (int32_t)g_layout.g_vm_tpoff);
    w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);         /* mov sp, %ecx */
    if (has_bail_op) {
        w = emit_movabs_r14(w, (uint64_t)(uintptr_t)chunk);
        w = emit_xor_r13d_r13d(w);
    }

    if (needs_env_cache) {
        /* %r12 = &g_vm.frames[frame_count - 1]
         *      = &g_vm + off_frames + (fc-1)*sizeof_callframe
         * Then chase frame->fn_env then env->values into %r12. */
        w = emit_mov_disp32_rbx_to_eax(w, g_layout.off_frame_count);
        w = emit_dec_eax(w);
        w = emit_imul_imm32_rax(w, g_layout.sizeof_callframe);
        w = emit_lea_rbx_rax_to_r12(w, g_layout.off_frames);
        w = emit_mov_disp32_r12_to_r12(w, g_layout.off_callframe_fn_env);
        w = emit_mov_disp32_r12_to_r12(w, g_layout.off_env_values);
    }

    /* Body: inline native code per opcode. */
    int i = entry_offset;
    /* Emit-time mirror of the scanner's last_push_immediate tracker.
     * Required for OP_POP, which has two emission paths:
     *   - imm=1: `dec %ecx` peephole (slot_decref of immediate is no-op)
     *   - imm=0: load+dec+conditional_decref_rsi
     * Must transition the same way the scanner does — see jit_supported_prefix. */
    int last_imm = 0;
    while (i < prefix) {
        uint8_t op = chunk->code[i];
        int op_start = i;  /* saved for post-iteration last_imm update */
        /* Record the native entry point for this bytecode byte so that
         * later intra-prefix jumps can target it. We capture this BEFORE
         * emitting the op; backward JUMP_BACK to byte 0 thus lands at
         * the start of the body (after env-cache setup), not at the
         * thunk prologue — re-running the prologue would clobber %rcx. */
        if (byte_to_native) byte_to_native[i] = (int)(w - code);
        /* Unconditional jumps suppress the trailing `mov $i, %r13d`
         * advance writeback because the next bytes are unreachable. */
        int skip_post_op_advance = 0;
        if (op == OP_NULL || op == OP_NUM_ZERO || op == OP_NUM_ONE) {
            uint64_t bits;
            if (op == OP_NULL) {
                bits = 0xFFF8000000000000ULL;       /* SLOT_NULL_BITS */
            } else if (op == OP_NUM_ZERO) {
                bits = 0;                            /* IEEE-754 +0.0 */
            } else {
                double d = 1.0;
                memcpy(&bits, &d, 8);                /* IEEE-754 1.0 */
            }
            w = emit_movabs_rax(w, bits);
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            i += 1;
        } else if (op == OP_CONST) {
            uint16_t idx = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            Value *v = chunk->constants[idx];
            uint64_t bits;
            int needs_incref = 0;
            if (v->type == VAL_NUM && v->obs_age == 0) {
                /* Immediate-num: same shape as NUM_ZERO. */
                memcpy(&bits, &v->data.num, 8);
            } else {
                /* Heap slot: TAG_HEAP | payload. Incref unless arena. */
                bits = 0xFFFB000000000000ULL |
                       ((uint64_t)(uintptr_t)v & 0x0000FFFFFFFFFFFFULL);
                needs_incref = !v->arena;
            }
            w = emit_movabs_rax(w, bits);
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            if (needs_incref) {
                w = emit_movabs_rdi(w, (uint64_t)(uintptr_t)v);
                w = emit_lock_addl_1_disp32_rdi(
                        w, (int32_t)offsetof(Value, refcount));
            }
            i += 3;
        } else if (op == OP_GET_LOCAL) {
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            /* %rax = values[slot]  (8-byte slot at slot*8 offset) */
            w = emit_mov_disp32_r12_to_rax(w, (int32_t)slot * 8);
            int bail = 0;
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                JIT_BAIL_AND_RETURN();
            }
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            i += 3;
        } else if (op == OP_GET_NAME) {
            /* Stage 4k: out-of-line call to jit_helper_get_name(chunk, idx).
             * The helper does the EnvIC walk and slot push via vm_push_slot
             * — both touch g_vm.sp directly, so we sync our %ecx cache to
             * g_vm.sp before the call and reload after. Stack alignment:
             * body is at 8-mod-16; `push %rcx` carries us to 0-mod-16 (the
             * pushed value is junk, since we reload %ecx from g_vm.sp on
             * return). chunk pointer comes from %r14 (always set when
             * has_bail_op, which OP_GET_NAME forces). */
            uint16_t idx = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_r14_rdi(w);
            w = emit_mov_imm32_esi(w, (uint32_t)idx);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_get_name);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 3;
        } else if (op == OP_LOCAL_IDX_GET) {
            /* Stage 4l: out-of-line call to jit_helper_local_idx_get(slot, idx).
             * Helper resolves the frame's local, dispatches on container type,
             * and pushes the result via vm_push_slot/vm_push. Same sp sync/
             * reload pattern as OP_GET_NAME; %r14 not needed. */
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            uint16_t idx = (uint16_t)(chunk->code[i + 3] |
                                      ((uint16_t)chunk->code[i + 4] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_imm32_edi(w, (uint32_t)slot);
            w = emit_mov_imm32_esi(w, (uint32_t)idx);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_local_idx_get);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 5;
        } else if (op == OP_LOCAL_DOT_GET) {
            /* Stage 4m: out-of-line call to
             *   jit_helper_local_dot_get(chunk, slot, name_idx).
             * chunk arrives in %rdi via %r14 (has_bail_op forces load);
             * slot in %esi, name_idx in %edx. Same sp sync/reload as 4k/4l. */
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            uint16_t name_idx = (uint16_t)(chunk->code[i + 3] |
                                           ((uint16_t)chunk->code[i + 4] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_r14_rdi(w);
            w = emit_mov_imm32_esi(w, (uint32_t)slot);
            w = emit_mov_imm32_edx(w, (uint32_t)name_idx);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_local_dot_get);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 5;
        } else if (op == OP_LOCAL_IDX_DOT_GET) {
            /* Stage 4v: out-of-line call to
             *   jit_helper_local_idx_dot_get(chunk, slot, list_idx, name_idx).
             * 7-byte op [op][slot:16][list_idx:16][name_idx:16].
             * chunk → %rdi via %r14, slot → %esi, list_idx → %edx,
             * name_idx → %ecx (4th SysV arg). Since %ecx is our sp
             * cache, we sync first, then push %rcx for 16-byte align,
             * then load the arg regs (the name_idx → %ecx load clobbers
             * the cache but the sync already saved it), then call,
             * then reload sp from g_vm.sp. */
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            uint16_t list_idx = (uint16_t)(chunk->code[i + 3] |
                                           ((uint16_t)chunk->code[i + 4] << 8));
            uint16_t name_idx = (uint16_t)(chunk->code[i + 5] |
                                           ((uint16_t)chunk->code[i + 6] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_push_rcx(w);
            w = emit_mov_r14_rdi(w);
            w = emit_mov_imm32_esi(w, (uint32_t)slot);
            w = emit_mov_imm32_edx(w, (uint32_t)list_idx);
            w = emit_mov_imm32_ecx(w, (uint32_t)name_idx);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_local_idx_dot_get);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 7;
        } else if (op == OP_DOT_GET) {
            /* Stage 4q-f: out-of-line call to
             *   jit_helper_dot_get(chunk, name_idx).
             * chunk via %r14 → %rdi, name_idx in %esi. Helper pops 1,
             * pushes 1 — sp neutral. Sync %ecx → g_vm.sp before call so
             * helper sees TOS; reload after to keep cache honest. */
            uint16_t name_idx = (uint16_t)(chunk->code[i + 1] |
                                           ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_r14_rdi(w);
            w = emit_mov_imm32_esi(w, (uint32_t)name_idx);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_dot_get);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 3;
        } else if (op == OP_LOCAL_DOT_SET) {
            /* Stage 4q-d: out-of-line call to
             *   jit_helper_local_dot_set(chunk, slot, name_idx).
             * Mirrors LOCAL_DOT_GET wire-up: chunk via %r14, slot in
             * %esi, name_idx in %edx. Helper reads g_vm.stack[sp-1] —
             * sync %ecx → g_vm.sp before call. sp is unchanged on
             * return; reload %ecx for safety (matches existing pattern,
             * keeps the cache in sync if helper internals ever change). */
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            uint16_t name_idx = (uint16_t)(chunk->code[i + 3] |
                                           ((uint16_t)chunk->code[i + 4] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_r14_rdi(w);
            w = emit_mov_imm32_esi(w, (uint32_t)slot);
            w = emit_mov_imm32_edx(w, (uint32_t)name_idx);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_local_dot_set);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 5;
        } else if (op == OP_OBSERVE_ASSIGN) {
            /* Stage 4o: out-of-line call to
             *   jit_helper_observe_assign(chunk, name_idx).
             * chunk arrives via %r14 (has_bail_op forces load). Helper
             * reads g_vm.stack[sp-1] — sync %ecx → g_vm.sp before call.
             * Helper does not change sp; reload %ecx after for safety
             * (matches existing helper pattern, ~1 load). */
            uint16_t name_idx = (uint16_t)(chunk->code[i + 1] |
                                           ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_r14_rdi(w);
            w = emit_mov_imm32_esi(w, (uint32_t)name_idx);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_observe_assign);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 3;
        } else if (op == OP_OBSERVE_ASSIGN_LOCAL) {
            /* Stage 4o: out-of-line call to
             *   jit_helper_observe_assign_local(slot).
             * No chunk needed; slot in %edi. Same sp sync/reload as
             * OBSERVE_ASSIGN. */
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_imm32_edi(w, (uint32_t)slot);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_observe_assign_local);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 3;
        } else if (op == OP_UNOBSERVED_BEGIN) {
            /* Stage 4q-e: inline `g_unobserved_depth++` as a single
             * FS-prefixed `inc dword [tpoff]`. No stack interaction,
             * no env, no bail. */
            w = emit_incl_fs_disp32(w,
                (int32_t)g_layout.g_unobserved_depth_tpoff);
            i += 1;
        } else if (op == OP_UNOBSERVED_END) {
            /* Stage 4q-e: symmetric `g_unobserved_depth--`. */
            w = emit_decl_fs_disp32(w,
                (int32_t)g_layout.g_unobserved_depth_tpoff);
            i += 1;
        } else if (op == OP_DUP) {
            /* %rax = stack[sp-1] */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            int bail = 0;
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                JIT_BAIL_AND_RETURN();
            }
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            i += 1;
        } else if (op == OP_DUP2) {
            /* a b -> a b a b: copy stack[sp-2] to stack[sp],
             *                stack[sp-1] to stack[sp+1], sp += 2. */
            int bail = 0;
            /* Copy stack[sp-2] -> stack[sp]. */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 16);
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                JIT_BAIL_AND_RETURN();
            }
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            /* Copy stack[sp-2] (which was stack[sp-1] before inc) ->
             * stack[sp] (which is stack[sp+1] in original coords). */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 16);
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                JIT_BAIL_AND_RETURN();
            }
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            i += 1;
        } else if (op == OP_SET_LOCAL) {
            uint16_t slot = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            int32_t off = (int32_t)slot * 8;
            /* %rax = stack[sp-1]   (tos, stays on stack) */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            /* %rsi = old values[slot]  (decref later) */
            w = emit_mov_disp32_r12_to_rsi(w, off);
            /* values[slot] = tos */
            w = emit_mov_rax_to_disp32_r12(w, off);
            /* Incref new (%rax). */
            int bail = 0;
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                JIT_BAIL_AND_RETURN();
            }
            /* Decref old (%rsi). Note: bounds check on slot < e->count
             * is omitted — compiler-emitted bytecode never overruns. */
            w = emit_conditional_decref_rsi(w, &bail);
            if (bail) {
                JIT_BAIL_AND_RETURN();
            }
            i += 3;
        } else if (op == OP_MOD) {
            /* fmod-based modulo. Diverges from add/sub/mul/div: a libm
             * call replaces the single SSE op, the divisor needs an
             * explicit zero check (the VM falls into the slow-path
             * error arm on b==0), and the call site needs to align
             * %rsp to 16. Four bail slots: two type checks, one zero
             * check, one overflow check on the result. */
            if (bail_count + 4 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint8_t *p_b, *p_a, *p_z, *p_ov;
            /* %rax = b, %rdx = a. */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            w = emit_load_stack_to_rdx(w, g_layout.off_stack - 16);
            w = emit_immediate_num_check_rax(w, &p_b);
            bail_patches[bail_count++] = p_b;
            w = emit_immediate_num_check_rdx(w, &p_a);
            bail_patches[bail_count++] = p_a;
            /* Divisor zero check. The VM compares `b->data.num != 0.0`,
             * which under IEEE-754 treats +0.0 and -0.0 as equal — so
             * we must also bail when b == -0.0 (bits = 0x8000…0).
             * Strategy: copy b's bits to %rsi (dead scratch after the
             * type checks), clear the sign bit, test for zero. */
            w = emit_mov_rax_rsi(w);
            w = emit_btr_63_rsi(w);
            w = emit_test_rsi_rsi(w);
            w = emit_je_rel32(w, &p_z);
            bail_patches[bail_count++] = p_z;
            /* fmod(a, b) takes args in %xmm0, %xmm1. Set xmm0 = a
             * (from %rdx) and xmm1 = b (from %rax). */
            w = emit_movq_rdx_xmm0(w);
            w = emit_movq_rax_xmm1(w);
            /* Align %rsp from 8-mod-16 to 0-mod-16 by saving the sp
             * cache. movabs+call is the same indirect-call pattern
             * used for free_value. */
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&fmod);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            /* Result in %xmm0 → %rax → overflow check (catches NaN /
             * ±Inf, including fmod(±Inf, x) = NaN propagation). */
            w = emit_movq_xmm0_rax(w);
            w = emit_overflow_check_rax(w, max_normal_bits, &p_ov);
            bail_patches[bail_count++] = p_ov;
            w = emit_store_rax_at_disp_stack(w, g_layout.off_stack - 16);
            w = emit_dec_ecx(w);
            i += 1;
        } else if (op == OP_ADD || op == OP_SUB ||
                   op == OP_MUL || op == OP_DIV) {
            /* Reserve patch slots: two type checks + one overflow check.
             * Bail-out budget headroom enforced statically (256 slots
             * vs prefix * 3 ≥ 3 * 128 = 384 worst case theoretical, but
             * in practice prefix * 3 ≪ 256 for compiled chunks). */
            if (bail_count + 3 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint8_t *p_b, *p_a, *p_ov;
            /* %rax = stack[sp-1] = b ; %rdx = stack[sp-2] = a */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            w = emit_load_stack_to_rdx(w, g_layout.off_stack - 16);
            /* Both must be immediate-num (upper 16 bits < 0xFFF8). */
            w = emit_immediate_num_check_rax(w, &p_b);
            bail_patches[bail_count++] = p_b;
            w = emit_immediate_num_check_rdx(w, &p_a);
            bail_patches[bail_count++] = p_a;
            /* Move into XMM: xmm0 = b, xmm1 = a. */
            w = emit_movq_rax_xmm0(w);
            w = emit_movq_rdx_xmm1(w);
            /* xmm1 = xmm1 OP xmm0 (a OP b). divsd by-zero produces
             * ±Inf or NaN — the overflow check below catches both, so
             * we don't need a separate divisor check. */
            switch (op) {
            case OP_ADD: w = emit_addsd_xmm0_xmm1(w); break;
            case OP_SUB: w = emit_subsd_xmm0_xmm1(w); break;
            case OP_MUL: w = emit_mulsd_xmm0_xmm1(w); break;
            default:     w = emit_divsd_xmm0_xmm1(w); break;
            }
            /* Result -> %rax for storage + overflow check. */
            w = emit_movq_xmm1_rax(w);
            /* |result| > 1e308 → bail (catches NaN, ±Inf, num_guard
             * clamp boundary). Stack is still untouched here, so bail
             * leaves the operands in place for the slow path. */
            w = emit_overflow_check_rax(w, max_normal_bits, &p_ov);
            bail_patches[bail_count++] = p_ov;
            /* Commit: store result at stack[sp-2], dec sp. */
            w = emit_store_rax_at_disp_stack(w, g_layout.off_stack - 16);
            w = emit_dec_ecx(w);
            i += 1;
        } else if (op == OP_EQ || op == OP_NE || op == OP_LT ||
                   op == OP_GT || op == OP_LE || op == OP_GE) {
            /* Two type-check bail slots; no overflow check (result is
             * bounded to {0.0, 1.0}). */
            if (bail_count + 2 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint8_t *p_b, *p_a;
            /* Load both, type-check (immediate-num). NaN inputs would
             * give incorrect comparison results (PF=1 makes setcc
             * paths fire), but num_guard prevents NaN from reaching a
             * stack slot in normal operation — so we accept the same
             * input-NaN imprecision as ADD/SUB do. */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            w = emit_load_stack_to_rdx(w, g_layout.off_stack - 16);
            w = emit_immediate_num_check_rax(w, &p_b);
            bail_patches[bail_count++] = p_b;
            w = emit_immediate_num_check_rdx(w, &p_a);
            bail_patches[bail_count++] = p_a;
            /* Move operands into xmm regs, then materialize the cmov
             * operands (%rax=0.0 bits, %rdx=1.0 bits) BEFORE ucomisd.
             * The materialization uses `xor %rax,%rax` which clobbers
             * ZF, so it must come before the comparison — otherwise
             * cmove would always fire (ZF=1 from the xor). movabs
             * does not touch flags, and movq/ucomisd between the xor
             * and cmovcc are the only flag-affecting ops left in this
             * sequence — ucomisd's flags are exactly what cmovcc sees. */
            w = emit_movq_rax_xmm0(w);   /* xmm0 = b */
            w = emit_movq_rdx_xmm1(w);   /* xmm1 = a */
            w = emit_xor_rax_rax(w);     /* rax = 0.0 bits */
            {
                uint64_t one_bits;
                double one = 1.0;
                memcpy(&one_bits, &one, 8);
                w = emit_movabs_rdx(w, one_bits); /* rdx = 1.0 bits */
            }
            w = emit_ucomisd_xmm0_xmm1(w);
            /* cmovcc %rdx → %rax when condition holds. */
            uint8_t cc_byte;
            switch (op) {
            case OP_EQ: cc_byte = 0x44; break; /* cmove */
            case OP_NE: cc_byte = 0x45; break; /* cmovne */
            case OP_LT: cc_byte = 0x42; break; /* cmovb */
            case OP_GT: cc_byte = 0x47; break; /* cmova */
            case OP_LE: cc_byte = 0x46; break; /* cmovbe */
            default:    cc_byte = 0x43; break; /* OP_GE → cmovae */
            }
            w = emit_cmovcc_rdx_rax(w, cc_byte);
            /* Commit: store result at stack[sp-2], dec sp. */
            w = emit_store_rax_at_disp_stack(w, g_layout.off_stack - 16);
            w = emit_dec_ecx(w);
            i += 1;
        } else if (op == OP_BAND || op == OP_BOR || op == OP_BXOR ||
                   op == OP_SHL || op == OP_SHR) {
            /* Bitwise INT_BINOP family: cast both doubles to int64,
             * apply the integer op, cast back. No overflow check —
             * the VM doesn't apply num_guard here either, so we match
             * its truncation semantics. Two bail slots for type check. */
            if (bail_count + 2 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint8_t *p_b, *p_a;
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            w = emit_load_stack_to_rdx(w, g_layout.off_stack - 16);
            w = emit_immediate_num_check_rax(w, &p_b);
            bail_patches[bail_count++] = p_b;
            w = emit_immediate_num_check_rdx(w, &p_a);
            bail_patches[bail_count++] = p_a;
            /* xmm0 = (double)b, xmm1 = (double)a → rax = (int64)b,
             * rdx = (int64)a. */
            w = emit_movq_rax_xmm0(w);
            w = emit_movq_rdx_xmm1(w);
            w = emit_cvttsd2si_xmm0_rax(w);
            w = emit_cvttsd2si_xmm1_rdx(w);
            /* Apply op: rdx = rdx OP rax. For SHL/SHR the shift count
             * must be in %cl, but %rcx holds our sp cache — save it,
             * move rax→rcx, shift, restore rcx. */
            if (op == OP_BAND) {
                w = emit_and_rax_rdx(w);
            } else if (op == OP_BOR) {
                w = emit_or_rax_rdx(w);
            } else if (op == OP_BXOR) {
                w = emit_xor_rax_rdx(w);
            } else {
                w = emit_push_rcx(w);
                w = emit_mov_rax_rcx(w);
                if (op == OP_SHL) w = emit_shl_cl_rdx(w);
                else              w = emit_sar_cl_rdx(w);
                w = emit_pop_rcx(w);
            }
            /* Cast back: xmm0 = (double)rdx, rax = xmm0 bits, store. */
            w = emit_cvtsi2sd_rdx_xmm0(w);
            w = emit_movq_xmm0_rax(w);
            w = emit_store_rax_at_disp_stack(w, g_layout.off_stack - 16);
            w = emit_dec_ecx(w);
            i += 1;
        } else if (op == OP_NEG || op == OP_NOT || op == OP_BNOT) {
            /* Unary: load TOS, type-check, compute in place, store
             * back at TOS. One bail slot, sp unchanged. */
            if (bail_count + 1 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint8_t *p_t;
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            w = emit_immediate_num_check_rax(w, &p_t);
            bail_patches[bail_count++] = p_t;
            if (op == OP_NEG) {
                /* Flip the IEEE-754 sign bit: rax ^= 0x8000…0. */
                w = emit_movabs_rdx(w, 0x8000000000000000ULL);
                w = emit_xor_rdx_rax(w);
                w = emit_store_rax_at_disp_stack(w, g_layout.off_stack - 8);
            } else if (op == OP_NOT) {
                /* Logical not over an immediate num: result is 1.0 iff
                 * the input is ±0.0, else 0.0. btr clears the sign bit
                 * so -0.0 and +0.0 both test as zero. Materialize the
                 * cmov operands BEFORE the test (xor clobbers ZF). */
                w = emit_btr_63_rax(w);
                w = emit_xor_rdx_rdx(w);          /* rdx = 0.0 bits */
                {
                    uint64_t one_bits;
                    double one = 1.0;
                    memcpy(&one_bits, &one, 8);
                    w = emit_movabs_rsi(w, one_bits); /* rsi = 1.0 bits */
                }
                w = emit_test_rax_rax(w);         /* ZF=1 iff input was ±0 */
                w = emit_cmove_rsi_rdx(w);        /* rdx = ZF ? rsi : rdx */
                w = emit_store_rdx_at_disp_stack(w, g_layout.off_stack - 8);
            } else { /* OP_BNOT */
                /* (double)(~(int64_t)d): cvttsd2si, not, cvtsi2sd back. */
                w = emit_movq_rax_xmm0(w);
                w = emit_cvttsd2si_xmm0_rax(w);
                w = emit_not_rax(w);
                w = emit_cvtsi2sd_rax_xmm0(w);
                w = emit_movq_xmm0_rax(w);
                w = emit_store_rax_at_disp_stack(w, g_layout.off_stack - 8);
            }
            i += 1;
        } else if (op == OP_JUMP || op == OP_JUMP_BACK) {
            /* Unconditional intra-prefix jump. Compute the bytecode
             * target, set r13d (so an out-of-prefix target carries the
             * right jit_advance into the epilogue), then emit jmp rel32.
             * Backward targets resolve immediately from byte_to_native;
             * forward targets register a pending patch resolved at the
             * end of body emission. */
            if (pending_count + 1 > (int)(sizeof pending /
                                          sizeof pending[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint16_t off = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            int target = (op == OP_JUMP) ? (i + 3 + (int)off)
                                         : (i + 3 - (int)off);
            /* r13d holds "bytes to advance from frame->ip on exit", and
             * frame->ip sits at entry_offset when the thunk is invoked.
             * The subtraction folds to identity when entry_offset == 0. */
            w = emit_mov_imm32_r13d(w, (uint32_t)(target - entry_offset));
            uint8_t *patch;
            w = emit_jmp_rel32(w, &patch);
            pending[pending_count].target = target;
            pending[pending_count].patch = patch;
            pending_count++;
            /* Suppress the post-op `mov $i+3, %r13d` — the bytes after
             * this jmp are unreachable until a backward branch loops
             * back here. */
            skip_post_op_advance = 1;
            i += 3;
        } else if (op == OP_JUMP_IF_FALSE || op == OP_JUMP_IF_TRUE ||
                   op == OP_JUMP_IF_FALSE_PEEK ||
                   op == OP_JUMP_IF_TRUE_PEEK) {
            /* Conditional jump. Fast path handles only immediate-num
             * TOS: bail on any other tag so the interpreter can apply
             * the full slot_truthy rules. Layout:
             *   load TOS -> %rax
             *   type-check (bail if not immediate-num)
             *   [non-PEEK only] dec %ecx          ; pop
             *   btr $63, %rax                     ; clear sign bit
             *   test %rax, %rax                   ; ZF=1 iff ±0.0
             *   jne/je skip_taken                 ; falsy/truthy → skip
             *   mov $target, %r13d                ; advance writeback
             *   jmp <target or epilogue>          ; pending patch
             *  skip_taken:
             *
             * For JIF_*  (jump on falsy): take when ZF=1; skip when ZF=0 → jne
             * For JIT_*  (jump on truthy): take when ZF=0; skip when ZF=1 → je
             *
             * Type check fires before the pop, so the stack/IC state on
             * bail matches the interpreter's view at the start of the
             * op (r13d still holds the op's own bytecode offset). */
            if (bail_count + 1 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0]) ||
                pending_count + 1 > (int)(sizeof pending /
                                          sizeof pending[0])) {
                JIT_BAIL_AND_RETURN();
            }
            int is_peek = (op == OP_JUMP_IF_FALSE_PEEK ||
                           op == OP_JUMP_IF_TRUE_PEEK);
            int take_on_falsy = (op == OP_JUMP_IF_FALSE ||
                                 op == OP_JUMP_IF_FALSE_PEEK);
            uint16_t off = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            int target = i + 3 + (int)off;

            uint8_t *p_t;
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            w = emit_immediate_num_check_rax(w, &p_t);
            bail_patches[bail_count++] = p_t;
            if (!is_peek) w = emit_dec_ecx(w);
            w = emit_btr_63_rax(w);
            w = emit_test_rax_rax(w);

            uint8_t *skip_patch;
            if (take_on_falsy) {
                /* Take when ZF=1; skip taken-arm when ZF=0. */
                w = emit_jne_rel32(w, &skip_patch);
            } else {
                /* Take when ZF=0; skip taken-arm when ZF=1. */
                w = emit_je_rel32(w, &skip_patch);
            }
            /* Taken arm. Same entry-relative encoding as OP_JUMP above. */
            w = emit_mov_imm32_r13d(w, (uint32_t)(target - entry_offset));
            uint8_t *jump_patch;
            w = emit_jmp_rel32(w, &jump_patch);
            pending[pending_count].target = target;
            pending[pending_count].patch = jump_patch;
            pending_count++;
            /* skip_taken: */
            patch_rel32(skip_patch, w);
            i += 3;
        } else if (op == OP_ITER_NEXT) {
            /* Stage 4q-a: ITER_NEXT via helper call.
             *
             * Layout:
             *   mov %ecx -> g_vm.sp     ; sync our sp cache so helper sees it
             *   push %rcx                ; align (body at 8-mod-16 -> 0-mod-16)
             *   movabs &jit_helper_iter_next, %rax
             *   call %rax                ; eax = 0 (pushed) / 1 (exhausted)
             *   pop %rcx                 ; (junk, will be reloaded)
             *   mov g_vm.sp -> %ecx      ; reload — helper may have pushed
             *   test %eax, %eax
             *   jz skip_taken            ; fall-through when not exhausted
             *   mov $(exit_target - entry_offset), %r13d
             *   jmp <pending patch>      ; resolved later (native or epilogue)
             *  skip_taken:
             *
             * Same pending-patch bookkeeping as OP_JUMP_IF_FALSE. */
            if (pending_count + 1 > (int)(sizeof pending /
                                          sizeof pending[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint16_t off = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            int target = i + 3 + (int)off;

            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_iter_next);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            w = emit_test_rax_rax(w);

            uint8_t *skip_patch;
            /* Take when ZF=0 (exhausted, eax != 0); skip taken arm when
             * ZF=1 (continue, eax == 0). */
            w = emit_je_rel32(w, &skip_patch);
            /* Taken arm: write target into r13d and jump. */
            w = emit_mov_imm32_r13d(w, (uint32_t)(target - entry_offset));
            uint8_t *jump_patch;
            w = emit_jmp_rel32(w, &jump_patch);
            pending[pending_count].target = target;
            pending[pending_count].patch = jump_patch;
            pending_count++;
            /* skip_taken: */
            patch_rel32(skip_patch, w);
            i += 3;
        } else if (op == OP_INDEX_GET) {
            /* Stage 4q-c: INDEX_GET via helper call.
             *
             * Helper pops 2 slots, pushes 1 (net sp -1), reads sp from
             * g_vm.sp directly. Layout matches the ITER_NEXT call ABI:
             *
             *   mov %ecx -> g_vm.sp     ; sync sp cache
             *   push %rcx                ; align (body at 8-mod-16 -> 0-mod-16)
             *   movabs &jit_helper_index_get, %rax
             *   call %rax
             *   pop %rcx                 ; (junk, will be reloaded)
             *   mov g_vm.sp -> %ecx      ; reload — helper mutated sp
             *
             * No return value to test — helper handles errors via
             * runtime_error, picked up by CHECK_ERROR after the thunk
             * returns. */
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_index_get);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            i += 1;
        } else if (op == OP_CALL) {
            /* Stage 4r: OP_CALL with builtin-only fast path via helper.
             *
             *   mov $op_start - entry_offset, %r13d   ; pre-set bail advance
             *   mov %ecx -> g_vm.sp                    ; sync sp cache
             *   mov $argc, %edi                        ; arg to helper
             *   push %rcx                              ; align 8 -> 0 mod 16
             *   movabs &jit_helper_call, %rax
             *   call %rax                              ; eax = 0 (continue) / 1 (bail)
             *   pop %rcx                               ; (junk, will be reloaded)
             *   mov g_vm.sp -> %ecx                    ; reload (helper may have pushed)
             *   test %eax, %eax
             *   jne -> epilogue                        ; bail; r13d already at op_start
             *
             * On success (eax==0) the loop-tail post-op writeback at
             * the bottom of this body overwrites %r13d with i (=
             * op_start + 3), so the resume-after-thunk path lands past
             * this CALL. On bail, the existing pre-set %r13d carries
             * the interpreter back to OP_CALL itself.
             *
             * r13 is callee-saved in SysV, so the pre-set survives the
             * helper call. */
            if (bail_count + 1 > (int)(sizeof bail_patches /
                                       sizeof bail_patches[0])) {
                JIT_BAIL_AND_RETURN();
            }
            uint16_t argc = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_mov_imm32_r13d(w, (uint32_t)(op_start - entry_offset));
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_mov_imm32_edi(w, (uint32_t)argc);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_call);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            w = emit_test_rax_rax(w);
            uint8_t *p_bail;
            w = emit_jne_rel32(w, &p_bail);
            bail_patches[bail_count++] = p_bail;
            i += 3;
        } else if (op == OP_RETURN) {
            /* Stage 4s: OP_RETURN via helper.
             *
             *   mov $-1, %r13d                      ; sentinel for vm_run
             *   mov %ecx -> g_vm.sp                 ; sync sp cache
             *   push %rcx                           ; 16-byte align
             *   movabs &jit_helper_return, %rax
             *   call %rax                           ; void, always OK
             *   pop %rcx
             *   mov g_vm.sp -> %ecx                 ; reload (helper pushed)
             *
             * skip_post_op_advance suppresses the loop-tail writeback
             * so the -1 sentinel survives to the epilogue. The scanner
             * already broke out of the loop after OP_RETURN, so there
             * are no following ops in this thunk anyway — but the
             * suppression is the load-bearing thing: without it, the
             * post-op writeback would overwrite %r13d with `i -
             * entry_offset` and the sentinel would be lost.
             *
             * No jne_bail: the helper is void and always succeeds.
             * Control falls through to the epilogue naturally (since
             * the scanner broke at OP_RETURN, the for-loop exits and
             * the epilogue is the next thing the writer emits). */
            w = emit_mov_imm32_r13d(w, (uint32_t)-1);
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_return);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            skip_post_op_advance = 1;
            i += 1;
        } else if (op == OP_RETURN_NULL) {
            /* Stage 4t: OP_RETURN_NULL — same call sequence as OP_RETURN
             * but routes to the null-pushing helper. The -1 sentinel
             * still lands in chunk->jit_advance and vm_run's post-thunk
             * code does the same frame/ip resync (or top-level return
             * via slot_null → make_null). */
            w = emit_mov_imm32_r13d(w, (uint32_t)-1);
            w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
            w = emit_push_rcx(w);
            w = emit_movabs_rax(w, (uint64_t)(uintptr_t)&jit_helper_return_null);
            w = emit_call_rax(w);
            w = emit_pop_rcx(w);
            w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);
            skip_post_op_advance = 1;
            i += 1;
        } else if (op == OP_POP) {
            if (last_imm) {
                /* Peephole: prior op pushed an immediate, whose slot_decref
                 * is a no-op. Just dec the cached sp. */
                w = emit_dec_ecx(w);
            } else {
                /* Non-immediate TOS — slot may hold a heap/tracked Value
                 * whose refcount must be decremented (and freed at zero).
                 *
                 * Sequence:
                 *   mov  stack[sp-1], %rax
                 *   mov  %rax, %rsi          ; conditional_decref reads %rsi
                 *   dec  %ecx                ; pop (sp-- in cache)
                 *   emit_conditional_decref_rsi
                 *
                 * The decref helper does its own %rcx preservation
                 * around the free_value call, so the %ecx-cache survives
                 * the call without further setup. */
                w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
                w = emit_mov_rax_rsi(w);
                w = emit_dec_ecx(w);
                int bail = 0;
                w = emit_conditional_decref_rsi(w, &bail);
                if (bail) {
                    JIT_BAIL_AND_RETURN();
                }
            }
            i += 1;
        } else { /* OP_LINE */
            uint16_t line = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_movl_imm_at_disp32_rbx(w, g_layout.off_current_line,
                                            (int32_t)line);
            i += 3;
        }
        /* Update last_imm in lockstep with the scanner's last_push_immediate.
         * Consumed by OP_POP to decide between the `dec %ecx` peephole and
         * the load+conditional_decref path. Any new op added to the scanner
         * must also be handled here. */
        switch (op) {
        case OP_NULL: case OP_NUM_ZERO: case OP_NUM_ONE:
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_DIV: case OP_MOD:
        case OP_EQ: case OP_NE: case OP_LT: case OP_GT: case OP_LE: case OP_GE:
        case OP_BAND: case OP_BOR: case OP_BXOR: case OP_SHL: case OP_SHR:
        case OP_NEG: case OP_NOT: case OP_BNOT:
        case OP_JUMP_IF_FALSE_PEEK: case OP_JUMP_IF_TRUE_PEEK:
            last_imm = 1; break;
        case OP_CONST: {
            uint16_t idx = (uint16_t)(chunk->code[op_start + 1] |
                                      ((uint16_t)chunk->code[op_start + 2] << 8));
            Value *v = chunk->constants[idx];
            last_imm = (v && v->type == VAL_NUM && v->obs_age == 0);
            break;
        }
        case OP_LINE:
            /* Pass-through — line markers don't touch the stack. */
            break;
        default:
            last_imm = 0; break;
        }
        /* Update the advance tracker: if the next op bails, the caller
         * will resume at bytecode offset `i` (just past the op we just
         * emitted). Unconditional jumps already wrote r13d=target and
         * the bytes after them are unreachable until a backward branch
         * loops back — emitting another writeback would either be dead
         * code or worse, clobber the target-correct advance value. */
        if (has_bail_op && !skip_post_op_advance) {
            w = emit_mov_imm32_r13d(w, (uint32_t)(i - entry_offset));
        }
    }

    /* Common epilogue. All bail jumps land here. Order:
     *   1. (has_bail_op) write %r13d → chunk->jit_advance via %r14.
     *   2. write %ecx → g_vm.sp.
     *   3. (has_bail_op) pop %r14, %r13.
     *   4. pop %r12, %rbx, ret. */
    uint8_t *epilogue_start = w;
    if (has_bail_op) {
        /* For the from-zero thunk this writes chunk->jit_advance; for the
         * OSR thunk it writes chunk->jit_osr_advance. Caller passes the
         * correct offset via advance_field_offset. */
        w = emit_mov_r13d_to_disp32_r14(w, (int32_t)advance_field_offset);
    }
    w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
    if (has_bail_op) {
        w = emit_pop_r14(w);
        w = emit_pop_r13(w);
    }
    w = emit_u8(w, 0x41); w = emit_u8(w, 0x5C);                 /* pop %r12 */
    w = emit_u8(w, 0x5B);                                       /* pop %rbx */
    w = emit_u8(w, 0xC3);                                       /* ret */

    /* Resolve all bail rel32 jumps to the common epilogue. */
    for (int j = 0; j < bail_count; j++) {
        patch_rel32(bail_patches[j], epilogue_start);
    }

    /* Resolve intra-prefix jump patches. Targets inside the compiled
     * prefix patch to native code; out-of-prefix targets patch to the
     * epilogue so the runtime resumes via jit_advance = target. */
    for (int j = 0; j < pending_count; j++) {
        int t = pending[j].target;
        uint8_t *target_native;
        if (t >= 0 && t < prefix && byte_to_native &&
            byte_to_native[t] >= 0) {
            target_native = code + byte_to_native[t];
        } else {
            target_native = epilogue_start;
        }
        patch_rel32(pending[j].patch, target_native);
    }

    /* Sanity: did we stay within the allocation? */
    if ((size_t)(w - code) > size) {
        /* Catastrophic — we wrote past `used`. Abandon. */
        free(byte_to_native);
        *out_state = 1;
        *out_code = NULL;
        jit_cache_seal(g_jit_cache);
        return;
    }

    if (jit_cache_seal(g_jit_cache) != 0) {
        free(byte_to_native);
        *out_state = 1;
        *out_code = NULL;
        return;
    }

    free(byte_to_native);
    *out_state = 2;
    *out_code = code;
    /* Default advance — number of bytes to advance frame->ip from its
     * entry position (entry_offset) if the thunk runs to completion
     * without writing r13d. For entry_offset == 0 this is just `prefix`. */
    *out_advance = prefix - entry_offset;
    g_jit_compiled_chunks++;
    g_jit_compiled_count++;
    if (getenv("EIGS_JIT_DEBUG")) {
        fprintf(stderr, "[jit] compiled %s: entry=%d prefix=%d bytes (",
                chunk->name ? chunk->name : "?", entry_offset, prefix);
        for (int j = entry_offset; j < prefix; j++)
            fprintf(stderr, " %02x", chunk->code[j]);
        fprintf(stderr, " ) -> %zu bytes native\n", (size_t)(w - code));
        if (getenv("EIGS_JIT_DUMP_NATIVE")) {
            fprintf(stderr, "[jit] native:");
            for (size_t j = 0; j < (size_t)(w - code); j++) {
                if (j % 16 == 0) fprintf(stderr, "\n  ");
                fprintf(stderr, " %02x", code[j]);
            }
            fprintf(stderr, "\n");
        }
    }
#endif
}

/* Public from-zero entry: gating + delegation to the compile helper.
 * Writes results into chunk->jit_{state,code,advance,stop_op}; the
 * native thunk's r13d epilogue stores its advance writeback at
 * offsetof(EigsChunk, jit_advance). */
void jit_try_compile_chunk(struct EigsChunk *chunk) {
    if (!chunk) return;
    if (chunk->jit_state != 0) return;
    /* EIGS_JIT_OFF: hard-disable native compilation. Useful for bisecting
     * suspected JIT bugs against the interpreter. */
    if (getenv("EIGS_JIT_OFF")) {
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        return;
    }
    jit_register_chunk(chunk);
    load_thresholds();
    if (chunk->exec_count   < (uint64_t)g_entry_threshold &&
        chunk->back_edge_count < (uint32_t)g_iter_threshold) return;
    jit_compile_to_thunk(chunk, 0,
                         (int)offsetof(struct EigsChunk, jit_advance),
                         &chunk->jit_state, &chunk->jit_code,
                         &chunk->jit_advance, &chunk->jit_stop_op);
}

/* Public OSR entry: caller has already decided (via back-edge hotness
 * accounting or similar) that this chunk should get a native thunk
 * starting at `entry_offset`. We skip the exec_count/back_edge gating
 * here — the caller's gate is what's load-bearing. We do honor a
 * dedicated EIGS_JIT_OSR_OFF for bisection, plus the global JIT_OFF.
 * Writes results into chunk->jit_osr_*. */
void jit_try_compile_chunk_osr(struct EigsChunk *chunk, int entry_offset) {
    if (!chunk) return;
    if (chunk->jit_osr_state != 0) return;
    if (entry_offset < 0 || entry_offset >= chunk->code_len) {
        chunk->jit_osr_state = 1;
        chunk->jit_osr_code = NULL;
        return;
    }
    if (getenv("EIGS_JIT_OFF") || getenv("EIGS_JIT_OSR_OFF")) {
        chunk->jit_osr_state = 1;
        chunk->jit_osr_code = NULL;
        return;
    }
    jit_register_chunk(chunk);
    chunk->jit_osr_entry_offset = entry_offset;
    jit_compile_to_thunk(chunk, entry_offset,
                         (int)offsetof(struct EigsChunk, jit_osr_advance),
                         &chunk->jit_osr_state, &chunk->jit_osr_code,
                         &chunk->jit_osr_advance, &chunk->jit_osr_stop_op);
}
