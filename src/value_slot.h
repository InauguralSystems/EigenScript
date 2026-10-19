/*
 * EigenScript NaN-boxed slot encoding.
 *
 * An EigsSlot is a 64-bit union aliasing a double. Floats live as
 * immediate doubles. Pointers and other immediates encode into the
 * unused QNaN-with-sign-set bit pattern, which num_guard() makes
 * unreachable from user numbers (NaN -> 0, +/-Inf -> +/-1e308).
 *
 * Tag layout (high 16 bits):
 *   < 0xFFF8     : a double          (slot_is_f64)
 *   0xFFF8 tag 0 : NULL              (payload ignored)
 *   0xFFF9 tag 1 : BOOL              (low bit = value)
 *   0xFFFA tag 2 : SMI               (an int in [-2^47, 2^47): 48-bit two's
 *                                     complement payload; #1758. Nothing
 *                                     produces one before R1.3)
 *   0xFFFB tag 3 : HEAP pointer      (str/list/dict/fn/builtin/buffer/tb)
 *   0xFFFC tag 4 : reserved          (#262 Step E: was TRACKED — removed)
 *   0xFFFD tag 5 : reserved
 *   0xFFFE tag 6 : reserved
 *   0xFFFF tag 7 : SENTINEL          (VM internal markers)
 *
 * x86-64 / aarch64 user pointers fit in 48 bits, leaving the high
 * 16 bits for the tag.
 *
 * This header is included from eigenscript.h *after* the Value struct
 * is defined, so the inline slot_incref / slot_decref can dereference
 * the full struct.
 */
#ifndef EIGENSCRIPT_VALUE_SLOT_H
#define EIGENSCRIPT_VALUE_SLOT_H

#include <stdint.h>

#ifndef EIGENSCRIPT_EIGSSLOT_UNION_DEFINED
#define EIGENSCRIPT_EIGSSLOT_UNION_DEFINED
typedef union { double d_; uint64_t u; } EigsSlot;   /* d_: read via SLOT_F64_RAW (#1637) */
#endif

#define SLOT_QNAN_MASK     0xFFF8000000000000ULL
#define SLOT_TAG_MASK      0xFFFF000000000000ULL
#define SLOT_PAYLOAD_MASK  0x0000FFFFFFFFFFFFULL

#define SLOT_NULL_BITS     0xFFF8000000000000ULL
#define SLOT_FALSE_BITS    0xFFF9000000000000ULL
#define SLOT_TRUE_BITS     0xFFF9000000000001ULL

#define TAG_BOOL           0xFFF9000000000000ULL
#define TAG_SMI            0xFFFA000000000000ULL
#define TAG_HEAP           0xFFFB000000000000ULL
#define TAG_SENTINEL       0xFFFF000000000000ULL

/* #1758: the SMI range, [-2^47, 2^47), and the payload's sign bit. */
#define SLOT_SMI_MIN       (-(INT64_C(1) << 47))
#define SLOT_SMI_MAX       ((INT64_C(1) << 47) - 1)
#define SLOT_SMI_SIGN      0x0000800000000000ULL

/* A slot reached a reader that does not handle its tag: a broken caller
 * contract, never a program's fault. Prints the reader and the bits, then
 * aborts (eigenscript.c). */
#if defined(__GNUC__) || defined(__clang__)
#define EIGS_SLOT_NORETURN __attribute__((noreturn, cold))
#else
#define EIGS_SLOT_NORETURN
#endif
EIGS_SLOT_NORETURN void eigs_slot_refuse(const char *who, EigsSlot s);
/* #1758 R1.1: an int exists as an encoding (the SMI) before any int Value
 * kind does (VAL_INT lands in R1.2a, make_int in R1.3). A reader whose int
 * arm needs an int Value, the int's ValType or tape v7 calls this instead
 * of guessing; nothing produces an int before R1.3, so it never runs.
 * R1.3 DELETES it, so every caller stops compiling in the commit that makes
 * ints reachable and gets its real arm there (design 2.7). */
EIGS_SLOT_NORETURN void eigs_int_unwired(const char *who, uint64_t bits);

/* slot_as_ptr refuses a slot that is not a heap pointer in sanitizer builds
 * and under -DEIGS_SLOT_CHECKED (#1758 R1.1: an SMI must never be read as a
 * pointer). Release keeps the bare mask: it is on every hot path. */
#if defined(__SANITIZE_ADDRESS__) || defined(EIGS_SLOT_CHECKED)
#  define EIGS_SLOT_CHECKS 1
#elif defined(__has_feature)
#  if __has_feature(address_sanitizer)
#    define EIGS_SLOT_CHECKS 1
#  endif
#endif

/* #1758 R1.1, the dynamic half of the int-source check: built with
 * -DEIGS_SMI_TRAP (`make smi-trap`), every slot classifier below aborts the
 * moment it reads an SMI, and slot_from_int aborts on any call. Nothing may
 * make an int before R1.3, so the corpus must run on that build exactly as on
 * release; a producer that writes the tag bits itself, which no scan of names
 * sees, dies at its first reader. R1.3 retires the mode with eigs_int_unwired.
 * In every other build SLOT_SMI_TRAP is nothing. */
#ifdef EIGS_SMI_TRAP
#define SLOT_SMI_TRAP(s)                                                       \
    do {                                                                       \
        if (__builtin_expect(((s).u & SLOT_TAG_MASK) == TAG_SMI, 0))           \
            eigs_slot_refuse("EIGS_SMI_TRAP: an int before #1758 R1.3", (s));  \
    } while (0)
#else
#define SLOT_SMI_TRAP(s) ((void)0)
#endif

/* Predicates */

/* #1758: a double. Was slot_is_num; renamed so that every site that meant
 * "a number" had to decide what an int (SMI) does there. */
static inline int slot_is_f64(EigsSlot s) {
    SLOT_SMI_TRAP(s);
    return (s.u & SLOT_QNAN_MASK) != SLOT_QNAN_MASK;
}
static inline int slot_is_null(EigsSlot s)    { SLOT_SMI_TRAP(s); return s.u == SLOT_NULL_BITS; }
static inline int slot_is_bool(EigsSlot s)    { SLOT_SMI_TRAP(s); return (s.u & SLOT_TAG_MASK) == TAG_BOOL; }
static inline int slot_is_smi(EigsSlot s)     { SLOT_SMI_TRAP(s); return (s.u & SLOT_TAG_MASK) == TAG_SMI; }
static inline int slot_is_heap(EigsSlot s)    { SLOT_SMI_TRAP(s); return (s.u & SLOT_TAG_MASK) == TAG_HEAP; }
/* #262 Step E: TAG_TRACKED is gone — a number is always an immediate, never a
 * heap-boxed observer-tracked Value. Heap is the only pointer tag. */
static inline int slot_is_ptr(EigsSlot s)     { SLOT_SMI_TRAP(s); return (s.u & SLOT_TAG_MASK) == TAG_HEAP; }

/* Accessors (caller must check the predicate first) */

/* #1637 round 4: the ONE raw way into a slot's double (an lvalue), for a slot
 * proven a double (slot_is_f64). Every use sits in a function listed in
 * tools/num_read_allowlist.txt with its count (tools/num_read_check.sh). */
#define SLOT_F64_RAW(s) ((s).d_)
static inline int      slot_as_bool(EigsSlot s)   { SLOT_SMI_TRAP(s); return (int)(s.u & 1ULL); }
static inline Value   *slot_as_ptr(EigsSlot s) {
    SLOT_SMI_TRAP(s);
#ifdef EIGS_SLOT_CHECKS
    if (__builtin_expect(!slot_is_heap(s), 0)) eigs_slot_refuse("slot_as_ptr", s);
#endif
    return (Value*)(uintptr_t)(s.u & SLOT_PAYLOAD_MASK);
}
#define slot_as_heap     slot_as_ptr
/* The int an SMI holds, sign-extending payload bit 47 without an
 * implementation-defined right shift (design 2.1). */
static inline int64_t  slot_smi_val(EigsSlot s) {
    SLOT_SMI_TRAP(s);
    return (int64_t)((s.u & SLOT_PAYLOAD_MASK) ^ SLOT_SMI_SIGN) - (int64_t)SLOT_SMI_SIGN;
}

/* Constructors */

/* #1758: the ONE double writer. Round 2 canonicalizes a NaN here. */
static inline EigsSlot slot_from_f64(double d)       { EigsSlot s; SLOT_F64_RAW(s) = d;                                              return s; }
static inline EigsSlot slot_from_heap(Value *v);
/* #1758: the ONE int writer: an SMI inside [-2^47, 2^47), otherwise an
 * owned VAL_INT heap box. */
static inline EigsSlot slot_from_int(int64_t i) {
#ifdef EIGS_SMI_TRAP
    eigs_int_unwired("slot_from_int under EIGS_SMI_TRAP", (uint64_t)i);
#endif
    if (__builtin_expect(i < SLOT_SMI_MIN || i > SLOT_SMI_MAX, 0))
        return slot_from_heap(make_int(i));
    EigsSlot s; s.u = TAG_SMI | ((uint64_t)i & SLOT_PAYLOAD_MASK); return s;
}
static inline EigsSlot slot_null(void)               { EigsSlot s; s.u = SLOT_NULL_BITS;  return s; }
static inline EigsSlot slot_true(void)               { EigsSlot s; s.u = SLOT_TRUE_BITS;  return s; }
static inline EigsSlot slot_false(void)              { EigsSlot s; s.u = SLOT_FALSE_BITS; return s; }
static inline EigsSlot slot_from_bool(int b)         { EigsSlot s; s.u = TAG_BOOL | (b ? 1ULL : 0ULL); return s; }

/* The null and bool singletons are never heap-tagged. Their refcounts are not
 * maintained (val_incref/val_decref skip them), so a TAG_HEAP slot holding one
 * would lose a count at every slot_decref: `type of x` with x null, run 1.1M
 * times, decremented the null singleton's 1000000 to zero and free()d a static
 * (EigenLua's warmup pairs fuzz, 2026-10-11). Normalising here closes every
 * caller at once — the env and stack lifts, the element stores, the task
 * mailbox — instead of each remembering. */
static inline EigsSlot slot_from_heap(Value *v) {
    EigsSlot s;
    if (__builtin_expect(!v || v->type == VAL_NULL, 0)) { s.u = SLOT_NULL_BITS; return s; }
    if (__builtin_expect(v->type == VAL_BOOL, 0)) return slot_from_bool(v->data.boolean);
    s.u = TAG_HEAP | ((uint64_t)(uintptr_t)v & SLOT_PAYLOAD_MASK);
    return s;
}

/* Single-thread refcount gate (g_vm_multithreaded) is now provided as a
 * bridge macro by eigenscript.h, which is already included transitively
 * by every site that includes this header. */

/* Refcount fast path:
 *   immediate (number / null / bool) -> no-op
 *   heap or tracked pointer          -> existing atomic refcount
 * The outer `& SLOT_QNAN_MASK` branch peels off numbers in one
 * predicted-not-taken test with zero memory access. */
static inline void slot_incref(EigsSlot s) {
    SLOT_SMI_TRAP(s);
    if ((s.u & SLOT_QNAN_MASK) == SLOT_QNAN_MASK) {
        uint64_t tag = s.u & SLOT_TAG_MASK;
        if (tag == TAG_HEAP) {
            Value *v = (Value*)(uintptr_t)(s.u & SLOT_PAYLOAD_MASK);
                if (__builtin_expect(g_vm_multithreaded, 0))
                    __atomic_add_fetch(&v->refcount, 1, __ATOMIC_RELAXED);
                else
                    v->refcount++;
        }
    }
}

static inline void slot_decref(EigsSlot s) {
    SLOT_SMI_TRAP(s);
    if ((s.u & SLOT_QNAN_MASK) == SLOT_QNAN_MASK) {
        uint64_t tag = s.u & SLOT_TAG_MASK;
        if (tag == TAG_HEAP) {
            Value *v = (Value*)(uintptr_t)(s.u & SLOT_PAYLOAD_MASK);
                int newrc;
                if (__builtin_expect(g_vm_multithreaded, 0))
                    newrc = __atomic_sub_fetch(&v->refcount, 1, __ATOMIC_ACQ_REL);
                else
                    newrc = --v->refcount;
                if (newrc <= 0) free_value(v);
                /* #307: an env-slot drop is the dominant path by which a
                 * function-local list/dict cycle becomes garbage — register it
                 * as a possible cycle root (mirrors val_decref's hook). */
                else if (__builtin_expect(!g_vm_multithreaded
                                  && (v->type == VAL_LIST || v->type == VAL_DICT)
                                          && !v->gc_buffered, 0))
                    gc_note_possible_root(v);
        }
    }
}

/* Truthiness — used by JUMP_IF_FALSE / JUMP_IF_TRUE fast paths.
 * Immediate-number truthiness is a non-zero double, or a non-zero int
 * (#1758: an SMI is 0 exactly when its payload is 0); null and false
 * are falsy; everything else (heap) defers to caller-side is_truthy(). */
static inline int slot_truthy_immediate(EigsSlot s, int *out_decided) {
    if (slot_is_f64(s)) { *out_decided = 1; return SLOT_F64_RAW(s) != 0.0; }
    if (slot_is_null(s) || s.u == SLOT_FALSE_BITS) { *out_decided = 1; return 0; }
    if (s.u == SLOT_TRUE_BITS) { *out_decided = 1; return 1; }
    if (slot_is_smi(s)) { *out_decided = 1; return slot_smi_val(s) != 0; }
    *out_decided = 0;
    return 0;
}

/* #1758: a float's double, from an immediate or a VAL_FLOAT box (the VM boxes
 * numbers on purpose: the lifts, a for-in variable). 0 for anything else,
 * an int (an SMI, later a VAL_INT box) included: the caller sends it to its
 * slow path; *out is written only when the answer is 1. Replaces vm.c's
 * slot_as_double.
 * Leave it so: its callers sit in vm_run_ex's hot arms, and making it write
 * *out on every path (0.0, or the slot's bits, on the failure path) changed
 * vm_run_ex's code and cost +3.8% Ir on a JIT-off float loop, as much as
 * initialising the callers' locals did (#1775, measured with callgrind). */
static inline int slot_f64_value(EigsSlot s, double *out) {
    if (slot_is_f64(s)) { *out = SLOT_F64_RAW(s); return 1; }
    if (slot_is_heap(s)) {
        Value *v = slot_as_ptr(s);
        if (v->type == VAL_FLOAT) { *out = VAL_F64_RAW(v); return 1; }   /* a VAL_INT box: 0 */
    }
    return 0;
}
/* #1758: an int's value. R1.1 knows the SMI; R1.2a adds the VAL_INT box
 * arm with the type it names. */
static inline int slot_int_value(EigsSlot s, int64_t *out) {
    if (slot_is_smi(s)) { *out = slot_smi_val(s); return 1; }
    if (slot_is_heap(s)) {
        Value *v = slot_as_ptr(s);
        if (v->type == VAL_INT) { *out = VAL_I64_RAW(v); return 1; }
    }
    return 0;
}

/* Boundary shims declared here, defined in eigenscript.c.
 *
 * slot_from_value (takes ownership of the input ref):
 *   - VAL_FLOAT -> immediate double, input decref'd (#262 Step E: numbers never
 *     carry observer state, so there is no tracked-pointer case).
 *   - VAL_NULL -> SLOT_NULL (incref skipped; null is borrowed).
 *   - any heap type -> TAG_HEAP pointer (incref).
 *
 * slot_to_value:
 *   - immediate number/null/bool -> fresh Value via make_*.
 *   - heap pointer -> return pointer, incref. */
EigsSlot slot_from_value(Value *v);
Value   *slot_to_value(EigsSlot s);

#endif /* EIGENSCRIPT_VALUE_SLOT_H */
