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
 *   B  the tag matrix: the predicates and the deciding readers against a
 *      double, the canonical NaN, -0.0, null, both bools, an SMI, a heap
 *      pointer, the reserved tags and the sentinel.
 *   C  slot_from_int, the one int writer (plant 1's named check, design 9.3):
 *      inside [-2^47, 2^47) the tag is 0xFFFA and the int reads back exactly;
 *      outside, R1.1 refuses (the VAL_INT box lands in R1.3).
 *
 * Output: one `ENTRY <file>:<function> ...` line per Part A entry (the runner
 * compares that set with the derived population, both ways), `FAIL` lines,
 * and a final `slot-layer-test: examined=N ... failures=F` line, then its verdict.
 * Exit 0 only for failures == 0 with every part non-empty. */
#include "eigenscript_all.c"

#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef EIGS_SLOT_CHECKS
#error "build with -DEIGS_SLOT_CHECKED (or ASan): slot_as_ptr's refusal is under test"
#endif

static int failures;

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
static int r_slot_int_value(int64_t v) { int64_t i = 7; return slot_int_value(smi(v), &i) != 1 || i != v; }
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

static void a_eigs_slot_box(EigsSlot s) { (void)eigs_slot_box(s); }
static void a_slot_type(EigsSlot s) { (void)slot_type(s); }
static void a_slot_view(EigsSlot s) { EIGS_VIEW_NOCHECK(view); (void)slot_view(s, &view); }
static void a_slot_to_value(EigsSlot s) { (void)slot_to_value(s); }
static void a_write_slot(EigsSlot s) { write_slot(s); }
static void a_obs_slot_observable(EigsSlot s) { (void)obs_slot_observable(s); }
static void a_slot_bridge_unwrap(EigsSlot s) { (void)slot_bridge_unwrap(s); }
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
    {"container.h:eigs_slot_box", 0, a_eigs_slot_box, "slot_to_value", "unwired: an int Value (R1.3)"},
    {"container.h:slot_type", 0, a_slot_type, "slot_type", "unwired: the int ValType (R1.2a)"},
    {"container.h:slot_view", 0, a_slot_view, "slot_view", "unwired: a VAL_INT facade (R1.2a)"},
    {"eigenscript.c:slot_to_value", 0, a_slot_to_value, "slot_to_value", "unwired: make_int (R1.3)"},
    {"trace.c:write_slot", 0, a_write_slot, "write_slot", "unwired: tape v7 (R1.3)"},
    {"vm.c:obs_slot_observable", 0, a_obs_slot_observable, "obs_slot_observable", "refuse"},
    {"vm.c:slot_bridge_unwrap", 0, a_slot_bridge_unwrap, "slot_to_value", "routes to the one SMI boxer"},
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

/* ---- Part B: the tag matrix ---------------------------------------------- */

typedef struct { const char *name; uint64_t u; } Kind;

static void b_type_name(EigsSlot s) { (void)slot_type_name(s); }
static void b_truthy(EigsSlot s) { (void)slot_truthy(s); }

static int part_b(void) {
    Value *str = make_str("x");
    Kind kinds[] = {
        {"f64 1.5", 0x3FF8000000000000ULL},
        {"f64 canonical NaN", 0x7FF8000000000000ULL},
        {"f64 -0.0", 0x8000000000000000ULL},
        {"null", 0xFFF8000000000000ULL},
        {"false", 0xFFF9000000000000ULL},
        {"true", 0xFFF9000000000001ULL},
        {"SMI 5", T_SMI_TAG | 5},
        {"heap str", 0},
        {"reserved 0xFFFC", 0xFFFC000000000000ULL},
        {"reserved 0xFFFD", 0xFFFD000000000000ULL},
        {"reserved 0xFFFE", 0xFFFE000000000000ULL},
        {"sentinel 0xFFFF", 0xFFFF000000000000ULL},
    };
    int nk = (int)(sizeof kinds / sizeof kinds[0]);
    kinds[7].u = slot_from_heap(str).u;
    /* expected predicate answers, columns: f64 smi null bool heap ptr */
    static const int want_pred[][6] = {
        {1,0,0,0,0,0}, {1,0,0,0,0,0}, {1,0,0,0,0,0}, {0,0,1,0,0,0}, {0,0,0,1,0,0},
        {0,0,0,1,0,0}, {0,1,0,0,0,0}, {0,0,0,0,1,1}, {0,0,0,0,0,0}, {0,0,0,0,0,0},
        {0,0,0,0,0,0}, {0,0,0,0,0,0},
    };
    static const char *want_type[] = {
        "num", "num", "num", "none", "bool", "bool", "num", "str", 0, 0, 0, 0,
    };
    static const int want_truthy[] = { 1, 1, 0, 0, 0, 1, 1, 1, -1, -1, -1, -1 };
    static const int want_f64[] = { 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    int rows = 0;
    for (int i = 0; i < nk; i++) {
        EigsSlot s = bits(kinds[i].u);
        int got[6] = { slot_is_f64(s), slot_is_smi(s), slot_is_null(s), slot_is_bool(s),
                       slot_is_heap(s), slot_is_ptr(s) };
        static const char *pn[6] = {"slot_is_f64", "slot_is_smi", "slot_is_null",
                                    "slot_is_bool", "slot_is_heap", "slot_is_ptr"};
        for (int j = 0; j < 6; j++, rows++)
            if (got[j] != want_pred[i][j])
                FAILF("%s(%s) = %d, want %d", pn[j], kinds[i].name, got[j], want_pred[i][j]);
        rows++;
        if (want_type[i]) {
            const char *t = slot_type_name(s);
            if (strcmp(t, want_type[i]) != 0)
                FAILF("slot_type_name(%s) = %s, want %s", kinds[i].name, t, want_type[i]);
        } else {
            (void)aborts_naming(b_type_name, s, "slot_type_name", "slot_type_name");
        }
        rows++;
        if (want_truthy[i] >= 0) {
            int t = slot_truthy(s);
            if (t != want_truthy[i])
                FAILF("slot_truthy(%s) = %d, want %d", kinds[i].name, t, want_truthy[i]);
        } else {
            (void)aborts_naming(b_truthy, s, "slot_truthy", "slot_truthy");
        }
        rows++;
        double d = -7.25;
        int f = slot_f64_value(s, &d);
        if (f != want_f64[i] || (f && memcmp(&d, &kinds[i].u, sizeof d) != 0))
            FAILF("slot_f64_value(%s) = %d, want %d with the same bits", kinds[i].name, f, want_f64[i]);
        rows++;
        int64_t iv = 0;
        int isint = slot_int_value(s, &iv);
        if (isint != (i == 6) || (isint && iv != 5))
            FAILF("slot_int_value(%s) = %d (%lld)", kinds[i].name, isint, (long long)iv);
        /* the readers that must refuse every non-pointer, non-null, non-bool */
        rows++;
        if (want_pred[i][3] || want_pred[i][2] || want_pred[i][4]) {
            Value *r = eigs_slot_ref(s);
            Value *want = want_pred[i][4] ? str : want_pred[i][2] ? make_null() : make_bool(i == 5);
            if (r != want) FAILF("eigs_slot_ref(%s) is not its Value", kinds[i].name);
        } else {
            (void)aborts_naming(a_eigs_slot_ref, s, "eigs_slot_ref", "eigs_slot_ref");
        }
        rows++;
        if (want_pred[i][1]) {
            (void)aborts_naming(a_slot_to_value, s, "slot_to_value", "slot_to_value");
        } else if (want_pred[i][0] || want_pred[i][2] || want_pred[i][3] || want_pred[i][4]) {
            Value *v = slot_to_value(s);
            /* make_num guards: a NaN reads back 0.0 (non-strict, set in main) */
            double wd = want_pred[i][0] ? num_guard(f64_of(kinds[i].u)) : 0.0;
            int ok = want_pred[i][0] ? (v->type == VAL_NUM && memcmp(&VAL_NUM_RAW(v), &wd, 8) == 0)
                   : want_pred[i][2] ? v->type == VAL_NULL
                   : want_pred[i][3] ? (v->type == VAL_BOOL && v->data.boolean == (i == 5))
                   : v == str;
            if (!ok) FAILF("slot_to_value(%s) is not its Value", kinds[i].name);
            val_decref(v);
        } else {
            (void)aborts_naming(a_slot_to_value, s, "slot_to_value", "slot_to_value");
        }
        rows++;
        if (want_pred[i][1] || (!want_pred[i][0] && !want_pred[i][2] && !want_pred[i][3] && !want_pred[i][4])) {
            (void)aborts_naming(a_obs_slot_observable, s, "obs_slot_observable", "obs_slot_observable");
        } else {
            int o = obs_slot_observable(s);
            int wo = want_pred[i][3] || want_pred[i][4];
            if (o != wo) FAILF("obs_slot_observable(%s) = %d, want %d", kinds[i].name, o, wo);
        }
    }
    val_decref(str);
    return rows;
}

/* ---- Part C: slot_from_int (plant 1's named check) ----------------------- */

static int64_t g_from_int_arg;
static void c_from_int(EigsSlot s) { (void)s; (void)slot_from_int(g_from_int_arg); }

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
        g_from_int_arg = outside[k];
        char what[64];
        snprintf(what, sizeof what, "slot_from_int(%lld)", (long long)outside[k]);
        (void)aborts_naming(c_from_int, slot_null(), "slot_from_int", what);
    }
    return rows;
}

int main(void) {
    EigsState *st = eigs_open();
    if (!st) { printf("slot-layer-test: FAIL eigs_open\n"); return 1; }
    /* Part B reads the canonical NaN back through make_num, whose guard
     * raises under strict mode; the test pins the soft read instead. */
    eigs_state_set_strict(st, 0);
    int calls = part_a();
    int tag_rows = part_b();
    int from_int_rows = part_c();
    printf("slot-layer-test: examined=%d smi_values=%d calls=%d tag_rows=%d from_int_rows=%d failures=%d\n",
           N_ENTRIES, N_SMI, calls, tag_rows, from_int_rows, failures);
    eigs_close(st);
    int ok = failures == 0 && N_ENTRIES > 0 && calls > 0 && tag_rows > 0 && from_int_rows > 0;
    printf("slot-layer-test: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}
