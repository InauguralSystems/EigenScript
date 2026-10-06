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
    out->off_thread_exit_scope = offsetof(EigsThread, exit_scope);
    out->off_exit_scope_latched = offsetof(EigsExitScope, latched_storage);
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

/* Receipt-only helper: controlled statuses test the production emitter's
 * call/bailout ABI without running a language error or changing runtime state. */
static struct { int status, calls, bad; } index_receipt;
int jit_helper_local_idx_get(int slot, int idx) {
    VM *vm = eigs_current->vm;
    index_receipt.calls++;
    if (slot != 0 || idx != 0 || vm->sp != 0) index_receipt.bad++;
    vm->stack[vm->sp++] = index_receipt.status ? slot_null() : slot_from_num(42);
    return index_receipt.status;
}

/* Stage 4m: same shape — emitter takes &jit_helper_local_dot_get as an
 * immediate. Smoke binary never invokes the emit path. */
int jit_helper_local_dot_get(struct EigsChunk *chunk, int slot, int name_idx) {
    (void)chunk; (void)slot; (void)name_idx; return 0;
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

/* Controlled reader statuses exercise the production emitter without
 * constructing containers, raising runtime errors, or executing a language
 * program. These receipts cover only the helper-call/exit ABI. */
static struct {
    uint8_t *ip;
    int kind, status, calls, bad;
} reader_receipt;
int jit_helper_iter_next(void) {
    VM *vm = eigs_current->vm;
    reader_receipt.calls++;
    if (reader_receipt.kind != 1 || vm->sp != 1 ||
        SLOT_NUM_RAW(vm->stack[0]) != 0 || vm->frames[0].ip != reader_receipt.ip ||
        vm->current_line != 71)
        reader_receipt.bad++;
    if (reader_receipt.status != 1)
        vm->stack[vm->sp++] = slot_from_num(reader_receipt.status ? 0 : 42);
    return reader_receipt.status;
}
int jit_helper_index_get(void) {
    VM *vm = eigs_current->vm;
    reader_receipt.calls++;
    if (reader_receipt.kind != 0 || vm->sp != 2 ||
        SLOT_NUM_RAW(vm->stack[0]) != 0 || SLOT_NUM_RAW(vm->stack[1]) != 1 ||
        vm->frames[0].ip != reader_receipt.ip || vm->current_line != 71)
        reader_receipt.bad++;
    vm->sp -= 2;
    vm->stack[vm->sp++] = slot_from_num(reader_receipt.status ? 0 : 42);
    return reader_receipt.status;
}
/* Remaining Stage 4q/4v helpers are linker-immediate stubs. */
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
        SLOT_NUM_RAW(g_vm.stack[0]) != 42 || SLOT_NUM_RAW(g_vm.stack[1]) != 0 ||
        SLOT_NUM_RAW(g_vm.stack[2]) != 1 || g_vm.frames[0].ip != store_receipt.ip)
        store_receipt.bad = 1;
    for (int i = 0; i < 3; i++) {
        if (SLOT_NUM_RAW(store_receipt.values[i]) != 10 + i ||
            store_receipt.counts[i] != 17)
            store_receipt.bad = 1;
    }
}
void jit_helper_set_name_local(struct EigsChunk *chunk, int idx) { (void)chunk; (void)idx; }
void jit_helper_set_fn_name_local(struct EigsChunk *chunk, int idx) { (void)chunk; (void)idx; }
void jit_helper_set_local(struct EigsChunk *chunk, int slot) { (void)chunk; (void)slot; }
void jit_helper_local_dot_set(struct EigsChunk *chunk, int slot, int name_idx) {
    (void)chunk; (void)slot; (void)name_idx;
}
void jit_helper_dot_get(struct EigsChunk *chunk, int name_idx) {
    (void)chunk; (void)name_idx;
}
void jit_helper_dot_set(struct EigsChunk *chunk, int name_idx) {
    (void)chunk; (void)name_idx;
}
int jit_helper_local_idx_dot_get(struct EigsChunk *chunk, int slot,
                                 int list_idx, int name_idx) {
    (void)chunk; (void)slot; (void)list_idx; (void)name_idx; return 0;
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
            STORE_ASSERT(SLOT_NUM_RAW(vm->stack[0]) == 42 && SLOT_NUM_RAW(vm->stack[1]) == 0);
            STORE_ASSERT(SLOT_NUM_RAW(vm->stack[2]) == 1);
            STORE_ASSERT(vm->frames[0].ip == store_receipt.ip);
            STORE_ASSERT((osr ? chunk.jit_osr[0].advance : chunk.jit_advance) == 5);
            STORE_ASSERT((osr ? chunk.jit_advance : chunk.jit_osr[0].advance) == -99);
            STORE_ASSERT(state->builtin_env == &env[2]);
            for (int i = 0; i < 3; i++) {
                int stored = !cases[c].helper && i == target;
                STORE_ASSERT(SLOT_NUM_RAW(values[i]) == (stored ? 1 : 10 + i));
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

/* This prefix contains no other bailout opcode. Entry and OSR therefore
 * cannot inherit r13 preservation/writeback from RETURN or arithmetic. */
static int run_index_bail_cases(void) {
#if EIGS_JIT_ENABLED
    int rc = 0, rows = 0;
    EigsState *state = calloc(1, sizeof *state);
    EigsThread *thread = calloc(1, sizeof *thread);
    VM *vm = calloc(1, sizeof *vm);
    if (!state || !thread || !vm) {
        fprintf(stderr, "FAIL: index-bail fixture allocation\n");
        free(vm); free(thread); free(state);
        return 1;
    }
    thread->state = state;
    thread->vm = vm;
    vm->owner = thread;
    eigs_current = thread;
    state->jit_entry_threshold = state->jit_iter_threshold = 1;
    /* The balanced pair after offset 2 keeps the OSR prefix above the
     * scanner's three-operation minimum without introducing a bailout. */
    uint8_t code[] = {OP_NULL, OP_POP, OP_NULL, OP_POP,
                      OP_LOCAL_IDX_GET, 0, 0, 0, 0, OP_NUM_ONE};
    EigsChunk chunk = {0};
    chunk.code = code;
    chunk.code_len = sizeof code;
    chunk.local_count = 1;
    chunk.exec_count = 1;
    for (int osr = 0; osr < 2; osr++) {
        if (osr) jit_try_compile_chunk_osr(&chunk, 2, 0);
        else jit_try_compile_chunk(&chunk);
        void *thunk = osr ? chunk.jit_osr[0].code : chunk.jit_code;
        int compiled = (osr ? chunk.jit_osr[0].state : chunk.jit_state) == 2;
        if (!compiled || !thunk) {
            fprintf(stderr, "FAIL: index-bail %s did not compile\n",
                    osr ? "osr" : "entry");
            rc = 1;
            continue;
        }
        for (int status = 0; status < 2; status++) {
            vm->sp = 0;
            vm->stack[0] = vm->stack[1] = slot_null();
            index_receipt.status = status;
            index_receipt.calls = index_receipt.bad = 0;
            chunk.jit_advance = chunk.jit_osr[0].advance = -99;
            /* A live callee-saved register witnesses the callable ABI.
             * The barriers prevent constant-folding the preservation check. */
            register uint64_t saved_r13 __asm__("r13") = UINT64_C(0x13579bdf2468ace0);
            __asm__ __volatile__("" : "+r"(saved_r13));
            ((JitChunkFn)thunk)();
            __asm__ __volatile__("" : "+r"(saved_r13));
            int advance = osr ? chunk.jit_osr[0].advance : chunk.jit_advance;
            int expected = (int)sizeof code - (status ? 1 : 0) - (osr ? 2 : 0);
            int good = saved_r13 == UINT64_C(0x13579bdf2468ace0) &&
                advance == expected && index_receipt.calls == 1 &&
                index_receipt.bad == 0 && vm->sp == (status ? 1 : 2) &&
                (status ? slot_is_null(vm->stack[0]) :
                          SLOT_NUM_RAW(vm->stack[0]) == 42 && SLOT_NUM_RAW(vm->stack[1]) == 1);
            rows++;
            if (!good) {
                fprintf(stderr, "FAIL: index-bail %s status=%d r13=%" PRIx64
                        " advance=%d/%d sp=%d calls=%d bad=%d\n",
                        osr ? "osr" : "entry", status, saved_r13, advance,
                        expected, vm->sp, index_receipt.calls, index_receipt.bad);
                rc = 1;
            } else {
                printf("ok  index-bail %s status=%d ABI/advance/continuation\n",
                       osr ? "osr" : "entry", status);
            }
        }
    }
    jit_unregister_chunk(&chunk);
    jit_thread_destroy(thread);
    eigs_current = NULL;
    free(vm); free(thread); free(state);
    if (rows != 4) rc = 1;
    if (!rc) printf("Index-bail smoke: 4/4 rows passed.\n");
    return rc;
#else
    printf("Index-bail smoke: SKIP (native JIT unavailable).\n");
    return 0;
#endif
}

/* Each prefix has only its reader as a bailout opcode, including the OSR
 * slice at offset 2. A later LINE and immediate push witness continuation;
 * ITER_NEXT also has an in-prefix exhaustion target distinct from error. */
static int run_reader_bail_cases(void) {
#if EIGS_JIT_ENABLED
    int rc = 0, rows = 0;
    EigsState *state = calloc(1, sizeof *state);
    EigsThread *thread = calloc(1, sizeof *thread);
    VM *vm = calloc(1, sizeof *vm);
    if (!state || !thread || !vm) {
        fprintf(stderr, "FAIL: reader-bail fixture allocation\n");
        free(vm); free(thread); free(state);
        return 1;
    }
    thread->state = state;
    thread->vm = vm;
    vm->owner = thread;
    eigs_current = thread;
    state->jit_entry_threshold = state->jit_iter_threshold = 1;
    uint8_t index_code[] = {OP_NULL, OP_POP, OP_NULL, OP_POP,
        OP_NUM_ZERO, OP_NUM_ONE, OP_INDEX_GET,
        OP_LINE, 72, 0, 0, 0, OP_NUM_ONE};
    uint8_t iter_code[] = {OP_NULL, OP_POP, OP_NULL, OP_POP,
        OP_NUM_ZERO, OP_ITER_NEXT, 6, 0,
        OP_LINE, 72, 0, 0, 0, OP_NUM_ONE, OP_NUM_ZERO};
    for (int kind = 0; kind < 2; kind++) {
        EigsChunk chunk = {0};
        chunk.code = kind ? iter_code : index_code;
        chunk.code_len = kind ? sizeof iter_code : sizeof index_code;
        chunk.exec_count = 1;
        const char *name = kind ? "iter" : "dynamic-index";
        for (int osr = 0; osr < 2; osr++) {
            if (osr) jit_try_compile_chunk_osr(&chunk, 2, 0);
            else jit_try_compile_chunk(&chunk);
            void *thunk = osr ? chunk.jit_osr[0].code : chunk.jit_code;
            int compiled = (osr ? chunk.jit_osr[0].state : chunk.jit_state) == 2;
            if (!compiled || !thunk) {
                fprintf(stderr, "FAIL: reader-bail %s/%s did not compile\n",
                        name, osr ? "osr" : "entry");
                rc = 1;
                continue;
            }
            for (int status = 0; status < (kind ? 3 : 2); status++) {
                vm->sp = 0;
                for (int k = 0; k < 4; k++) vm->stack[k] = slot_null();
                vm->frame_count = 1;
                vm->frames[0].chunk = &chunk;
                vm->frames[0].ip = chunk.code + (osr ? 2 : 0);
                vm->current_line = g_trace_current_line_smoke = 71;
                reader_receipt.ip = vm->frames[0].ip;
                reader_receipt.kind = kind;
                reader_receipt.status = status;
                reader_receipt.calls = reader_receipt.bad = 0;
                chunk.jit_advance = chunk.jit_osr[0].advance = -99;
                register uint64_t saved_r13 __asm__("r13") = UINT64_C(0x13579bdf2468ace0);
                __asm__ __volatile__("" : "+r"(saved_r13));
                ((JitChunkFn)thunk)();
                __asm__ __volatile__("" : "+r"(saved_r13));
                int raised = status == (kind ? 2 : 1);
                int expected = (raised ? (kind ? 8 : 7) : chunk.code_len) -
                               (osr ? 2 : 0);
                int advance = osr ? chunk.jit_osr[0].advance : chunk.jit_advance;
                int expected_sp = kind ? (status ? 2 : 4) : (status ? 1 : 2);
                int expected_line = status ? 71 : 72;
                int stack_ok = kind
                    ? SLOT_NUM_RAW(vm->stack[0]) == 0 &&
                      (status ? SLOT_NUM_RAW(vm->stack[1]) == 0 :
                       SLOT_NUM_RAW(vm->stack[1]) == 42 && SLOT_NUM_RAW(vm->stack[2]) == 1 &&
                       SLOT_NUM_RAW(vm->stack[3]) == 0)
                    : (status ? SLOT_NUM_RAW(vm->stack[0]) == 0 :
                       SLOT_NUM_RAW(vm->stack[0]) == 42 && SLOT_NUM_RAW(vm->stack[1]) == 1);
                int good = saved_r13 == UINT64_C(0x13579bdf2468ace0) &&
                    advance == expected && reader_receipt.calls == 1 &&
                    reader_receipt.bad == 0 && vm->sp == expected_sp && stack_ok &&
                    vm->frame_count == 1 && vm->frames[0].chunk == &chunk &&
                    vm->frames[0].ip == reader_receipt.ip &&
                    vm->current_line == expected_line &&
                    g_trace_current_line_smoke == expected_line;
                rows++;
                if (!good) {
                    fprintf(stderr, "FAIL: reader-bail %s/%s status=%d r13=%" PRIx64
                            " advance=%d/%d sp=%d/%d line=%d/%d calls=%d bad=%d\n",
                            name, osr ? "osr" : "entry", status, saved_r13,
                            advance, expected, vm->sp, expected_sp, vm->current_line,
                            expected_line, reader_receipt.calls, reader_receipt.bad);
                    rc = 1;
                } else {
                    printf("ok  reader-bail %s/%s status=%d ABI/advance/frame/line/continuation\n",
                           name, osr ? "osr" : "entry", status);
                }
            }
        }
        jit_unregister_chunk(&chunk);
    }
    jit_thread_destroy(thread);
    eigs_current = NULL;
    free(vm); free(thread); free(state);
    if (rows != 10) rc = 1;
    if (!rc) printf("Reader-bail smoke: 10/10 rows passed.\n");
    return rc;
#else
    printf("Reader-bail smoke: SKIP (native JIT unavailable).\n");
    return 0;
#endif
}

/* A four-iteration stack-only loop executes the real production emitter in
 * both entry and OSR mode. A stopped scope must bail at the FIRST back-edge;
 * removing that poll still terminates after four iterations and fails the
 * value/advance assertions, without a timing race or an unbounded loop. The
 * state's default and the executing thread's scope deliberately disagree.
 * The OSR entry includes NULL/POP before the tested INNER loop header: the
 * scanner hands a back-edge targeting the OSR entry to the interpreter, so
 * testing that boundary would not exercise an emitted back-edge at all. */
static int run_exit_cases(void) {
    int rc = 0, rows = 0, bailed = 0, completed = 0;
    EigsState *state = calloc(1, sizeof *state);
    EigsThread *thread = calloc(1, sizeof *thread);
    VM *vm = calloc(1, sizeof *vm);
    if (!state || !thread || !vm) {
        free(state); free(thread); free(vm);
        fprintf(stderr, "FAIL native_exit allocation\n");
        return 1;
    }
    EigsExitScope open = {.refs = 1}, stopped = {.refs = 1, .latched_storage = 1, .code = 5};
    thread->state = state;
    thread->vm = vm;
    vm->owner = thread;
    eigs_current = thread;
    state->jit_entry_threshold = state->jit_iter_threshold = 1;
    Value limit = {.type = VAL_NUM};
    VAL_NUM_RAW(&limit) = 4;
    Value *constants[] = {&limit};
    uint8_t code[] = {OP_NULL, OP_POP, OP_NULL, OP_POP,
                      OP_NUM_ONE, OP_ADD, OP_DUP, OP_CONST, 0, 0,
                      OP_LT, OP_JUMP_IF_FALSE, 3, 0, OP_JUMP_BACK, 13, 0};
    EigsChunk chunk = {0};
    chunk.constants = constants;
    chunk.const_count = 1;
    chunk.exec_count = 1;
    for (int osr = 0; osr < 2; osr++) {
        chunk.code = code + (osr ? 0 : 4);
        chunk.code_len = osr ? sizeof code : sizeof code - 4;
        int entry = osr ? 2 : 0;
        if (osr) jit_try_compile_chunk_osr(&chunk, entry, 0);
        else jit_try_compile_chunk(&chunk);
        void *thunk = osr ? chunk.jit_osr[0].code : chunk.jit_code;
        if (!thunk || (osr ? chunk.jit_osr[0].state : chunk.jit_state) != 2) {
            fprintf(stderr, "FAIL native_exit %s did not compile\n", osr ? "osr" : "entry");
            rc = 1;
            continue;
        }
        for (int row = 0; row < 3; row++) {
            int stop = row == 1;
            thread->exit_scope = stop ? &stopped : &open;
            state->exit_scope = row == 2 ? &stopped : &open;
            vm->sp = vm->frame_count = 1;
            vm->stack[0] = slot_from_num(0);
            vm->frames[0].chunk = &chunk;
            vm->frames[0].ip = chunk.code + entry;
            chunk.jit_advance = chunk.jit_osr[0].advance = -99;
            ((JitChunkFn)thunk)();
            rows++;
            int advance = osr ? chunk.jit_osr[0].advance : chunk.jit_advance;
            int other = osr ? chunk.jit_advance : chunk.jit_osr[0].advance;
            int want_advance = (stop ? 10 : 13) + (osr ? 2 : 0);
            int ok = vm->sp == 1 && SLOT_NUM_RAW(vm->stack[0]) == (stop ? 1 : 4) &&
                     advance == want_advance && other == -99 &&
                     vm->frames[0].ip == chunk.code + entry;
            if (!ok) {
                fprintf(stderr, "FAIL native_exit %s row=%d sp=%d value=%g advance=%d other=%d\n",
                        osr ? "osr" : "entry", row, vm->sp, SLOT_NUM_RAW(vm->stack[0]), advance, other);
                rc = 1;
            }
            if (ok && stop) bailed++;
            if (ok && !stop) completed++;
        }
    }
    if (rows != 6 || bailed != 2 || completed != 4) rc = 1;
    printf("JIT native_exit: rows=%d backedge=%d completed=%d status=%s\n",
           rows, bailed, completed, rc ? "FAIL" : "PASS");
    jit_unregister_chunk(&chunk);
    jit_thread_destroy(thread);
    eigs_current = NULL;
    free(vm); free(thread); free(state);
    return rc;
}

/* #1637: the bool emitters, read off the native stack. Every comparison and
 * NOT pushes the TAG_BOOL slot bits (never 0.0/1.0), NOT flips a bool, and
 * JUMP_IF_FALSE decides on a bool without bailing — so the thunk must run to
 * the end of the chunk (advance == code_len). Removing the JUMP_IF bool arm
 * makes it stop at the first JUMP_IF_FALSE; a comparison emitting numbers
 * fails the slot-bits rows. */
static int run_bool_cases(void) {
    int rc = 0, checked = 0;
    EigsState *state = calloc(1, sizeof *state);
    EigsThread *thread = calloc(1, sizeof *thread);
    VM *vm = calloc(1, sizeof *vm);
    if (!state || !thread || !vm) {
        free(state); free(thread); free(vm);
        fprintf(stderr, "FAIL bool allocation\n");
        return 1;
    }
    EigsExitScope open = {.refs = 1};
    thread->state = state;
    thread->vm = vm;
    vm->owner = thread;
    eigs_current = thread;
    thread->exit_scope = state->exit_scope = &open;
    uint8_t code[] = {
        OP_TRUE, OP_NOT,                         /* false */
        OP_FALSE, OP_NOT,                        /* true  */
        OP_NUM_ZERO, OP_NOT,                     /* true  */
        OP_NUM_ONE, OP_NUM_ZERO, OP_LT,          /* 1 < 0: false */
        OP_NUM_ZERO, OP_NUM_ONE, OP_LT,          /* 0 < 1: true  */
        OP_TRUE, OP_JUMP_IF_FALSE, 1, 0, OP_NUM_ONE,   /* not taken: push 1 */
        OP_FALSE, OP_JUMP_IF_FALSE, 1, 0, OP_NUM_ZERO, /* taken: skip */
    };
    const uint64_t want[] = {SLOT_FALSE_BITS, SLOT_TRUE_BITS, SLOT_TRUE_BITS,
                             SLOT_FALSE_BITS, SLOT_TRUE_BITS, 0x3FF0000000000000ULL};
    const int nwant = (int)(sizeof want / sizeof want[0]);
    EigsChunk chunk = {0};
    chunk.code = code;
    chunk.code_len = sizeof code;
    chunk.exec_count = 1;
    jit_try_compile_chunk(&chunk);
    if (!chunk.jit_code || chunk.jit_state != 2) {
        fprintf(stderr, "FAIL bool: chunk did not compile\n");
        rc = 1;
    } else {
        vm->sp = 1;
        vm->stack[0] = slot_null();
        vm->frame_count = 1;
        vm->frames[0].chunk = &chunk;
        vm->frames[0].ip = chunk.code;
        chunk.jit_advance = -99;
        ((JitChunkFn)chunk.jit_code)();
        if (chunk.jit_advance != (int)sizeof code || vm->sp != 1 + nwant) {
            fprintf(stderr, "FAIL bool: advance=%d (want %d) sp=%d (want %d)\n",
                    chunk.jit_advance, (int)sizeof code, vm->sp, 1 + nwant);
            rc = 1;
        } else {
            for (int k = 0; k < nwant; k++) {
                checked++;
                if (vm->stack[1 + k].u != want[k]) {
                    fprintf(stderr, "FAIL bool: slot %d = %016llx, want %016llx\n", k,
                            (unsigned long long)vm->stack[1 + k].u,
                            (unsigned long long)want[k]);
                    rc = 1;
                }
            }
        }
    }
    if (checked != nwant) rc = 1;
    printf("JIT bool: slots=%d/%d status=%s\n", checked, nwant, rc ? "FAIL" : "PASS");
    jit_unregister_chunk(&chunk);
    jit_thread_destroy(thread);
    eigs_current = NULL;
    free(vm); free(thread); free(state);
    return rc;
}

int main(void) {
    int rc = 0;
    rc |= run_case(42);
    rc |= run_case(-1);
    rc |= run_case(0x0123456789ABCDEFLL);
    rc |= run_case(INT64_MIN);
    rc |= run_case(INT64_MAX);
    rc |= run_store_cases();
    rc |= run_index_bail_cases();
    rc |= run_reader_bail_cases();
    rc |= run_exit_cases();
    rc |= run_bool_cases();
    if (rc == 0) printf("\nJIT smoke: all cases passed.\n");
    return rc;
}
