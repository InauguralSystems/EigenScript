#include "jit.h"
#include "eigenscript.h"
#include "vm.h"

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
 * *needs_env_cache nonzero if the prefix contains any op that reads or
 * writes fn_env->values[] (OP_GET_LOCAL / OP_SET_LOCAL) — the emitter
 * uses this to decide whether to emit the env-cache slice of the
 * prologue (worth ~25 bytes, paid once).
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
 *   OP_POP                   — peephole `dec %ecx`, valid only when the
 *                              most recent push was an immediate whose
 *                              slot_decref is a no-op. GET_LOCAL/DUP/
 *                              DUP2/SET_LOCAL break the chain (dynamic
 *                              slot type).
 */
static int jit_supported_prefix(const struct EigsChunk *chunk,
                                int *needs_env_cache) {
    int i = 0, ops = 0, non_line_ops = 0;
    int last_good = 0;
    int last_push_immediate = 0;
    *needs_env_cache = 0;
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
            /* SET_LOCAL keeps TOS; type-tracking conservatively reset. */
            last_push_immediate = 0;
        } else if (op == OP_DUP) {
            i += 1; ops++; non_line_ops++;
            /* DUP'd value type unknown statically. */
            last_push_immediate = 0;
        } else if (op == OP_DUP2) {
            i += 1; ops++; non_line_ops++;
            last_push_immediate = 0;
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
 *   prologue 23 (always) + 35 (env-cache extra when needs_env_cache) +
 *   epilogue 10 + 128 bytes/op worst case (OP_SET_LOCAL with both
 *   inline incref/decref plus possible free_value call site). The
 *   caller advances frame->ip by chunk->jit_advance, so the thunk only
 *   writes %ecx back to g_vm.sp before returning. */
static size_t jit_estimate_size(int prefix, int needs_env_cache) {
    return 23 + (needs_env_cache ? 35 : 0) + 10 + 128 * (size_t)prefix;
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
    int prefix = jit_supported_prefix(chunk, &needs_env_cache);
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

    size_t size = jit_estimate_size(prefix, needs_env_cache);
    uint8_t *code = jit_cache_alloc(g_jit_cache, size);
    if (!code) {
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        jit_cache_seal(g_jit_cache);
        return;
    }

    uint8_t *w = code;

    /* Prologue: preserve %rbx + %r12, point %rbx at &g_vm, cache sp.
     *
     * Register allocation across the thunk:
     *   %rbx = &g_vm                 (callee-saved, set once)
     *   %ecx = g_vm.sp               (live, mutates with pushes/pops)
     *   %r12 = current_frame->fn_env->values  (set when needs_env_cache)
     *
     * %rdx/%rdi/%rsi/%rax are scratch for incref/decref logic. */
    w = emit_u8(w, 0x53);                                       /* push %rbx */
    w = emit_u8(w, 0x41); w = emit_u8(w, 0x54);                 /* push %r12 */
    w = emit_load_fs_zero_rbx(w);                               /* mov %fs:0, %rbx */
    w = emit_lea_rbx_disp32_rbx(w, (int32_t)g_layout.g_vm_tpoff);
    w = emit_mov_disp32_rbx_to_ecx(w, g_layout.off_sp);         /* mov sp, %ecx */

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
                chunk->jit_state = 1; chunk->jit_code = NULL;
                jit_cache_seal(g_jit_cache); return;
            }
            w = emit_store_rax_at_stack(w, g_layout.off_stack);
            w = emit_inc_ecx(w);
            /* Copy stack[sp-2] (which was stack[sp-1] before inc) ->
             * stack[sp] (which is stack[sp+1] in original coords). */
            w = emit_load_stack_to_rax(w, g_layout.off_stack - 16);
            w = emit_conditional_incref_rax(w, &bail);
            if (bail) {
                chunk->jit_state = 1; chunk->jit_code = NULL;
                jit_cache_seal(g_jit_cache); return;
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
                chunk->jit_state = 1; chunk->jit_code = NULL;
                jit_cache_seal(g_jit_cache); return;
            }
            /* Decref old (%rsi). Note: bounds check on slot < e->count
             * is omitted — compiler-emitted bytecode never overruns. */
            w = emit_conditional_decref_rsi(w, &bail);
            if (bail) {
                chunk->jit_state = 1; chunk->jit_code = NULL;
                jit_cache_seal(g_jit_cache); return;
            }
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
    }

    /* Epilogue (10 bytes): write sp back to g_vm, restore %r12 + %rbx,
     * return. frame->ip advance is the caller's responsibility. */
    w = emit_mov_ecx_to_disp32_rbx(w, g_layout.off_sp);
    w = emit_u8(w, 0x41); w = emit_u8(w, 0x5C);                 /* pop %r12 */
    w = emit_u8(w, 0x5B);                                       /* pop %rbx */
    w = emit_u8(w, 0xC3);                                       /* ret */

    /* Sanity: did we stay within the allocation? */
    if ((size_t)(w - code) > size) {
        /* Catastrophic — we wrote past `used`. Abandon. */
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        jit_cache_seal(g_jit_cache);
        return;
    }

    if (jit_cache_seal(g_jit_cache) != 0) {
        chunk->jit_state = 1;
        chunk->jit_code = NULL;
        return;
    }

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
    }
#endif
}
