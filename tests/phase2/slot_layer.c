/* tests/phase2/slot_layer.c -- #1758 R1.1, the C slot test (design 2.5).
 *
 * Nothing in the runtime produces an SMI before R1.3, so no program can show
 * what a slot reader does with one. This test builds SMI slots BY HAND (the
 * literal tag 0xFFFA, never slot_from_int) and drives every slot classifier
 * whose first parameter is an EigsSlot -- the population
 * `tools/phase2_inventory.py --slot-population` derives -- with the SMI
 * boundary values. It includes the single-file amalgamation
 * (tools/amalgamate.sh) so the static classifiers are reachable.
 *
 * Parts:
 *   A  every population entry x every SMI boundary value. An entry either
 *      RETURNS the int's answer (its truthiness, type name, double, digits,
 *      the slot unchanged), or ABORTS through a named refusal: the permanent
 *      ones (eigs_slot_refuse) and the R1.1 placeholders whose int arm needs
 *      the int Value kind (eigs_int_unwired, deleted in R1.3). An abort runs
 *      in a forked child, and its FATAL line must name the expected reader.
 *   B  every population entry x twelve slot kinds: a double, the canonical
 *      NaN, -0.0, null, both bools, an SMI, a heap pointer, the reserved
 *      tags and the sentinel; each cell runs in a forked child.
 *   C  slot_from_int, the one int writer (plant 1's named check, design 9.3):
 *      inside [-2^47, 2^47) the tag is 0xFFFA and the int reads back exactly;
 *      outside, an owned VAL_INT box preserves every int64 bit.
 *   D  the VM's operator arms: a host builtin puts an SMI into a list and a
 *      program applies each operator to it. Every converted arm must compute its exact value,
 *      inside a `try` too; the same program with a double is the control.
 *   E  ITER_NEXT index and snapshot metadata in both executors, with float,
 *      SMI and boxed-int metadata, including range and malformed controls.
 *
 * Output, every line in one grammar (tests/phase2/slot_layer.sh refuses any
 * other line): `ENTRY <file>:<function> <kind> values=<n> ok|FAIL` per Part A
 * entry and `MATRIX <file>:<function> kinds=<n> ok|FAIL` per Part B entry (the
 * runner compares both sets with the derived population, both ways),
 * `ARM <name> ok|FAIL` per Part D arm, `slot-layer-test: FAIL <detail>` lines,
 * then `slot-layer-test: examined=N ... failures=F` and the verdict. Nothing
 * goes to stderr. Exit 0 only for failures == 0 with every part complete. */
#include "eigenscript_all.c"

#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

#ifndef EIGS_SLOT_CHECKS
#error "build with -DEIGS_SLOT_CHECKED (or ASan): slot_as_ptr's refusal is under test"
#endif

static int failures;

/* A child that is EXPECTED to abort must not dump core. On a box whose
 * core_pattern pipes to a crash reporter (Ubuntu's apport), the kernel runs
 * the reporter for every abort, RLIMIT_CORE notwithstanding: about 1.4 s
 * each, which made this test take 224 s instead of seconds. A non-dumpable
 * process skips the core dump entirely; the SIGABRT status is unchanged. */
static void child_no_core(void) {
#ifdef __linux__
    (void)prctl(PR_SET_DUMPABLE, 0, 0, 0, 0);
#endif
}

/* The test's own encoding, independent of value_slot.h's writers. */
#define T_SMI_TAG   0xFFFA000000000000ULL
#define T_PAYLOAD   0x0000FFFFFFFFFFFFULL
static EigsSlot bits(uint64_t u) { EigsSlot s; s.u = u; return s; }
static EigsSlot smi(int64_t v) { return bits(T_SMI_TAG | ((uint64_t)v & T_PAYLOAD)); }
static double f64_of(uint64_t u) { double d; memcpy(&d, &u, sizeof d); return d; }

static const int64_t SMI_VALUES[] = {
    0, 1, -1, (INT64_C(1) << 47) - 1, -(INT64_C(1) << 47),
};
#define N_SMI ((int)(sizeof SMI_VALUES / sizeof SMI_VALUES[0]))

#define FAILF(...) do { printf("slot-layer-test: FAIL "); printf(__VA_ARGS__); printf("\n"); \
                        failures++; } while (0)

/* Run fn(s) in a child; it must die by SIGABRT with a FATAL line naming
 * `who`. Returns 1 when it did. */
static int aborts_naming(void (*fn)(EigsSlot), EigsSlot s, const char *who, const char *what) {
    int p[2];
    if (pipe(p) != 0) { FAILF("%s: pipe", what); return 0; }
    fflush(stdout); fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) { FAILF("%s: fork", what); return 0; }
    if (pid == 0) {
        child_no_core();
        close(p[0]);
        dup2(p[1], 2);
        fn(s);
        _exit(0);                     /* returned: the refusal did not fire */
    }
    close(p[1]);
    char buf[1024];
    size_t n = 0;
    ssize_t r;
    while (n < sizeof buf - 1 && (r = read(p[0], buf + n, sizeof buf - 1 - n)) > 0) n += (size_t)r;
    buf[n] = 0;
    close(p[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    char want[160];
    snprintf(want, sizeof want, "EigenScript FATAL: %s:", who);
    if (WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT && strstr(buf, want)) return 1;
    char *nl = strchr(buf, '\n');
    if (nl) *nl = 0;
    FAILF("%s(0x%016llx): want an abort naming %s; got %s %d, stderr \"%s\"", what,
          (unsigned long long)s.u, who, WIFSIGNALED(st) ? "signal" : "exit",
          WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st), buf);
    return 0;
}

/* ---- Part A: RETURN checks (0 = ok) ------------------------------------ */

static int r_eigs_slot_elem_num(int64_t v) { return eigs_slot_elem_num(smi(v), "slot_layer") != (double)v; }
static int r_eigs_slot_num(int64_t v) { return eigs_slot_num(smi(v), "slot_layer") != (double)v; }
static int r_eigs_slot_opt_num(int64_t v) {
    double d = -7.25;
    return eigs_slot_opt_num(smi(v), &d, "slot_layer") != 1 || d != (double)v;
}
static int r_eigs_slot_store_borrow(int64_t v) { return eigs_slot_store_borrow(smi(v)).u != smi(v).u; }
static int r_eigs_slot_store_owned(int64_t v) { return eigs_slot_store_owned(smi(v)).u != smi(v).u; }
static int r_ent_child_slot(int64_t v) {
    return ent_child_slot(smi(v)) != ent_child_slot(slot_from_f64((double)v));
}
static int r_store_json_encode_slot(int64_t v) {
    strbuf sb;
    strbuf_init(&sb);
    store_json_encode_slot(smi(v), &sb);
    char want[32];
    snprintf(want, sizeof want, "%lld", (long long)v);
    int bad = !sb.data || strcmp(sb.data, want) != 0;
    strbuf_free(&sb);
    return bad;
}
static int r_slot_f64_value(int64_t v) { double d = -7.25; return slot_f64_value(smi(v), &d) != 0 || d != -7.25; }
static int r_slot_int_value(int64_t v) {
    int64_t i = 7;
    if (slot_int_value(smi(v), &i) != 1 || i != v) return 1;
    /* The box arm is independent of SMI range and must not narrow through double. */
    static const int64_t boxed[] = {INT64_MIN, INT64_MAX, INT64_C(9007199254740993)};
    for (size_t n = 0; n < sizeof boxed / sizeof boxed[0]; n++) {
        Value box = {.type = VAL_INT};
        VAL_I64_RAW(&box) = boxed[n];
        i = 7;
        if (!slot_int_value(slot_from_heap(&box), &i) || i != boxed[n]) return 1;
    }
    return 0;
}
static int r_slot_type(int64_t v) { return slot_type(smi(v)) != VAL_INT; }
static int r_slot_view(int64_t v) {
    EIGS_VIEW(view);
    Value *got = slot_view(smi(v), &view);
    return got != &view.v || got->type != VAL_INT || VAL_I64_RAW(got) != v ||
           got->refcount != EIGS_VIEW_RC;
}
static int r_slot_is_f64(int64_t v) { return slot_is_f64(smi(v)) != 0; }
static int r_slot_is_smi(int64_t v) { return slot_is_smi(smi(v)) != 1; }
static int r_slot_smi_val(int64_t v) { return slot_smi_val(smi(v)) != v; }
static int r_slot_truthy_immediate(int64_t v) {
    int decided = -1;
    int t = slot_truthy_immediate(smi(v), &decided);
    return decided != 1 || t != (v != 0);
}
static int r_obs_dump_value(int64_t v) {
    char buf[160], want[32];
    obs_dump_value(smi(v), buf, sizeof buf);
    snprintf(want, sizeof want, "%lld", (long long)v);
    return strcmp(buf, want) != 0;
}
static int r_obs_slot_num(int64_t v) { double d = -7.25; return obs_slot_num(smi(v), &d) != 1 || d != (double)v; }
static int r_slot_truthy(int64_t v) { return slot_truthy(smi(v)) != (v != 0); }
static int r_slot_type_name(int64_t v) { return strcmp(slot_type_name(smi(v)), "num") != 0; }
static int r_slot_decref(int64_t v) { slot_decref(smi(v)); return 0; }   /* no refcount: no-op */
static int r_slot_incref(int64_t v) { slot_incref(smi(v)); return 0; }
static int r_slot_is_bool(int64_t v) { return slot_is_bool(smi(v)) != 0; }
static int r_slot_is_heap(int64_t v) { return slot_is_heap(smi(v)) != 0; }
static int r_slot_is_null(int64_t v) { return slot_is_null(smi(v)) != 0; }
static int r_slot_is_ptr(int64_t v) { return slot_is_ptr(smi(v)) != 0; }

/* ---- Part A: ABORT calls ------------------------------------------------ */

static int r_eigs_slot_box(int64_t v) {
    Value *got = eigs_slot_box(smi(v));
    int bad = !got || got->type != VAL_INT || VAL_I64_RAW(got) != v;
    val_decref(got); return bad;
}
static int r_slot_to_value(int64_t v) {
    Value *got = slot_to_value(smi(v));
    int bad = !got || got->type != VAL_INT || VAL_I64_RAW(got) != v;
    val_decref(got); return bad;
}
static void a_write_slot(EigsSlot s) { write_slot(s); }
static int r_slot_bridge_unwrap(int64_t v) {
    Value *got = slot_bridge_unwrap(smi(v));
    int bad = !got || got->type != VAL_INT || VAL_I64_RAW(got) != v;
    val_decref(got); return bad;
}
static int r_vm_bit_operand(int64_t v) {
    int64_t got = 7; return vm_bit_operand(smi(v), &got) != 1 || got != v;
}
static int r_vm_number_compare(int64_t v) {
    int got = 7; return !vm_number_compare(smi(v), smi(v), &got) || got != 0;
}
static int r_vm_iter_index(int64_t v) {
    int got = 7, valid = v >= INT_MIN && v <= INT_MAX;
    return vm_iter_index(smi(v), &got) != valid || got != (valid ? (int)v : 7);
}
static int r_vm_iter_limit(int64_t v) {
    int want = v < 0 ? 0 : v < 10 ? (int)v : 10;
    return vm_iter_limit(smi(v), 10) != want;
}
static void a_obs_slot_observable(EigsSlot s) { (void)obs_slot_observable(s); }
static void a_eigs_slot_ref(EigsSlot s) { (void)eigs_slot_ref(s); }
static void a_slot_as_ptr(EigsSlot s) { (void)slot_as_ptr(s); }
static void a_obs_slot_value(EigsSlot s) { (void)obs_slot_value(s); }

typedef struct {
    const char *name;                  /* the inventory's file:function */
    int (*ret)(int64_t);               /* returns the int's answer, or */
    void (*abort_call)(EigsSlot);      /* aborts ...                   */
    const char *aborts;                /* ... naming this reader        */
    const char *why;
} Entry;

static const Entry ENTRIES[] = {
    {"vm.c:vm_bit_operand", r_vm_bit_operand, 0, 0, "exact int64 operand"},
    {"vm.c:vm_number_compare", r_vm_number_compare, 0, 0, "exact numeric comparison"},
    {"vm.c:vm_iter_index", r_vm_iter_index, 0, 0, "checked C int metadata"},
    {"vm.c:vm_iter_limit", r_vm_iter_limit, 0, 0, "bounded snapshot"},
    {"container.h:eigs_slot_elem_num", r_eigs_slot_elem_num, 0, 0, "bridge: the int's double"},
    {"container.h:eigs_slot_num", r_eigs_slot_num, 0, 0, "bridge: the int's double"},
    {"container.h:eigs_slot_opt_num", r_eigs_slot_opt_num, 0, 0, "bridge: present, the int's double"},
    {"container.h:eigs_slot_store_borrow", r_eigs_slot_store_borrow, 0, 0, "canonical storage: unchanged"},
    {"container.h:eigs_slot_store_owned", r_eigs_slot_store_owned, 0, 0, "canonical storage: unchanged"},
    {"eigenscript.c:ent_child_slot", r_ent_child_slot, 0, 0, "the entropy of its double"},
    {"ext_store.c:store_json_encode_slot", r_store_json_encode_slot, 0, 0, "exact digits"},
    {"value_slot.h:slot_f64_value", r_slot_f64_value, 0, 0, "not a float: 0, out untouched"},
    {"value_slot.h:slot_int_value", r_slot_int_value, 0, 0, "the int"},
    {"value_slot.h:slot_is_f64", r_slot_is_f64, 0, 0, "0"},
    {"value_slot.h:slot_is_smi", r_slot_is_smi, 0, 0, "1"},
    {"value_slot.h:slot_smi_val", r_slot_smi_val, 0, 0, "the int, sign-extended"},
    {"value_slot.h:slot_truthy_immediate", r_slot_truthy_immediate, 0, 0, "decided: not 0"},
    {"vm.c:obs_dump_value", r_obs_dump_value, 0, 0, "exact digits"},
    {"vm.c:obs_slot_num", r_obs_slot_num, 0, 0, "the numeric channel: the int's double"},
    {"vm.c:slot_truthy", r_slot_truthy, 0, 0, "not 0"},
    {"vm.c:slot_type_name", r_slot_type_name, 0, 0, "\"num\""},
    {"value_slot.h:slot_decref", r_slot_decref, 0, 0, "no refcount"},
    {"value_slot.h:slot_incref", r_slot_incref, 0, 0, "no refcount"},
    {"value_slot.h:slot_is_bool", r_slot_is_bool, 0, 0, "0"},
    {"value_slot.h:slot_is_heap", r_slot_is_heap, 0, 0, "0"},
    {"value_slot.h:slot_is_null", r_slot_is_null, 0, 0, "0"},
    {"value_slot.h:slot_is_ptr", r_slot_is_ptr, 0, 0, "0"},
    {"container.h:eigs_slot_box", r_eigs_slot_box, 0, 0, "exact owned VAL_INT"},
    {"container.h:slot_type", r_slot_type, 0, 0, "VAL_INT"},
    {"container.h:slot_view", r_slot_view, 0, 0, "exact VAL_INT facade"},
    {"eigenscript.c:slot_to_value", r_slot_to_value, 0, 0, "exact owned VAL_INT"},
    {"trace.c:write_slot", 0, a_write_slot, "write_slot", "unwired: tape v7 (R1.3)"},
    {"vm.c:obs_slot_observable", 0, a_obs_slot_observable, "obs_slot_observable", "refuse"},
    {"vm.c:slot_bridge_unwrap", r_slot_bridge_unwrap, 0, 0, "exact owned VAL_INT"},
    {"container.h:eigs_slot_ref", 0, a_eigs_slot_ref, "eigs_slot_ref", "refuse"},
    {"value_slot.h:slot_as_ptr", 0, a_slot_as_ptr, "slot_as_ptr", "refuse (checked builds)"},
    {"vm.c:obs_slot_value", 0, a_obs_slot_value, "slot_as_ptr", "precondition: pointer or bool only"},
};
#define N_ENTRIES ((int)(sizeof ENTRIES / sizeof ENTRIES[0]))

static int part_a(void) {
    int calls = 0;
    for (int i = 0; i < N_ENTRIES; i++) {
        const Entry *e = &ENTRIES[i];
        int bad = 0;
        for (int k = 0; k < N_SMI; k++) {
            int64_t v = SMI_VALUES[k];
            calls++;
            if (e->ret) {
                if (e->ret(v)) { FAILF("%s(SMI %lld): want %s", e->name, (long long)v, e->why); bad++; }
            } else if (!aborts_naming(e->abort_call, smi(v), e->aborts, e->name)) {
                bad++;
            }
        }
        printf("ENTRY %s %s values=%d %s\n", e->name,
               e->ret ? "returns" : e->aborts, N_SMI, bad ? "FAIL" : "ok");
    }
    return calls;
}

/* ---- Part B: every entry against every tag ------------------------------ */

/* The twelve slot kinds: three doubles (an ordinary one, the canonical NaN,
 * -0.0), null, both bools, an SMI, a heap pointer, the three reserved tags
 * and the sentinel. */
enum { K_F, K_NAN, K_NZ, K_NULL, K_FALSE, K_TRUE, K_SMI, K_HEAP, K_R1, K_R2, K_R3, K_SENT, N_KINDS };
static const char *KIND_NAMES[N_KINDS] = {
    "f64 1.5", "f64 canonical NaN", "f64 -0.0", "null", "false", "true", "SMI 5",
    "heap str", "reserved 0xFFFC", "reserved 0xFFFD", "reserved 0xFFFE", "sentinel 0xFFFF",
};
static uint64_t KB[N_KINDS];          /* each kind's slot bits (main fills K_HEAP) */
static Value *g_str;                  /* the heap kind's Value, a string "x" */
static double KD(int k) { return f64_of(KB[k]); }
enum { C_F64, C_NULL, C_BOOL, C_SMI, C_HEAP, C_RES };
static int kclass(int k) {
    switch (k) {
        case K_F: case K_NAN: case K_NZ: return C_F64;
        case K_NULL: return C_NULL;
        case K_FALSE: case K_TRUE: return C_BOOL;
        case K_SMI: return C_SMI;
        case K_HEAP: return C_HEAP;
        default: return C_RES;
    }
}

/* Renderers: every result becomes one comparable token. */
static uint64_t u64_of(double d) { uint64_t u; memcpy(&u, &d, sizeof u); return u; }
static void r_d(char *b, size_t n, double d) { snprintf(b, n, "d:%016llx", (unsigned long long)u64_of(d)); }
static void r_v(char *b, size_t n, Value *v) {
    if (!v) { snprintf(b, n, "v:NULL"); return; }
    if (v == g_str) { snprintf(b, n, "v:H"); return; }
    switch (v->type) {
        case VAL_FLOAT: snprintf(b, n, "v:num:%016llx", (unsigned long long)u64_of(VAL_F64_RAW(v))); return;
        case VAL_INT: snprintf(b, n, "v:int:%lld", (long long)VAL_I64_RAW(v)); return;   /* #1758 R1.2a */
        case VAL_NULL: snprintf(b, n, "v:null"); return;
        case VAL_BOOL: snprintf(b, n, "v:%s", v->data.boolean ? "true" : "false"); return;
        case VAL_STR: case VAL_LIST: case VAL_DICT: case VAL_FN: case VAL_BUILTIN:
        case VAL_BUFFER: case VAL_TEXT_BUILDER:
            snprintf(b, n, "v:%s", val_type_name(v->type)); return;
    }
}
static int is_heap_kind(EigsSlot s) { return s.u == KB[K_HEAP]; }

/* Cells: call one entry and render its result. Each runs in a forked child. */
#define CELL(name) static void c_##name(EigsSlot s, char *b, size_t n)
CELL(elem_num) { r_d(b, n, eigs_slot_elem_num(s, "matrix")); }
CELL(num) { r_d(b, n, eigs_slot_num(s, "matrix")); }
CELL(opt_num) { double d = -7.25; int r = eigs_slot_opt_num(s, &d, "matrix");
                snprintf(b, n, "o:%d d:%016llx", r, (unsigned long long)u64_of(d)); }
CELL(store_borrow) { EigsSlot r = eigs_slot_store_borrow(s); snprintf(b, n, "b:%016llx", (unsigned long long)r.u);
                     if (is_heap_kind(r)) slot_decref(r); }
CELL(store_owned) { if (is_heap_kind(s)) slot_incref(s);
                    EigsSlot r = eigs_slot_store_owned(s); snprintf(b, n, "b:%016llx", (unsigned long long)r.u);
                    if (is_heap_kind(r)) slot_decref(r); }
CELL(ent_child) { r_d(b, n, ent_child_slot(s)); }
CELL(store_json) { strbuf sb; strbuf_init(&sb); store_json_encode_slot(s, &sb);
                   snprintf(b, n, "s:%s", sb.data ? sb.data : ""); strbuf_free(&sb); }
CELL(write_slot) { size_t before = g_out_len; write_slot(s);
                   snprintf(b, n, "w:%.*s", (int)(g_out_len - before), g_out + before); }
CELL(f64_value) { double d = -7.25; int r = slot_f64_value(s, &d);
                  snprintf(b, n, "o:%d d:%016llx", r, (unsigned long long)u64_of(d)); }
CELL(int_value) { int64_t i = 7; int r = slot_int_value(s, &i); snprintf(b, n, "o:%d i:%lld", r, (long long)i); }
CELL(is_f64) { snprintf(b, n, "i:%d", slot_is_f64(s)); }
CELL(is_smi) { snprintf(b, n, "i:%d", slot_is_smi(s)); }
CELL(smi_val) { snprintf(b, n, "i:%lld", (long long)slot_smi_val(s)); }
CELL(truthy_imm) { int dec = -1; int t = slot_truthy_immediate(s, &dec); snprintf(b, n, "o:%d dec:%d", t, dec); }
CELL(dump_value) { char buf[160]; obs_dump_value(s, buf, sizeof buf); snprintf(b, n, "s:%s", buf); }
CELL(obs_num) { double d = -7.25; int r = obs_slot_num(s, &d);
                snprintf(b, n, "o:%d d:%016llx", r, (unsigned long long)u64_of(d)); }
CELL(truthy) { snprintf(b, n, "i:%d", slot_truthy(s)); }
CELL(type_name) { snprintf(b, n, "s:%s", slot_type_name(s)); }
CELL(decref) { if (is_heap_kind(s)) slot_incref(s); slot_decref(s); snprintf(b, n, "ok"); }
CELL(incref) { slot_incref(s); if (is_heap_kind(s)) slot_decref(s); snprintf(b, n, "ok"); }
CELL(is_bool) { snprintf(b, n, "i:%d", slot_is_bool(s)); }
CELL(is_heap) { snprintf(b, n, "i:%d", slot_is_heap(s)); }
CELL(is_null) { snprintf(b, n, "i:%d", slot_is_null(s)); }
CELL(is_ptr) { snprintf(b, n, "i:%d", slot_is_ptr(s)); }
CELL(slot_box) { Value *v = eigs_slot_box(s); r_v(b, n, v); val_decref(v); }
CELL(slot_type) { snprintf(b, n, "t:%s", val_type_name(slot_type(s))); }
CELL(slot_view) { EIGS_VIEW_NOCHECK(view); r_v(b, n, slot_view(s, &view)); }
CELL(to_value) { Value *v = slot_to_value(s); r_v(b, n, v); val_decref(v); }
CELL(observable) { snprintf(b, n, "i:%d", obs_slot_observable(s)); }
CELL(unwrap) { Value *v = slot_bridge_unwrap(s); r_v(b, n, v); if (!slot_is_ptr(s)) val_decref(v); }
CELL(vm_bit_operand) { int64_t i = 7; int r = vm_bit_operand(s, &i); snprintf(b, n, "o:%d i:%lld", r, (long long)i); }
CELL(vm_number_compare) { int cmp = 7; int r = vm_number_compare(s, smi(1), &cmp); snprintf(b, n, "o:%d c:%d", r, cmp); }
CELL(vm_iter_index) { int i = 7; int r = vm_iter_index(s, &i); snprintf(b, n, "o:%d i:%d", r, i); }
CELL(vm_iter_limit) { snprintf(b, n, "i:%d", vm_iter_limit(s, 10)); }
CELL(slot_ref) { r_v(b, n, eigs_slot_ref(s)); }
CELL(as_ptr) { r_v(b, n, slot_as_ptr(s)); }
CELL(obs_value) { r_v(b, n, obs_slot_value(s)); }

/* Expectations: what each entry must do with each kind, written from its
 * contract (container.h, value_slot.h, the 2.5 dispositions). The tokens:
 * `A:<reader>` an abort naming the reader; ` raise` a type error raised. */
#define EXP(name) static void e_##name(int k, char *b, size_t n)
#define ABORT(who) snprintf(b, n, "A:%s", who)
static void e_d(char *b, size_t n, double d, int raise) { r_d(b, n, d); if (raise) strncat(b, " raise", n - strlen(b) - 1); }
static void e_bool(char *b, size_t n, int k) { snprintf(b, n, "v:%s", k == K_TRUE ? "true" : "false"); }
EXP(elem_num) {
    switch (kclass(k)) {
        case C_F64: e_d(b, n, KD(k), 0); break;
        case C_NULL: case C_HEAP: e_d(b, n, 0.0, 0); break;       /* non-strict element read */
        case C_BOOL: e_d(b, n, 0.0, 1); break;                    /* a bool raises (#1637) */
        case C_SMI: e_d(b, n, 5.0, 0); break;
        default: ABORT("eigs_slot_ref");
    }
}
EXP(num) {
    switch (kclass(k)) {
        case C_F64: e_d(b, n, KD(k), 0); break;
        case C_SMI: e_d(b, n, 5.0, 0); break;
        case C_NULL: case C_BOOL: case C_HEAP: e_d(b, n, 0.0, 1); break;   /* required: raises */
        default: ABORT("eigs_slot_ref");
    }
}
EXP(opt_num) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "o:1 d:%016llx", (unsigned long long)KB[k]); break;
        case C_SMI: snprintf(b, n, "o:1 d:%016llx", (unsigned long long)u64_of(5.0)); break;
        case C_NULL: snprintf(b, n, "o:0 d:%016llx", (unsigned long long)u64_of(-7.25)); break;
        case C_BOOL: case C_HEAP: snprintf(b, n, "o:0 d:%016llx raise", (unsigned long long)u64_of(-7.25)); break;
        default: ABORT("eigs_slot_ref");
    }
}
EXP(store_slot) {   /* both normalisers: a double is guarded (NaN -> 0), the rest kept */
    snprintf(b, n, "b:%016llx", (unsigned long long)(k == K_NAN ? 0 : KB[k]));
}
EXP(ent_child) {
    switch (kclass(k)) {
        case C_F64: r_d(b, n, entropy_of_num(KD(k))); break;
        case C_SMI: r_d(b, n, entropy_of_num(5.0)); break;
        case C_NULL: r_d(b, n, compute_entropy_impl(make_null())); break;
        case C_BOOL: r_d(b, n, compute_entropy_impl(make_bool(k == K_TRUE))); break;
        case C_HEAP: r_d(b, n, compute_entropy_impl(g_str)); break;
        default: ABORT("eigs_slot_ref");
    }
}
EXP(store_json) {
    static const char *f64[3] = {"s:1.5", "s:nan", "s:0"};   /* -0.0 takes the %d branch */
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "%s", f64[k]); break;
        case C_NULL: snprintf(b, n, "s:null"); break;
        case C_BOOL: snprintf(b, n, "s:%s", k == K_TRUE ? "true" : "false"); break;
        case C_SMI: snprintf(b, n, "s:5"); break;
        case C_HEAP: snprintf(b, n, "s:\"x\""); break;
        default: ABORT("eigs_slot_ref");
    }
}
static char g_heap_tape[64];         /* what the tape writer prints for g_str */
EXP(write_slot) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "w:%.17g", KD(k)); break;
        case C_NULL: snprintf(b, n, "w:null"); break;
        case C_BOOL: snprintf(b, n, "w:%s", k == K_TRUE ? "true" : "false"); break;
        case C_HEAP: snprintf(b, n, "w:%s", g_heap_tape); break;
        default: ABORT("write_slot");             /* an SMI: tape v7 is R1.3's; a reserved tag refuses */
    }
}
EXP(f64_value) {
    if (kclass(k) == C_F64) snprintf(b, n, "o:1 d:%016llx", (unsigned long long)KB[k]);
    else snprintf(b, n, "o:0 d:%016llx", (unsigned long long)u64_of(-7.25));
}
EXP(int_value) { snprintf(b, n, k == K_SMI ? "o:1 i:5" : "o:0 i:7"); }
EXP(is_f64) { snprintf(b, n, "i:%d", kclass(k) == C_F64); }
EXP(is_smi) { snprintf(b, n, "i:%d", k == K_SMI); }
EXP(smi_val) {   /* the payload, sign-extended from bit 47, by the test's own arithmetic */
    uint64_t p = KB[k] & T_PAYLOAD;
    int64_t v = (p & 0x0000800000000000ULL) ? (int64_t)p - (INT64_C(1) << 48) : (int64_t)p;
    snprintf(b, n, "i:%lld", (long long)v);
}
EXP(truthy_imm) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "o:%d dec:1", KD(k) != 0.0); break;   /* NaN is truthy, -0.0 is not */
        case C_NULL: snprintf(b, n, "o:0 dec:1"); break;
        case C_BOOL: snprintf(b, n, "o:%d dec:1", k == K_TRUE); break;
        case C_SMI: snprintf(b, n, "o:1 dec:1"); break;
        default: snprintf(b, n, "o:0 dec:0");                             /* undecided: no dereference */
    }
}
EXP(dump_value) {
    char t[64];
    switch (kclass(k)) {
        case C_F64: eigs_num_text(t, sizeof t, KD(k)); snprintf(b, n, "s:%s", t); break;
        case C_NULL: snprintf(b, n, "s:null"); break;
        case C_BOOL: snprintf(b, n, "s:%s", k == K_TRUE ? "true" : "false"); break;
        case C_SMI: snprintf(b, n, "s:5"); break;
        case C_HEAP: snprintf(b, n, "s:\"x\""); break;
        default: snprintf(b, n, "s:?");
    }
}
EXP(obs_num) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "o:1 d:%016llx", (unsigned long long)KB[k]); break;
        case C_SMI: snprintf(b, n, "o:1 d:%016llx", (unsigned long long)u64_of(5.0)); break;
        default: snprintf(b, n, "o:0 d:%016llx", (unsigned long long)u64_of(-7.25));
    }
}
EXP(truthy) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "i:%d", KD(k) != 0.0); break;
        case C_NULL: snprintf(b, n, "i:0"); break;
        case C_BOOL: snprintf(b, n, "i:%d", k == K_TRUE); break;
        case C_SMI: case C_HEAP: snprintf(b, n, "i:1"); break;
        default: ABORT("slot_truthy");
    }
}
EXP(type_name) {
    static const char *names[] = {"s:num", "s:none", "s:bool", "s:num", "s:str"};
    if (kclass(k) == C_RES) ABORT("slot_type_name"); else snprintf(b, n, "%s", names[kclass(k)]);
}
EXP(ok) { (void)k; snprintf(b, n, "ok"); }
EXP(is_bool) { snprintf(b, n, "i:%d", kclass(k) == C_BOOL); }
EXP(is_heap) { snprintf(b, n, "i:%d", k == K_HEAP); }
EXP(is_null) { snprintf(b, n, "i:%d", k == K_NULL); }
EXP(slot_box) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "v:num:%016llx", (unsigned long long)(k == K_NAN ? 0 : KB[k])); break;
        case C_NULL: snprintf(b, n, "v:null"); break;
        case C_BOOL: e_bool(b, n, k); break;
        case C_HEAP: snprintf(b, n, "v:H"); break;
        case C_SMI: snprintf(b, n, "v:int:5"); break;
        default: ABORT("eigs_slot_ref");
    }
}
EXP(slot_type) {
    static const char *names[] = {"t:num", "t:null", "t:bool", "t:num", "t:str"};
    if (kclass(k) == C_RES) ABORT("slot_type");
    else snprintf(b, n, "%s", names[kclass(k)]);
}
EXP(slot_view) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "v:num:%016llx", (unsigned long long)KB[k]); break;   /* a facade: no guard */
        case C_NULL: snprintf(b, n, "v:null"); break;
        case C_BOOL: e_bool(b, n, k); break;
        case C_HEAP: snprintf(b, n, "v:H"); break;
        case C_SMI: snprintf(b, n, "v:int:5"); break;
        default: ABORT("slot_type");
    }
}
EXP(to_value) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "v:num:%016llx", (unsigned long long)(k == K_NAN ? 0 : KB[k])); break;
        case C_NULL: snprintf(b, n, "v:null"); break;
        case C_BOOL: e_bool(b, n, k); break;
        case C_HEAP: snprintf(b, n, "v:H"); break;
        case C_SMI: snprintf(b, n, "v:int:5"); break;
        default: ABORT("slot_to_value");
    }
}
EXP(observable) {
    switch (kclass(k)) {
        case C_F64: case C_NULL: snprintf(b, n, "i:0"); break;
        case C_BOOL: case C_HEAP: snprintf(b, n, "i:1"); break;
        default: ABORT("obs_slot_observable");
    }
}
EXP(unwrap) {
    switch (kclass(k)) {
        case C_F64: snprintf(b, n, "v:num:%016llx", (unsigned long long)(k == K_NAN ? 0 : KB[k])); break;
        case C_NULL: snprintf(b, n, "v:null"); break;
        case C_BOOL: e_bool(b, n, k); break;
        case C_HEAP: snprintf(b, n, "v:H"); break;
        case C_SMI: snprintf(b, n, "v:int:5"); break;
        default: ABORT("slot_as_ptr");
    }
}
EXP(slot_ref) {
    switch (kclass(k)) {
        case C_NULL: snprintf(b, n, "v:null"); break;
        case C_BOOL: e_bool(b, n, k); break;
        case C_HEAP: snprintf(b, n, "v:H"); break;
        default: ABORT("eigs_slot_ref");
    }
}
EXP(as_ptr) { if (k == K_HEAP) snprintf(b, n, "v:H"); else ABORT("slot_as_ptr"); }
EXP(obs_value) {
    if (kclass(k) == C_BOOL) e_bool(b, n, k);
    else if (k == K_HEAP) snprintf(b, n, "v:H");
    else ABORT("slot_as_ptr");
}

typedef struct {
    const char *name;
    void (*cell)(EigsSlot, char *, size_t);
    void (*expect)(int, char *, size_t);
} MatrixEntry;
EXP(vm_bit_operand) {
    if (k == K_SMI) snprintf(b, n, "o:1 i:5");
    else if (k == K_NZ) snprintf(b, n, "o:1 i:0");
    else snprintf(b, n, "o:%d i:7", kclass(k) == C_F64 ? 0 : -1);
}
EXP(vm_number_compare) {
    if (k == K_SMI) snprintf(b, n, "o:1 c:1");
    else if (k == K_NAN) snprintf(b, n, "o:1 c:2");
    else if (kclass(k) == C_F64) snprintf(b, n, "o:1 c:%d", k == K_NZ ? -1 : 1);
    else snprintf(b, n, "o:0 c:7");
}
EXP(vm_iter_index) {
    if (k == K_SMI) snprintf(b, n, "o:1 i:5");
    else if (k == K_NZ) snprintf(b, n, "o:1 i:0");
    else if (k == K_F) snprintf(b, n, "o:1 i:1");
    else snprintf(b, n, "o:0 i:7");
}
EXP(vm_iter_limit) { snprintf(b, n, "i:%d", k == K_SMI ? 5 : k == K_NZ ? 0 : k == K_F ? 1 : 10); }
static const MatrixEntry MATRIX[] = {
    {"vm.c:vm_bit_operand", c_vm_bit_operand, e_vm_bit_operand},
    {"vm.c:vm_number_compare", c_vm_number_compare, e_vm_number_compare},
    {"vm.c:vm_iter_index", c_vm_iter_index, e_vm_iter_index},
    {"vm.c:vm_iter_limit", c_vm_iter_limit, e_vm_iter_limit},
    {"container.h:eigs_slot_elem_num", c_elem_num, e_elem_num},
    {"container.h:eigs_slot_num", c_num, e_num},
    {"container.h:eigs_slot_opt_num", c_opt_num, e_opt_num},
    {"container.h:eigs_slot_store_borrow", c_store_borrow, e_store_slot},
    {"container.h:eigs_slot_store_owned", c_store_owned, e_store_slot},
    {"eigenscript.c:ent_child_slot", c_ent_child, e_ent_child},
    {"ext_store.c:store_json_encode_slot", c_store_json, e_store_json},
    {"trace.c:write_slot", c_write_slot, e_write_slot},
    {"value_slot.h:slot_f64_value", c_f64_value, e_f64_value},
    {"value_slot.h:slot_int_value", c_int_value, e_int_value},
    {"value_slot.h:slot_is_f64", c_is_f64, e_is_f64},
    {"value_slot.h:slot_is_smi", c_is_smi, e_is_smi},
    {"value_slot.h:slot_smi_val", c_smi_val, e_smi_val},
    {"value_slot.h:slot_truthy_immediate", c_truthy_imm, e_truthy_imm},
    {"vm.c:obs_dump_value", c_dump_value, e_dump_value},
    {"vm.c:obs_slot_num", c_obs_num, e_obs_num},
    {"vm.c:slot_truthy", c_truthy, e_truthy},
    {"vm.c:slot_type_name", c_type_name, e_type_name},
    {"value_slot.h:slot_decref", c_decref, e_ok},
    {"value_slot.h:slot_incref", c_incref, e_ok},
    {"value_slot.h:slot_is_bool", c_is_bool, e_is_bool},
    {"value_slot.h:slot_is_heap", c_is_heap, e_is_heap},
    {"value_slot.h:slot_is_null", c_is_null, e_is_null},
    {"value_slot.h:slot_is_ptr", c_is_ptr, e_is_heap},
    {"container.h:eigs_slot_box", c_slot_box, e_slot_box},
    {"container.h:slot_type", c_slot_type, e_slot_type},
    {"container.h:slot_view", c_slot_view, e_slot_view},
    {"eigenscript.c:slot_to_value", c_to_value, e_to_value},
    {"vm.c:obs_slot_observable", c_observable, e_observable},
    {"vm.c:slot_bridge_unwrap", c_unwrap, e_unwrap},
    {"container.h:eigs_slot_ref", c_slot_ref, e_slot_ref},
    {"value_slot.h:slot_as_ptr", c_as_ptr, e_as_ptr},
    {"vm.c:obs_slot_value", c_obs_value, e_obs_value},
};
#define N_MATRIX ((int)(sizeof MATRIX / sizeof MATRIX[0]))

/* Run cell(s) in a child; return its outcome as a token: the rendered result
 * (plus " raise" when the call raised), `A:<reader>` for an abort with a FATAL
 * line naming the reader, `X:...` for anything else (a crash, a bad exit).
 * `pre`, when given, receives what the child printed before its result. */
static void run_cell(void (*cell)(EigsSlot, char *, size_t), EigsSlot s, char *got, size_t gn,
                     char *pre, size_t pn) {
    if (pre) pre[0] = 0;
    int p[2];
    if (pipe(p) != 0) { snprintf(got, gn, "X:pipe"); return; }
    fflush(stdout); fflush(stderr);
    pid_t pid = fork();
    if (pid < 0) { snprintf(got, gn, "X:fork"); return; }
    if (pid == 0) {
        child_no_core();
        close(p[0]);
        dup2(p[1], 1); dup2(p[1], 2);
        char b[512];
        g_has_error = 0;
        cell(s, b, sizeof b);
        printf("R:%s%s\n", b, g_has_error ? " raise" : "");
        fflush(stdout);
        _exit(0);
    }
    close(p[1]);
    char buf[2048];
    size_t len = 0;
    ssize_t r;
    while (len < sizeof buf - 1 && (r = read(p[0], buf + len, sizeof buf - 1 - len)) > 0) len += (size_t)r;
    buf[len] = 0;
    close(p[0]);
    int st = 0;
    waitpid(pid, &st, 0);
    char *f = strstr(buf, "EigenScript FATAL: ");
    if (WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT && f) {
        f += strlen("EigenScript FATAL: ");
        char *end = strstr(f, ": ");
        snprintf(got, gn, "A:%.*s", end ? (int)(end - f) : (int)strcspn(f, "\n"), f);
        return;
    }
    char *rl = (strncmp(buf, "R:", 2) == 0) ? buf : strstr(buf, "\nR:");
    if (rl && rl != buf) rl++;
    if (pre && rl) snprintf(pre, pn, "%.*s", (int)(rl - buf), buf);
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0 && rl) {
        snprintf(got, gn, "%.*s", (int)strcspn(rl + 2, "\n"), rl + 2);
        return;
    }
    snprintf(got, gn, "X:%s %d: %.*s", WIFSIGNALED(st) ? "signal" : "exit",
             WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st), (int)strcspn(buf, "\n"), buf);
}

static int part_b(void) {
    int cells = 0;
    for (int i = 0; i < N_MATRIX; i++) {
        const MatrixEntry *m = &MATRIX[i];
        int bad = 0;
        for (int k = 0; k < N_KINDS; k++, cells++) {
            char want[256], got[512];
            m->expect(k, want, sizeof want);
            run_cell(m->cell, bits(KB[k]), got, sizeof got, NULL, 0);
            if (strcmp(want, got) != 0) {
                FAILF("%s(%s): got %s, want %s", m->name, KIND_NAMES[k], got, want);
                bad++;
            }
        }
        printf("MATRIX %s kinds=%d %s\n", m->name, N_KINDS, bad ? "FAIL" : "ok");
    }
    return cells;
}

/* ---- Part C: slot_from_int (plant 1's named check) ----------------------- */

static int part_c(void) {
    static const int64_t inside[] = {
        0, 1, -1, 12345, -12345, (INT64_C(1) << 47) - 1, -(INT64_C(1) << 47),
    };
    static const int64_t outside[] = {
        INT64_C(1) << 47, -(INT64_C(1) << 47) - 1, INT64_MAX, INT64_MIN,
    };
    int rows = 0;
    for (size_t k = 0; k < sizeof inside / sizeof inside[0]; k++, rows++) {
        int64_t v = inside[k];
        EigsSlot s = slot_from_int(v);
        /* plant 1's named check: an int that fits is stored as an SMI */
        if (s.u != smi(v).u)
            FAILF("slot_from_int(%lld): bits 0x%016llx (tag 0x%04llx), want the SMI 0x%016llx",
                  (long long)v, (unsigned long long)s.u, (unsigned long long)(s.u >> 48),
                  (unsigned long long)smi(v).u);
        if (slot_smi_val(smi(v)) != v)
            FAILF("slot_smi_val(SMI %lld) = %lld", (long long)v, (long long)slot_smi_val(smi(v)));
    }
    for (size_t k = 0; k < sizeof outside / sizeof outside[0]; k++, rows++) {
        EigsSlot boxed = slot_from_int(outside[k]);
        int64_t got = 0;
        if (!slot_is_heap(boxed) || !slot_int_value(boxed, &got) || got != outside[k] ||
            slot_as_ptr(boxed)->type != VAL_INT)
            FAILF("slot_from_int(%lld): box loses exact int64", (long long)outside[k]);
        slot_decref(boxed);
    }
    return rows;
}

/* ---- Part D: the VM's operator arms, with an int in a list ------------- */

/* A host builtin puts a hand-built SMI (or a float control) in a list.
 * Every R1.3-converted arm computes its final value, including under try. */
static int g_poke_smi;
static EigsValue *h_poke(EigsValue *arg) {
    Value *t = list_get_ref(arg, 0);
    if (!t || t->type != VAL_LIST || t->data.list.count < 1) { printf("POKE: bad target\n"); _exit(97); }
    EigsSlot old = t->data.list.items[0];
    t->data.list.items[0] = g_poke_smi ? smi(5) : slot_from_f64(5.0);
    slot_decref(old);
    return make_null();
}
typedef struct { const char *name, *expr, *f64_out, *int_out; int in_try; } Arm;
static const Arm ARMS[] = {
    {"lt", "xs[0] < 6", "true", "true", 0},
    {"gt", "xs[0] > 6", "false", "false", 0},
    {"le", "xs[0] <= 6", "true", "true", 0},
    {"ge", "xs[0] >= 6", "false", "false", 0},
    {"lt_in_try", "xs[0] < 6", "true", "true", 1},
    {"band", "xs[0] & 3", "1", "1", 0},
    {"bor", "xs[0] | 3", "7", "7", 0},
    {"bxor", "xs[0] ^ 3", "6", "6", 0},
    {"shl", "xs[0] << 1", "10", "10", 0},
    {"shr", "xs[0] >> 1", "2", "2", 0},
    {"band_in_try", "xs[0] & 3", "1", "1", 1},
    {"neg", "-(xs[0])", "-5", "-5", 0},
    {"neg_in_try", "-(xs[0])", "-5", "-5", 1},
    {"bnot", "~(xs[0])", "-6", "-6", 0},
    {"eq", "xs[0] == 5", "true", "true", 0},
    {"add", "xs[0] + 1", "6", "6", 0},
};
#define N_ARMS ((int)(sizeof ARMS / sizeof ARMS[0]))
static const Arm *g_arm;
static void c_arm(EigsSlot s, char *b, size_t n) {
    (void)s;
    char prog[512];
    if (g_arm->in_try)
        snprintf(prog, sizeof prog, "xs is [7.5]\nphase2_poke of ([xs])\ntry:\n    print of (%s)\n"
                 "catch e:\n    print of \"caught\"\n", g_arm->expr);
    else
        snprintf(prog, sizeof prog, "xs is [7.5]\nphase2_poke of ([xs])\nprint of (%s)\n", g_arm->expr);
    EigsValue *r = eigs_eval_string(prog);
    fflush(stdout);
    snprintf(b, n, "%s", r ? "ran" : "eval-error");
    eigs_value_release(r);
}
static int part_d(void) {
    eigs_register_function("phase2_poke", h_poke);
    int rows = 0;
    for (int i = 0; i < N_ARMS; i++) {
        g_arm = &ARMS[i];
        int bad = 0;
        char got[512], want[256], pre[512], wpre[64];
        g_poke_smi = 1;
        run_cell(c_arm, slot_null(), got, sizeof got, pre, sizeof pre);
        snprintf(want, sizeof want, "%s\n", g_arm->int_out);
        if (strcmp(got, "ran") != 0 || strcmp(pre, want) != 0) {
            FAILF("arm %s with an int: got %s printed %s, want ran and %s", g_arm->name, got, pre, want);
            bad++;
        }
        g_poke_smi = 0;
        run_cell(c_arm, slot_null(), got, sizeof got, pre, sizeof pre);
        snprintf(wpre, sizeof wpre, "%s\n", g_arm->f64_out);
        if (strcmp(got, "ran") != 0 || strcmp(pre, wpre) != 0) {
            FAILF("arm %s control (a double): got %s, printed \"%.*s\", want ran and %s", g_arm->name, got,
                  (int)strcspn(pre, "\n"), pre, g_arm->f64_out);
            bad++;
        }
        rows += 2;
        printf("ARM %s %s\n", g_arm->name, bad ? "FAIL" : "ok");
    }
    return rows;
}

/* ---- Part E: the four ITER_NEXT metadata sites (#1827) ------------------ */
/* Construct a raw state because ordinary for loops deliberately keep float
 * metadata until the builtin/iterator bridge round. Exercise the interpreter
 * through an assembled chunk, and the actual JIT helper directly. */
typedef struct { const char *name; int field, kind; int64_t value; int yields; } IterCase;
static const IterCase ITER_CASES[] = {
    {"float_control", 1, 0, 0, 1},
    {"smi_index", 1, 1, 0, 1},
    {"boxed_index", 1, 2, 0, 1},
    {"smi_snapshot", 2, 1, 1, 1},
    {"boxed_snapshot", 2, 2, 1, 1},
    {"large_index", 1, 2, INT64_MAX, 0},
    {"negative_index", 1, 2, INT64_MIN, 0},
    {"large_snapshot", 2, 2, INT64_MAX, 1},
    {"negative_snapshot", 2, 2, INT64_MIN, 0},
    {"smi_negative_snapshot", 2, 1, -1, 0},
    {"malformed_index", 1, 3, 0, 0},
    {"malformed_snapshot", 2, 3, 0, 1},
    {"malformed_iterable", 0, 2, 42, 0},
};
#define N_ITER_CASES ((int)(sizeof ITER_CASES / sizeof ITER_CASES[0]))
static const IterCase *g_iter_case;
static int g_iter_helper;
static void c_iter(EigsSlot unused, char *b, size_t n) {
    (void)unused;
    const IterCase *t = g_iter_case;
    Value *state = make_list(0), *items = make_list(0);
    list_append_slot(items, slot_from_f64(42.0));
    list_append_slot(state, slot_from_heap(items));
    val_decref(items);
    list_append_slot(state, slot_from_f64(0.0));
    list_append_slot(state, slot_from_f64(1.0));
    EigsSlot replacement = t->kind == 0 ? slot_from_f64((double)t->value) :
                           t->kind == 1 ? smi(t->value) :
                           t->kind == 2 ? slot_from_heap(make_int(t->value)) :
                                          slot_from_heap(make_str("bad"));
    /* Raw states can hold non-canonical small boxes. Bypass writers here
     * deliberately, and prove which representation reaches each reader. */
    EigsSlot old_metadata = state->data.list.items[t->field];
    state->data.list.items[t->field] = replacement;
    slot_decref(old_metadata);
    EigsSlot stored_metadata = list_slot(state, t->field);
    int representation_ok = t->kind == 0 ? slot_is_f64(stored_metadata) :
                            t->kind == 1 ? slot_is_smi(stored_metadata) :
                            t->kind == 2 ? (slot_is_heap(stored_metadata) &&
                                           slot_as_ptr(stored_metadata)->type == VAL_INT &&
                                           VAL_I64_RAW(slot_as_ptr(stored_metadata)) == t->value) :
                                          (slot_is_heap(stored_metadata) &&
                                           slot_as_ptr(stored_metadata)->type == VAL_STR);
    if (!representation_ok) {
        snprintf(b, n, "wrong-metadata-representation");
        val_decref(state);
        return;
    }
    Value *result;
    if (g_iter_helper) {
        vm_init();  /* direct helper calls need the VM allocated, as vm_execute does */
        val_incref(state);
        vm_push(state);
        int rc = jit_helper_iter_next();
        result = rc == 0 ? vm_pop() : make_null();
        Value *popped_state = vm_pop();
        val_decref(popped_state);
    } else {
        EigsChunk *chunk = chunk_new("<phase2-iterator>");
        int ci = chunk_add_constant(chunk, state);
        chunk_emit(chunk, OP_CONST, 1);
        chunk_emit_u16(chunk, (uint16_t)ci, 1);
        chunk_emit(chunk, OP_ITER_NEXT, 1);
        chunk_emit_u16(chunk, 1, 1);  /* exhausted: skip the element RETURN */
        chunk_emit(chunk, OP_RETURN, 1);
        chunk_emit(chunk, OP_NULL, 1);
        chunk_emit(chunk, OP_RETURN, 1);
        result = vm_execute(chunk, g_global_env);
        chunk_free(chunk);
    }
    if (result && result->type == VAL_FLOAT && VAL_F64_RAW(result) == 42.0) {
        double next = -1;
        int float_next = slot_f64_value(list_slot(state, 1), &next);
        snprintf(b, n, "yield:42 float_next:%d", float_next && next == 1.0);
    } else if (result && result->type == VAL_NULL) snprintf(b, n, "exhausted");
    else snprintf(b, n, "unexpected");
    val_decref(result);
    val_decref(state);
}
static int part_e(void) {
    int rows = 0;
    for (int i = 0; i < N_ITER_CASES; i++) {
        g_iter_case = &ITER_CASES[i];
        for (g_iter_helper = 0; g_iter_helper < 2; g_iter_helper++) {
            char got[512];
            run_cell(c_iter, slot_null(), got, sizeof got, NULL, 0);
            const char *want = g_iter_case->yields ? "yield:42 float_next:1" : "exhausted";
            int bad = strcmp(got, want) != 0;
            if (bad) FAILF("ITER_NEXT %s %s: got %s, want %s",
                           g_iter_helper ? "jit_helper" : "interpreter", g_iter_case->name, got, want);
            printf("ARM iter_%s_%s %s\n", g_iter_helper ? "jit" : "vm",
                   g_iter_case->name, bad ? "FAIL" : "ok");
            rows++;
        }
    }
    return rows;
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { printf("slot-layer-test: FAIL eigs_open\n"); return 1; }
    /* Part B reads the canonical NaN back through make_num, whose guard
     * raises under strict mode; the test pins the soft read instead. */
    eigs_state_set_strict(st, 0);
    g_str = make_str("x");
    static const uint64_t kinds[N_KINDS] = {
        0x3FF8000000000000ULL, 0x7FF8000000000000ULL, 0x8000000000000000ULL,
        0xFFF8000000000000ULL, 0xFFF9000000000000ULL, 0xFFF9000000000001ULL,
        T_SMI_TAG | 5, 0, 0xFFFC000000000000ULL, 0xFFFD000000000000ULL,
        0xFFFE000000000000ULL, 0xFFFF000000000000ULL,
    };
    memcpy(KB, kinds, sizeof KB);
    KB[K_HEAP] = slot_from_heap(g_str).u;
    size_t before = g_out_len;
    write_value_ptr(g_str);
    snprintf(g_heap_tape, sizeof g_heap_tape, "%.*s", (int)(g_out_len - before), g_out + before);
    int calls = part_a();
    int matrix_cells = part_b();
    int from_int_rows = part_c();
    int arm_rows = part_d();
    int iter_rows = part_e();
    printf("slot-layer-test: examined=%d smi_values=%d calls=%d matrix=%d kinds=%d matrix_cells=%d "
           "from_int_rows=%d arm_rows=%d iter_rows=%d failures=%d\n", N_ENTRIES, N_SMI, calls, N_MATRIX, N_KINDS,
           matrix_cells, from_int_rows, arm_rows, iter_rows, failures);
    val_decref(g_str);
    eigs_close(st);
    int ok = failures == 0 && N_ENTRIES > 0 && calls > 0 && N_MATRIX == N_ENTRIES &&
             matrix_cells == N_MATRIX * N_KINDS && from_int_rows > 0 && arm_rows == 2 * N_ARMS && iter_rows == 2 * N_ITER_CASES;
    printf("slot-layer-test: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
