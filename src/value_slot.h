/*
 * EigenScript NaN-boxed slot encoding.
 *
 * An EigsSlot is a 64-bit union aliasing a double. Numbers live as
 * immediate doubles. Pointers and other immediates encode into the
 * unused QNaN-with-sign-set bit pattern, which num_guard() makes
 * unreachable from user numbers (NaN -> 0, +/-Inf -> +/-1e308).
 *
 * Tag layout (high 16 bits):
 *   0xFFF8 tag 0 : NULL              (payload ignored)
 *   0xFFF9 tag 1 : BOOL              (low bit = value)
 *   0xFFFA tag 2 : reserved (SMI)    (reserved for future small-int)
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
typedef union { double d; uint64_t u; } EigsSlot;
#endif

#define SLOT_QNAN_MASK     0xFFF8000000000000ULL
#define SLOT_TAG_MASK      0xFFFF000000000000ULL
#define SLOT_PAYLOAD_MASK  0x0000FFFFFFFFFFFFULL

#define SLOT_NULL_BITS     0xFFF8000000000000ULL
#define SLOT_FALSE_BITS    0xFFF9000000000000ULL
#define SLOT_TRUE_BITS     0xFFF9000000000001ULL

#define TAG_BOOL           0xFFF9000000000000ULL
#define TAG_HEAP           0xFFFB000000000000ULL
#define TAG_SENTINEL       0xFFFF000000000000ULL

/* Predicates */

static inline int slot_is_num(EigsSlot s) {
    return (s.u & SLOT_QNAN_MASK) != SLOT_QNAN_MASK;
}
static inline int slot_is_null(EigsSlot s)    { return s.u == SLOT_NULL_BITS; }
static inline int slot_is_bool(EigsSlot s)    { return (s.u & SLOT_TAG_MASK) == TAG_BOOL; }
static inline int slot_is_heap(EigsSlot s)    { return (s.u & SLOT_TAG_MASK) == TAG_HEAP; }
/* #262 Step E: TAG_TRACKED is gone — a number is always an immediate, never a
 * heap-boxed observer-tracked Value. Heap is the only pointer tag. */
static inline int slot_is_ptr(EigsSlot s)     { return (s.u & SLOT_TAG_MASK) == TAG_HEAP; }
static inline int slot_is_numeric(EigsSlot s) { return slot_is_num(s); }

/* Accessors (caller must check the predicate first) */

static inline double   slot_as_num(EigsSlot s)    { return s.d; }
static inline int      slot_as_bool(EigsSlot s)   { return (int)(s.u & 1ULL); }
static inline Value   *slot_as_ptr(EigsSlot s)    { return (Value*)(uintptr_t)(s.u & SLOT_PAYLOAD_MASK); }
#define slot_as_heap     slot_as_ptr

/* Constructors */

static inline EigsSlot slot_from_num(double d)       { EigsSlot s; s.d = d;                                              return s; }
static inline EigsSlot slot_from_heap(Value *v)      { EigsSlot s; s.u = TAG_HEAP    | ((uint64_t)(uintptr_t)v & SLOT_PAYLOAD_MASK); return s; }
static inline EigsSlot slot_null(void)               { EigsSlot s; s.u = SLOT_NULL_BITS;  return s; }
static inline EigsSlot slot_true(void)               { EigsSlot s; s.u = SLOT_TRUE_BITS;  return s; }
static inline EigsSlot slot_false(void)              { EigsSlot s; s.u = SLOT_FALSE_BITS; return s; }
static inline EigsSlot slot_from_bool(int b)         { EigsSlot s; s.u = TAG_BOOL | (b ? 1ULL : 0ULL); return s; }

/* Single-thread refcount gate (g_vm_multithreaded) is now provided as a
 * bridge macro by eigenscript.h, which is already included transitively
 * by every site that includes this header. */

/* Refcount fast path:
 *   immediate (number / null / bool) -> no-op
 *   heap or tracked pointer          -> existing atomic refcount
 * The outer `& SLOT_QNAN_MASK` branch peels off numbers in one
 * predicted-not-taken test with zero memory access. */
static inline void slot_incref(EigsSlot s) {
    if ((s.u & SLOT_QNAN_MASK) == SLOT_QNAN_MASK) {
        uint64_t tag = s.u & SLOT_TAG_MASK;
        if (tag == TAG_HEAP) {
            Value *v = (Value*)(uintptr_t)(s.u & SLOT_PAYLOAD_MASK);
            if (!v->arena) {
                if (__builtin_expect(g_vm_multithreaded, 0))
                    __atomic_add_fetch(&v->refcount, 1, __ATOMIC_RELAXED);
                else
                    v->refcount++;
            }
        }
    }
}

static inline void slot_decref(EigsSlot s) {
    if ((s.u & SLOT_QNAN_MASK) == SLOT_QNAN_MASK) {
        uint64_t tag = s.u & SLOT_TAG_MASK;
        if (tag == TAG_HEAP) {
            Value *v = (Value*)(uintptr_t)(s.u & SLOT_PAYLOAD_MASK);
            if (!v->arena) {
                int newrc;
                if (__builtin_expect(g_vm_multithreaded, 0))
                    newrc = __atomic_sub_fetch(&v->refcount, 1, __ATOMIC_ACQ_REL);
                else
                    newrc = --v->refcount;
                if (newrc <= 0) free_value(v);
            }
        }
    }
}

/* Truthiness — used by JUMP_IF_FALSE / JUMP_IF_TRUE fast paths.
 * Immediate-number truthiness is a non-zero double; null and false
 * are falsy; everything else (heap, tracked) defers to caller-side
 * is_truthy() for now (Phase A keeps semantics identical). */
static inline int slot_truthy_immediate(EigsSlot s, int *out_decided) {
    if (slot_is_num(s)) { *out_decided = 1; return s.d != 0.0; }
    if (slot_is_null(s) || s.u == SLOT_FALSE_BITS) { *out_decided = 1; return 0; }
    if (s.u == SLOT_TRUE_BITS) { *out_decided = 1; return 1; }
    *out_decided = 0;
    return 0;
}

/* Boundary shims declared here, defined in eigenscript.c.
 *
 * slot_from_value (takes ownership of the input ref):
 *   - VAL_NUM -> immediate double, input decref'd (#262 Step E: numbers never
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
