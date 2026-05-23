#include "jit.h"
#include "eigenscript.h"
#include "vm.h"

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
static int jit_supported_prefix(const struct EigsChunk *chunk,
                                int *needs_env_cache, int *has_bail_op) {
    int i = 0, ops = 0, non_line_ops = 0;
    int last_good = 0;
    int last_push_immediate = 0;
    *needs_env_cache = 0;
    *has_bail_op = 0;
    while (i < chunk->code_len) {
        uint8_t op = chunk->code[i];
        if (op == OP_NULL || op == OP_NUM_ZERO || op == OP_NUM_ONE) {
            i += 1; ops++; non_line_ops++;
            last_push_immediate = 1;
        } else if (op == OP_CONST) {
            if (i + 3 > chunk->code_len) break;
            uint16_t idx = (uint16_t)(chunk->code[i + 1] |
                                      ((uint16_t)chunk->code[i + 2] << 8));
            if (idx >= chunk->const_count) break;
            Value *v = chunk->constants[idx];
            if (!v) break;
            i += 3; ops++; non_line_ops++;
            last_push_immediate = (v->type == VAL_NUM && v->obs_age == 0);
        } else if (op == OP_GET_LOCAL) {
            if (i + 3 > chunk->code_len) break;
            i += 3; ops++; non_line_ops++;
            *needs_env_cache = 1;
            last_push_immediate = 0;
        } else if (op == OP_SET_LOCAL) {
            if (i + 3 > chunk->code_len) break;
            i += 3; ops++; non_line_ops++;
            *needs_env_cache = 1;
            last_push_immediate = 0;
        } else if (op == OP_DUP) {
            i += 1; ops++; non_line_ops++;
            last_push_immediate = 0;
        } else if (op == OP_DUP2) {
            i += 1; ops++; non_line_ops++;
            last_push_immediate = 0;
        } else if (op == OP_ADD || op == OP_SUB ||
                   op == OP_MUL || op == OP_DIV ||
                   op == OP_MOD) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result type at runtime is num (when not bailed), so
             * subsequent OP_POP is still a no-op-decref. */
            last_push_immediate = 1;
        } else if (op == OP_EQ || op == OP_NE || op == OP_LT ||
                   op == OP_GT || op == OP_LE || op == OP_GE) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result is bit-exact 0.0 or 1.0 (an immediate-num), so
             * OP_POP after a comparison remains a no-op peephole. */
            last_push_immediate = 1;
        } else if (op == OP_BAND || op == OP_BOR || op == OP_BXOR ||
                   op == OP_SHL || op == OP_SHR) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Result is a double (whole-number-valued), so a subsequent
             * OP_POP stays a no-op peephole. */
            last_push_immediate = 1;
        } else if (op == OP_NEG || op == OP_NOT || op == OP_BNOT) {
            i += 1; ops++; non_line_ops++;
            *has_bail_op = 1;
            last_push_immediate = 1;
        } else if (op == OP_JUMP || op == OP_JUMP_BACK) {
            if (i + 3 > chunk->code_len) break;
            i += 3; ops++; non_line_ops++;
            /* Uses r13d/r14 machinery to either chain into native code at
             * the target or bail with jit_advance = target. */
            *has_bail_op = 1;
            /* Stack TOS at the jump target is whatever the predecessor
             * left — opaque to this scanner. */
            last_push_immediate = 0;
        } else if (op == OP_JUMP_IF_FALSE || op == OP_JUMP_IF_TRUE) {
            if (i + 3 > chunk->code_len) break;
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* TOS was popped — new TOS is unknown to us. */
            last_push_immediate = 0;
        } else if (op == OP_JUMP_IF_FALSE_PEEK || op == OP_JUMP_IF_TRUE_PEEK) {
            if (i + 3 > chunk->code_len) break;
            i += 3; ops++; non_line_ops++;
            *has_bail_op = 1;
            /* Type-check at runtime proved TOS is immediate-num — so a
             * subsequent OP_POP can use the peephole `dec ecx`. */
            last_push_immediate = 1;
        } else if (op == OP_POP) {
            if (!last_push_immediate) break;
            i += 1; ops++; non_line_ops++;
            last_push_immediate = 0;
        } else if (op == OP_LINE) {
            if (i + 3 > chunk->code_len) break;
            i += 3; ops++;
        } else {
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

void jit_try_compile_chunk(struct EigsChunk *chunk) {
    if (!chunk) return;
    if (chunk->jit_state != 0) return;
    g_jit_scanned_chunks++;
#if !defined(__x86_64__)
    chunk->jit_state = 1;
    chunk->jit_code = NULL;
    return;
#else
    ensure_layout();

    int needs_env_cache = 0;
    int has_bail_op = 0;
    int prefix = jit_supported_prefix(chunk, &needs_env_cache, &has_bail_op);
    if (prefix == 0) {
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        return;
    }

    if (!g_jit_cache) {
        g_jit_cache = jit_cache_new(64); /* 64 pages = 256 KB */
        if (!g_jit_cache) {
            chunk->jit_state = 1;
            chunk->jit_code = NULL;
            return;
        }
    }
    if (jit_cache_unseal(g_jit_cache) != 0) {
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        return;
    }

    size_t size = jit_estimate_size(prefix, needs_env_cache, has_bail_op);
    uint8_t *code = jit_cache_alloc(g_jit_cache, size);
    if (!code) {
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
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
    int *byte_to_native = NULL;
    struct { int target; uint8_t *patch; } pending[256];
    int pending_count = 0;
    if (prefix > 0) {
        byte_to_native = malloc((size_t)prefix * sizeof(int));
        if (!byte_to_native) {
            chunk->jit_state = 1; chunk->jit_code = NULL;
            jit_cache_seal(g_jit_cache); return;
        }
        for (int k = 0; k < prefix; k++) byte_to_native[k] = -1;
    }
    /* Bail-out helper for the compile path so all the seal/free dance
     * stays in one place. */
    #define JIT_BAIL_AND_RETURN() do { \
        free(byte_to_native); \
        chunk->jit_state = 1; chunk->jit_code = NULL; \
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
    int i = 0;
    while (i < prefix) {
        uint8_t op = chunk->code[i];
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
                chunk->jit_state = 1;
                chunk->jit_code = NULL;
                jit_cache_seal(g_jit_cache);
                return;
            }
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            i += 3;
        } else if (op == OP_DUP) {
            /* %rax = stack[sp-1] */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 8);
            int bail = 0;
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                chunk->jit_state = 1;
                chunk->jit_code = NULL;
                jit_cache_seal(g_jit_cache);
                return;
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
            w = emit_mov_imm32_r13d(w, (uint32_t)target);
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
            /* Taken arm. */
            w = emit_mov_imm32_r13d(w, (uint32_t)target);
            uint8_t *jump_patch;
            w = emit_jmp_rel32(w, &jump_patch);
            pending[pending_count].target = target;
            pending[pending_count].patch = jump_patch;
            pending_count++;
            /* skip_taken: */
            patch_rel32(skip_patch, w);
            i += 3;
        } else if (op == OP_POP) {
            /* Peephole: prior op pushed an immediate, whose slot_decref
             * is a no-op. Just dec the cached sp. */
            w = emit_dec_ecx(w);
            i += 1;
        } else { /* OP_LINE */
            uint16_t line = (uint16_t)(chunk->code[i + 1] |
                                       ((uint16_t)chunk->code[i + 2] << 8));
            w = emit_movl_imm_at_disp32_rbx(w, g_layout.off_current_line,
                                            (int32_t)line);
            i += 3;
        }
        /* Update the advance tracker: if the next op bails, the caller
         * will resume at bytecode offset `i` (just past the op we just
         * emitted). Unconditional jumps already wrote r13d=target and
         * the bytes after them are unreachable until a backward branch
         * loops back — emitting another writeback would either be dead
         * code or worse, clobber the target-correct advance value. */
        if (has_bail_op && !skip_post_op_advance) {
            w = emit_mov_imm32_r13d(w, (uint32_t)i);
        }
    }

    /* Common epilogue. All bail jumps land here. Order:
     *   1. (has_bail_op) write %r13d → chunk->jit_advance via %r14.
     *   2. write %ecx → g_vm.sp.
     *   3. (has_bail_op) pop %r14, %r13.
     *   4. pop %r12, %rbx, ret. */
    uint8_t *epilogue_start = w;
    if (has_bail_op) {
        w = emit_mov_r13d_to_disp32_r14(
                w, (int32_t)offsetof(struct EigsChunk, jit_advance));
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
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        jit_cache_seal(g_jit_cache);
        return;
    }

    if (jit_cache_seal(g_jit_cache) != 0) {
        free(byte_to_native);
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        return;
    }

    free(byte_to_native);
    chunk->jit_state = 2;
    chunk->jit_code = code;
    chunk->jit_advance = prefix;
    g_jit_compiled_chunks++;
    if (getenv("EIGS_JIT_DEBUG")) {
        fprintf(stderr, "[jit] compiled %s: prefix=%d bytes (",
                chunk->name ? chunk->name : "?", prefix);
        for (int j = 0; j < prefix; j++)
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
