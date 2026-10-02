/*
 * JIT executable-cache and native EnvIC store smoke tests.
 *
 * Allocates a code cache, emits a thunk returning a known int64, seals
 * the cache (RW -> RX), invokes the thunk, and asserts the result. Run
 * directly after `make jit-smoke` to confirm the platform allows
 * executable mmap regions and the chosen calling convention works.
 * Synthetic Env fixtures also execute entry and OSR SET_NAME thunks
 * produced by the production emitter, with receipt-only helper fallback.
 */
#include "jit.h"
#include "eigenscript.h"
#include "vm.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Use the real public layouts and this executable's TLS offset. Dict
 * emitters are not exercised here, so their private cache stays disabled. */
void eigs_jit_get_layout(EigsJitLayout *out) {
    memset(out, 0, sizeof *out);
    out->off_thread_vm = offsetof(EigsThread, vm);
    out->off_thread_unobserved_depth = offsetof(EigsThread, unobserved_depth);
    out->off_vm_owner = offsetof(VM, owner);
    out->off_thread_state = offsetof(EigsThread, state);
    out->off_state_obs_needed = offsetof(EigsState, obs_needed);
    out->off_sp = offsetof(VM, sp);
    out->off_stack = offsetof(VM, stack);
    out->off_frame_count = offsetof(VM, frame_count);
    out->off_frames = offsetof(VM, frames);
    out->off_current_line = offsetof(VM, current_line);
    out->off_callframe_ip = offsetof(CallFrame, ip);
    out->off_callframe_fn_env = offsetof(CallFrame, fn_env);
    out->sizeof_callframe = sizeof(CallFrame);
    out->off_env_values = offsetof(Env, values);
    out->off_env_count = offsetof(Env, count);
#if defined(__x86_64__) && !defined(__APPLE__)
    void *tp;
    __asm__ __volatile__("mov %%fs:0, %0" : "=r"(tp));
    out->eigs_current_tpoff = (long)((char *)&eigs_current - (char *)tp);
#endif
}

/* Darwin/Mach-O TLV-aware prologue helper for the synthetic thread. */
void *eigs_jit_load_eigs_current(void) { return eigs_current; }

/* Phase 5: jit_module_shutdown reads eigs_current to decide whether
 * to flush stats — the fixture clears it after destroying its cache. */
__thread EigsThread *eigs_current = NULL;

/* Stage 4c references &free_value as an immediate in the decref emitter,
 * so the linker needs a definition. All fixture values are immediate,
 * so neither this stub nor the possible-root hook is invoked. */
void free_value(Value *v) { (void)v; }
/* #728: the decref tail also bakes &gc_note_possible_root (the #307
 * possible-cycle-root hook arm). Lives in eigenscript.c for real. */
void gc_note_possible_root(Value *v) { (void)v; }

/* Stage 5b references &g_trace_hist as an immediate in the SET-name
 * inline trace gate. Lives in trace.c in the real binary. */
int g_trace_hist_storage = 0;
int g_trace_obs_hist_storage = 0;   /* #972: emit_obs_gate_test bakes its address */
/* OP_LINE asks trace.c for the current thread's flat stamp address. */
static int g_trace_current_line_smoke = 0;
int *trace_current_line_addr(void) { return &g_trace_current_line_smoke; }
int g_trace_enabled_storage = 0;
void trace_line(int line) { (void)line; }
/* #410: the back-edge abort poll bakes &g_vm_abort_flag (vm.c). Never NULL
 * there; the smoke stub mirrors the sentinel shape. */
static volatile int g_smoke_abort_never = 0;
volatile int *g_vm_abort_flag = &g_smoke_abort_never;

/* Stage 5d computes the dict-cache hash at compile time via
 * env_hash_name (eigenscript.c). The smoke binary never reaches the
 * LOCAL_DOT emitters, but the linker needs a definition. */
#include <stdint.h>
uint32_t env_hash_name(const char *name) { (void)name; return 0; }

/* Diagnostic histogram in jit_module_shutdown references op_name from
 * chunk.c. The smoke binary never triggers the histogram path because
 * EIGS_JIT_STOPS is not set, but the linker still needs a definition. */
const char *op_name(uint8_t op) { (void)op; return "?"; }

/* Stage 4k references &jit_helper_get_name as an immediate in the
 * OP_GET_NAME emitter. Smoke test never invokes that emitter, but
 * the linker needs a definition. */
struct EigsChunk;
void jit_helper_get_name(struct EigsChunk *chunk, int idx) {
    (void)chunk; (void)idx;
}

/* Stage 4l: same shape — emitter takes &jit_helper_local_idx_get as an
 * immediate. Smoke binary never invokes the emit path. */
void jit_helper_local_idx_get(int slot, int idx) {
    (void)slot; (void)idx;
}

/* Stage 4m: same shape — emitter takes &jit_helper_local_dot_get as an
 * immediate. Smoke binary never invokes the emit path. */
void jit_helper_local_dot_get(struct EigsChunk *chunk, int slot, int name_idx) {
    (void)chunk; (void)slot; (void)name_idx;
}

/* Stage 4o: same shape — emitter takes &jit_helper_observe_assign{,_local}
 * as immediates. Smoke binary never invokes those emit paths. */
void jit_helper_observe_assign(struct EigsChunk *chunk, int name_idx) {
    (void)chunk; (void)name_idx;
}
void jit_helper_observe_assign_local(int slot) {
    (void)slot;
}
/* #262 Phase-3 C.2: slot-keyed observer op helpers (linker-immediate stubs). */
void jit_helper_report_slot(int slot) { (void)slot; }
void jit_helper_observe_name_post(struct EigsChunk *chunk, int name_idx) {
    (void)chunk; (void)name_idx;
}

/* Stages 4q-a / 4q-c / 4q-d / 4q-f / 4v: same linker-immediate pattern —
 * jit.c references each helper as a call-site immediate from its emitter
 * for OP_ITER_NEXT / OP_INDEX_GET / OP_LOCAL_DOT_SET / OP_DOT_GET /
 * OP_LOCAL_IDX_DOT_GET. The smoke binary emits none of those opcodes,
 * so these stubs are unreachable. SET_NAME below records actual calls. */
int jit_helper_iter_next(void) { return 1; }
void jit_helper_index_set(void) {}
int jit_helper_loop_stall_check(void) { return 1; }
int jit_helper_loop_cap_check(void) { return 1; }
/* Receipt only: never resolves a name or writes a binding. A helper visit
 * must occur with every synthetic binding still untouched. */
static struct {
    EigsChunk *chunk;
    EigsSlot *values;
    int *counts;
    uint8_t *ip;
    int calls, bad;
} store_receipt;
void jit_helper_set_name(struct EigsChunk *chunk, int idx) {
    store_receipt.calls++;
    if (chunk != store_receipt.chunk || idx != 0 || g_vm.sp != 3 ||
        g_vm.stack[0].d != 42 || g_vm.stack[1].d != 0 ||
        g_vm.stack[2].d != 1 || g_vm.frames[0].ip != store_receipt.ip)
        store_receipt.bad = 1;
    for (int i = 0; i < 3; i++) {
        if (store_receipt.values[i].d != 10 + i ||
            store_receipt.counts[i] != 17)
            store_receipt.bad = 1;
    }
}
void jit_helper_set_name_local(struct EigsChunk *chunk, int idx) { (void)chunk; (void)idx; }
void jit_helper_set_fn_name_local(struct EigsChunk *chunk, int idx) { (void)chunk; (void)idx; }
void jit_helper_set_local(struct EigsChunk *chunk, int slot) { (void)chunk; (void)slot; }
void jit_helper_index_get(void) { }
void jit_helper_local_dot_set(struct EigsChunk *chunk, int slot, int name_idx) {
    (void)chunk; (void)slot; (void)name_idx;
}
void jit_helper_dot_get(struct EigsChunk *chunk, int name_idx) {
    (void)chunk; (void)name_idx;
}
void jit_helper_dot_set(struct EigsChunk *chunk, int name_idx) {
    (void)chunk; (void)name_idx;
}
void jit_helper_local_idx_dot_get(struct EigsChunk *chunk, int slot,
                                  int list_idx, int name_idx) {
    (void)chunk; (void)slot; (void)list_idx; (void)name_idx;
}

/* Stages 4r / 4s / 4t / 5f: OP_CALL / OP_RETURN / OP_RETURN_NULL
 * helpers, same unreachable-stub story. */
int jit_helper_call(struct EigsChunk *chunk, int argc, int resume_off) {
    (void)chunk; (void)argc; (void)resume_off; return 1;
}
void jit_helper_return(void) { }
void jit_helper_return_null(void) { }

/* Stage 4u: jit.c references chunk_disassemble in its EIGS_JIT_DUMP_PREFIX
 * diagnostic path. Smoke binary never sets that env var, so the call is
 * unreachable. */
struct EigsChunk;
void chunk_disassemble(struct EigsChunk *chunk, const char *label) {
    (void)chunk; (void)label;
}

static int run_case(int64_t expected) {
    EigsJitCache *jc = jit_cache_new(1);
    if (!jc) {
        fprintf(stderr, "FAIL: jit_cache_new\n");
        return 1;
    }
    JitConstFn fn = jit_emit_const_return(jc, expected);
    if (!fn) {
        fprintf(stderr, "FAIL: jit_emit_const_return\n");
        jit_cache_free(jc);
        return 1;
    }
    if (jit_cache_seal(jc) != 0) {
        fprintf(stderr, "FAIL: jit_cache_seal\n");
        jit_cache_free(jc);
        return 1;
    }
    int64_t got = fn();
    int rc = 0;
    if (got != expected) {
        fprintf(stderr, "FAIL: expected %" PRId64 ", got %" PRId64 "\n",
                expected, got);
        rc = 1;
    } else {
        printf("ok  const_return(%" PRId64 ") = %" PRId64
               "  [%zu bytes emitted]\n",
               expected, got, jit_cache_used(jc));
    }
    jit_cache_free(jc);
    return rc;
}

static int store_checks;
static int store_assert(int ok, const char *mode, const char *row,
                        const char *expr) {
    store_checks++;
    if (!ok) fprintf(stderr, "FAIL native_store %s/%s assertion: %s\n",
                     mode, row, expr);
    return !ok;
}
#define STORE_ASSERT(expr) \
    (rc |= store_assert((expr), mode, row, #expr))

/* No runtime env construction, builtin registration, or language execution:
 * only inert local Env/IC fixtures drive the actual production emitter. */
static int run_store_cases(void) {
    int rc = 0, rows = 0, native = 0, helpers = 0;
    const char *mode = "setup", *row = "allocation";
    EigsState *state = calloc(1, sizeof *state);
    EigsThread *thread = calloc(1, sizeof *thread);
    VM *vm = calloc(1, sizeof *vm);
    STORE_ASSERT(state && thread && vm);
    if (rc) { free(vm); free(thread); free(state); return rc; }
    thread->state = state;
    thread->vm = vm;
    vm->owner = thread;
    eigs_current = thread;
    state->jit_entry_threshold = 1;
    state->jit_iter_threshold = 1;
    Env env[3] = {{0}}; /* start, ordinary parent, protected inert parent */
    EigsSlot values[3];
    int counts[3];
    for (int i = 0; i < 3; i++) {
        env[i].values = &values[i];
        env[i].assign_counts = &counts[i];
        env[i].count = env[i].capacity = 1;
        env[i].binding_version = 100 + i;
    }
    state->builtin_env = &env[2]; /* constant for both compiled thunks */
    static const struct {
        const char *name;
        int parent, depth, fault, helper;
    } cases[] = {
        {"ordinary",       1, 1, 0, 0},
        {"protected",      2, 1, 0, 1},
        {"ordinary-again", 1, 1, 0, 0},
        {"depth-zero",     2, 0, 0, 0},
        {"null-parent",   -1, 1, 0, 1},
        {"stale-identity", 1, 1, 1, 1},
        {"stale-start",    1, 1, 2, 1},
        {"stale-target",   1, 1, 3, 1},
    };
    uint8_t code[] = {OP_NULL, OP_POP, OP_NUM_ZERO, OP_NUM_ONE,
                      OP_SET_NAME, 0, 0};
    char *names[] = {"inert_slot"};
    EnvIC ic = {0};
    EigsChunk chunk = {0};
    chunk.const_count = 1;
    chunk.const_interns = names;
    chunk.env_ic = &ic;
    chunk.exec_count = 1;
    for (int osr = 0; osr < 2; osr++) {
        mode = osr ? "osr" : "entry";
        row = "compile";
        chunk.code = code + (osr ? 0 : 2);
        chunk.code_len = osr ? sizeof code : sizeof code - 2;
        int entry = osr ? 2 : 0;
        if (osr) jit_try_compile_chunk_osr(&chunk, entry, 0);
        else jit_try_compile_chunk(&chunk);
        void *thunk = osr ? chunk.jit_osr[0].code : chunk.jit_code;
        STORE_ASSERT((osr ? chunk.jit_osr[0].state : chunk.jit_state) == 2);
        STORE_ASSERT(thunk != NULL);
        if (!thunk) break;
        for (size_t c = 0; c < sizeof cases / sizeof cases[0]; c++) {
            row = cases[c].name;
            for (int i = 0; i < 3; i++) {
                values[i] = slot_from_num(10 + i);
                counts[i] = 17;
            }
            env[0].parent = cases[c].parent < 0 ? NULL : &env[cases[c].parent];
            int target = cases[c].depth ? cases[c].parent : 0;
            ic.starting_env = cases[c].fault == 1 ? &env[1] : &env[0];
            ic.starting_ver = env[0].binding_version + (cases[c].fault == 2);
            ic.target_ver = target < 0 ? 0 : env[target].binding_version;
            ic.target_ver += cases[c].fault == 3;
            ic.walk_depth = cases[c].depth;
            ic.slot_idx = 0;
            vm->sp = 1;
            vm->stack[0] = slot_from_num(42);
            vm->stack[1] = vm->stack[2] = slot_null();
            vm->frame_count = 1;
            vm->frames[0].chunk = &chunk;
            vm->frames[0].env = vm->frames[0].fn_env = &env[0];
            vm->frames[0].ip = chunk.code + entry;
            chunk.jit_advance = chunk.jit_osr[0].advance = -99;
            store_receipt.chunk = &chunk;
            store_receipt.values = values;
            store_receipt.counts = counts;
            store_receipt.ip = vm->frames[0].ip;
            store_receipt.calls = store_receipt.bad = 0;
            ((JitChunkFn)thunk)();
            rows++;
            STORE_ASSERT(store_receipt.calls == cases[c].helper);
            STORE_ASSERT(store_receipt.bad == 0);
            STORE_ASSERT(vm->sp == 3);
            STORE_ASSERT(vm->stack[0].d == 42 && vm->stack[1].d == 0);
            STORE_ASSERT(vm->stack[2].d == 1);
            STORE_ASSERT(vm->frames[0].ip == store_receipt.ip);
            STORE_ASSERT((osr ? chunk.jit_osr[0].advance : chunk.jit_advance) == 5);
            STORE_ASSERT((osr ? chunk.jit_advance : chunk.jit_osr[0].advance) == -99);
            STORE_ASSERT(state->builtin_env == &env[2]);
            for (int i = 0; i < 3; i++) {
                int stored = !cases[c].helper && i == target;
                STORE_ASSERT(values[i].d == (stored ? 1 : 10 + i));
                STORE_ASSERT(counts[i] == 17 + stored);
            }
            helpers += store_receipt.calls;
            native += !cases[c].helper && counts[target] == 18;
        }
    }
    row = "population";
    STORE_ASSERT(rows == 16 && native == 6 && helpers == 10);
    printf("JIT native_store: rows=%d native=%d helpers=%d assertions=%d status=%s\n",
           rows, native, helpers, store_checks, rc ? "FAIL" : "PASS");
    jit_unregister_chunk(&chunk);
    jit_thread_destroy(thread);
    eigs_current = NULL;
    memset(&store_receipt, 0, sizeof store_receipt);
    free(vm); free(thread); free(state);
    return rc;
}
#undef STORE_ASSERT

int main(void) {
    int rc = 0;
    rc |= run_case(42);
    rc |= run_case(-1);
    rc |= run_case(0x0123456789ABCDEFLL);
    rc |= run_case(INT64_MIN);
    rc |= run_case(INT64_MAX);
    rc |= run_store_cases();
    if (rc == 0) printf("\nJIT smoke: all cases passed.\n");
    return rc;
}
