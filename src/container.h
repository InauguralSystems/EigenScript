#ifndef EIGENSCRIPT_CONTAINER_H
#define EIGENSCRIPT_CONTAINER_H

/* Container slot boundary (#1665 arm D).  List items and dict values are
 * EigsSlot storage (B10, the flip).  Every stored slot is one of:
 *   - an immediate number: a double, always num_guard'ed (the default x86
 *     NaN 0xFFF8... is SLOT_NULL_BITS, so an unguarded double could read
 *     back as null), or an SMI, an int in [-2^47, 2^47) (#1758 design 2.1);
 *   - SLOT_NULL_BITS or a bool encoding (the immortal singletons are never
 *     stored as heap pointers);
 *   - a TAG_HEAP pointer owning one counted reference to a Value whose type
 *     is none of FLOAT / NULL / BOOL.  A VAL_INT there is an int outside the
 *     SMI range, a box (eigs_container_slot below keeps it, since R1.3).
 * All-zero bits are the number 0.0, not a vacancy: calloc'd storage reads as
 * zeros, so only slots below `count` are meaningful.  Nothing outside this
 * header touches the storage arrays except the bulk alloc/grow/free code that
 * goes through the *_values_storage helpers at the bottom. */
#define EIGS_VIEW_RC (1 << 29)

typedef struct { Value v; } EigsView;

/* Encode a BORROWED Value* as a storage slot: no reference changes hands.
 * A boxed number becomes an immediate, null and bool become their
 * encodings, everything else is a heap pointer.  C NULL encodes as null. */
static inline EigsSlot eigs_container_slot(Value *v) {
    if (!v || v->type == VAL_NULL) return slot_null();
    if (v->type == VAL_FLOAT) return slot_from_f64(num_guard(VAL_F64_RAW(v)));
    /* #1758 (design 2.1): container storage is canonical -- a small int is
     * an SMI, and only an int outside [-2^47, 2^47) stays its box. */
    if (__builtin_expect(v->type == VAL_INT, 0)) {
        int64_t i = VAL_I64_RAW(v);
        return (i >= SLOT_SMI_MIN && i <= SLOT_SMI_MAX) ? slot_from_int(i) : slot_from_heap(v);
    }
    if (v->type == VAL_BOOL) return slot_from_bool(v->data.boolean);
    return slot_from_heap(v);
}
/* Encode an OWNED Value* (consumes the caller's reference): a box that does
 * not become a heap slot is released here. */
static inline EigsSlot eigs_slot_adopt(Value *v) {
    EigsSlot s = eigs_container_slot(v);
    if (!slot_is_heap(s)) val_decref(v);
    return s;
}
/* Normalise a slot for storage.  Immediates are guarded; a heap slot that
 * points at a NUM / NULL / BOOL Value (a VM-internal box or a singleton) is
 * re-encoded as an immediate.  _owned consumes the slot's reference, _borrow
 * takes a new one for the container.  #1758: an SMI is already canonical
 * storage and is returned as it is (it owns no reference). */
static inline EigsSlot eigs_slot_store_owned(EigsSlot s) {
    if (slot_is_f64(s)) return slot_from_f64(num_guard(SLOT_F64_RAW(s)));
    if (slot_is_heap(s)) {
        Value *v = slot_as_ptr(s);
        if (v->type == VAL_FLOAT || v->type == VAL_INT || v->type == VAL_NULL || v->type == VAL_BOOL)
            return eigs_slot_adopt(v);   /* #1758: a small-int box becomes its SMI */
    }
    return s;
}
static inline EigsSlot eigs_slot_store_borrow(EigsSlot s) {
    if (slot_is_f64(s)) return slot_from_f64(num_guard(SLOT_F64_RAW(s)));
    if (slot_is_heap(s)) {
        EigsSlot e = eigs_container_slot(slot_as_ptr(s));
        slot_incref(e);
        return e;
    }
    return s;
}

/* VM read helpers.  Storage already holds immediates, so a value read is the
 * stored slot and an owned read is that slot plus a reference. */
static inline EigsSlot slot_read_value(EigsSlot s) { return s; }
static inline EigsSlot slot_read_owned(EigsSlot s) { slot_incref(s); return s; }

/* A slot read is borrowed: it owns no reference and remains valid only until
 * the container is mutated. */
static inline EigsSlot list_slot(const Value *list, int i) {
    return list->data.list.items[i];
}
static inline EigsSlot dict_value_slot(const Value *dict, int i) {
    return dict->data.dict.vals[i];
}

/* Return the logical type of a borrowed slot without allocating.  #1758: an
 * SMI's type is VAL_INT; any reserved tag refuses instead of being read
 * as a pointer. */
static inline ValType slot_type(EigsSlot s) {
    if (slot_is_f64(s)) return VAL_FLOAT;
    if (slot_is_null(s)) return VAL_NULL;
    if (slot_is_bool(s)) return VAL_BOOL;
    if (slot_is_heap(s)) return slot_as_ptr(s)->type;
    if (slot_is_smi(s)) return VAL_INT;
    eigs_slot_refuse("slot_type", s);
}
/* A slot's Value for a reader that wants a pointer: null and bool become
 * their singletons, a heap slot its Value.  #1758 R1.1: anything else (a
 * double, an SMI, a reserved tag) is a broken caller contract -- every caller
 * tests for a number first -- and aborts instead of being dereferenced. */
static inline Value *eigs_slot_ref(EigsSlot s) {
    if (slot_is_null(s)) return make_null();
    if (slot_is_bool(s)) return make_bool(slot_as_bool(s));
    if (slot_is_heap(s)) return slot_as_ptr(s);
    eigs_slot_refuse("eigs_slot_ref", s);
}
static inline ValType list_elem_type(const Value *list, int i) {
    return slot_type(list_slot(list, i));
}
static inline ValType dict_value_type(const Value *dict, int i) {
    return slot_type(dict_value_slot(dict, i));
}

/* Return the real heap pointer (including the immortal null/bool singleton),
 * or NULL when the element is an immediate number: a double or an SMI.  A
 * boxed int (|i| >= 2^47, #1758 R1.3) is a heap slot, so it comes back as its
 * non-NULL VAL_INT Value; type the element (list_elem_type) before reading. */
static inline Value *list_get_ref(const Value *list, int i) {
    EigsSlot s = list_slot(list, i);
    return (slot_is_f64(s) || slot_is_smi(s)) ? NULL : eigs_slot_ref(s);
}
static inline Value *dict_value_get_ref(const Value *dict, int i) {
    EigsSlot s = dict_value_slot(dict, i);
    return (slot_is_f64(s) || slot_is_smi(s)) ? NULL : eigs_slot_ref(s);
}

/* A numeric view is a caller-owned, allocation-free Value facade.  Reference
 * slots return their real pointer.  The cleanup guard catches retaining or
 * decrefing a numeric facade: its sentinel refcount must be unchanged.
 * #1758: an SMI's facade preserves its exact int Value kind. */
static inline Value *slot_view(EigsSlot s, EigsView *view) {
    /* Float storage exits before any int classification (#1758 cost gate). */
    if (!slot_is_f64(s)) {
        if (slot_is_smi(s)) {
            view->v.type = VAL_INT;
            VAL_I64_RAW(&view->v) = slot_smi_val(s);
            view->v.refcount = EIGS_VIEW_RC;
            return &view->v;
        }
        /* A heap VAL_INT is a real Value, returned as itself. */
        if (slot_type(s) != VAL_FLOAT) return eigs_slot_ref(s);
    }
    view->v.type = VAL_FLOAT;
    /* The branch above proves float storage; retain raw facade semantics
     * even for a direct-C nonfinite box, without a flag write or raise. */
    (void)slot_f64_value(s, &VAL_F64_RAW(&view->v));
    view->v.refcount = EIGS_VIEW_RC;
    return &view->v;
}
static inline Value *list_get_view(const Value *list, int i, EigsView *view) {
    return slot_view(list_slot(list, i), view);
}
static inline Value *dict_value_get_view(const Value *dict, int i, EigsView *view) {
    return slot_view(dict_value_slot(dict, i), view);
}
static inline void eigs_view_check(EigsView *view) {
    /* A valid facade (or an unused zero view) exits before kind checks. */
    if (view->v.refcount != 0 && view->v.refcount != EIGS_VIEW_RC &&
        (view->v.type == VAL_FLOAT || view->v.type == VAL_INT)) {
        fprintf(stderr, "%s:%d: EigenScript FATAL: numeric view refcount moved (%d)\n",
                __FILE__, __LINE__, view->v.refcount);
        abort();
    }
}
#if defined(__GNUC__) || defined(__clang__)
#define EIGS_VIEW(name) EigsView name __attribute__((cleanup(eigs_view_check))) = {{0}}
#else
#define EIGS_VIEW(name) EigsView name = {{0}}
#endif
/* Computed goto does not run cleanup attributes (and clang rejects jumping
 * out of their protected scope).  Dispatch loops use this form and call
 * eigs_view_check explicitly before every exit from the view's scope. */
#define EIGS_VIEW_NOCHECK(name) EigsView name = {{0}}

/* Final slot readers borrow a facade for the duration of the call. The
 * facade is never retained, so SMI, boxed-int and raise paths own no refs. */
__attribute__((unused))
static inline EigsNum eigs_slot_number(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_number_arg(slot_view(s, &view), who);
}
__attribute__((unused))
static inline EigsNum eigs_slot_elem_number(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_elem_number(slot_view(s, &view), who);
}
__attribute__((unused))
static inline int eigs_slot_opt_number(EigsSlot s, EigsNum *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_number(slot_view(s, &view), out, who);
}
__attribute__((unused))
static inline double eigs_slot_float(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_float_arg(slot_view(s, &view), who);
}
__attribute__((unused))
static inline double eigs_slot_elem_float(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_elem_float(slot_view(s, &view), who);
}
__attribute__((unused))
static inline int eigs_slot_opt_float(EigsSlot s, double *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_float(slot_view(s, &view), out, who);
}
__attribute__((unused))
static inline int64_t eigs_slot_int(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_int_arg(slot_view(s, &view), who);
}
__attribute__((unused))
static inline int64_t eigs_slot_elem_int(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_elem_int(slot_view(s, &view), who);
}
__attribute__((unused))
static inline int eigs_slot_opt_int(EigsSlot s, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_int(slot_view(s, &view), out, who);
}
__attribute__((unused))
static inline uint8_t eigs_slot_byte(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_byte_arg(slot_view(s, &view), who);
}
__attribute__((unused))
static inline uint8_t eigs_slot_elem_byte(EigsSlot s, const char *who) {
    EIGS_VIEW(view); return eigs_elem_byte(slot_view(s, &view), who);
}
__attribute__((unused))
static inline int eigs_slot_opt_byte(EigsSlot s, uint8_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_byte(slot_view(s, &view), out, who);
}
__attribute__((unused))
static inline int eigs_slot_int_range(EigsSlot s, int64_t lo, int64_t hi, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_int_arg_range(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_elem_int_range(EigsSlot s, int64_t lo, int64_t hi, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_elem_int_range(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_opt_int_range(EigsSlot s, int64_t lo, int64_t hi, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_int_range(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_bounded(EigsSlot s, double lo, double hi, int *out, const char *who) {
    EIGS_VIEW(view); return eigs_bounded_arg(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_elem_bounded(EigsSlot s, double lo, double hi, int *out, const char *who) {
    EIGS_VIEW(view); return eigs_elem_bounded(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_opt_bounded(EigsSlot s, double lo, double hi, int *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_bounded(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_magnitude(EigsSlot s, int64_t lo, int64_t hi, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_magnitude_arg(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_elem_magnitude(EigsSlot s, int64_t lo, int64_t hi, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_elem_magnitude(slot_view(s, &view), lo, hi, out, who);
}
__attribute__((unused))
static inline int eigs_slot_opt_magnitude(EigsSlot s, int64_t lo, int64_t hi, int64_t *out, const char *who) {
    EIGS_VIEW(view); return eigs_opt_magnitude(slot_view(s, &view), lo, hi, out, who);
}

/* Owned/return reads make numeric storage independent.  Reference values are
 * increfed by the owned form; return preserves the builtin direct-child
 * borrow protocol for references while numbers are always fresh (#1758: an
 * int's fresh Value comes from slot_to_value, the one place that boxes an
 * SMI). */
static inline Value *list_get_owned(const Value *list, int i) {
    return slot_to_value(list_slot(list, i));
}
static inline Value *list_get_return(const Value *list, int i) {
    EigsSlot s = list_slot(list, i);
    if (slot_is_smi(s)) return slot_to_value(s);
    return slot_is_f64(s) ? make_float(SLOT_F64_RAW(s)) : eigs_slot_ref(s);
}
static inline Value *dict_value_get_owned(const Value *dict, int i) {
    return slot_to_value(dict_value_slot(dict, i));
}
__attribute__((unused))
static inline Value *dict_value_get_return(const Value *dict, int i) {
    EigsSlot s = dict_value_slot(dict, i);
    if (slot_is_smi(s)) return slot_to_value(s);
    return slot_is_f64(s) ? make_float(SLOT_F64_RAW(s)) : eigs_slot_ref(s);
}

/* Keyed reads (eigenscript.c).  The slot is borrowed from the dict (for a
 * module namespace, from its refreshed mirror); *found says whether the key
 * exists, since every slot value -- including null -- is a valid entry. */
EigsSlot dict_get_hashed_slot(Value *dict, const char *key, uint32_t h, int *found);
static inline EigsSlot dict_get_slot(Value *dict, const char *key, int *found) {
    return dict_get_hashed_slot(dict, key, 0, found);
}
/* View of a keyed value, or C NULL when the key is absent. */
static inline Value *dict_get_view(Value *dict, const char *key, EigsView *view) {
    int found;
    EigsSlot s = dict_get_slot(dict, key, &found);
    return found ? slot_view(s, view) : NULL;
}

/* Raw element stores: the caller has already released (or moved) the slot's
 * previous occupant.  The Value* form consumes the caller's reference. */
static inline void list_set_owned(Value *list, int i, Value *v) {
    list->data.list.items[i] = eigs_slot_adopt(v);
}
static inline void dict_value_set_owned(Value *dict, int i, Value *v) {
    dict->data.dict.vals[i] = eigs_slot_adopt(v);
}

/* Slot writes own exactly one container reference.  Owned consumes the slot;
 * append borrows it and therefore increfs.  Every double path applies
 * num_guard. */
static inline Value *eigs_slot_box(EigsSlot s) {
    if (slot_is_f64(s)) return make_float(num_guard(SLOT_F64_RAW(s)));
    if (slot_is_smi(s)) return slot_to_value(s);   /* #1758: kind-preserving */
    Value *v = eigs_slot_ref(s); val_incref(v); return v;
}
static inline __attribute__((always_inline)) void
list_set_slot_owned(Value *list, int i, EigsSlot s) {
    EigsSlot old = list->data.list.items[i];
    list->data.list.items[i] = eigs_slot_store_owned(s);
    slot_decref(old);
}
static inline void dict_value_set_slot_owned(Value *dict, int i, EigsSlot s) {
    EigsSlot old = dict->data.dict.vals[i];
    dict->data.dict.vals[i] = eigs_slot_store_owned(s);
    slot_decref(old);
}
/* Grow a list by one slot (sandbox-charged).  0 = refused: the catchable
 * EK_SANDBOX is already raised and the append must be dropped. */
int list_reserve_one(Value *list);
static inline void list_append_slot(Value *list, EigsSlot s) {
    if (!list_reserve_one(list)) return;
    list->data.list.items[list->data.list.count++] = eigs_slot_store_borrow(s);
}
/* Typed container writers own exactly one stored reference. _rewrite_f64
 * receives an already-normalised double, matching the existing fast store.
 * An int outside the SMI range owns the box slot_from_int creates. */
__attribute__((unused))
static inline int list_rewrite_f64(const Value *v, int i, double n) {
    EigsSlot old = list_slot(v, i);
    v->data.list.items[i] = slot_from_f64(n);
    slot_decref(old); return 1;
}
__attribute__((unused))
static inline void list_set_f64(Value *v, int i, double n) {
    list_rewrite_f64(v, i, num_guard(n));
}
__attribute__((unused))
static inline int list_get_f64(const Value *v, int i, double *out) {
    return slot_f64_value(list_slot(v, i), out);
}
__attribute__((unused))
static inline int dict_value_rewrite_f64(const Value *v, int i, double n) {
    EigsSlot old = dict_value_slot(v, i);
    v->data.dict.vals[i] = slot_from_f64(n);
    slot_decref(old); return 1;
}
__attribute__((unused))
static inline void dict_value_set_f64(Value *v, int i, double n) {
    dict_value_rewrite_f64(v, i, num_guard(n));
}
__attribute__((unused))
static inline int dict_value_get_f64(const Value *v, int i, double *out) {
    return slot_f64_value(dict_value_slot(v, i), out);
}
__attribute__((unused))
static inline void list_append_f64(Value *v, double n) {
    n = num_guard(n);
    if (!list_reserve_one(v)) return;
    v->data.list.items[v->data.list.count++] = slot_from_f64(n);
}
__attribute__((unused))
static inline int list_rewrite_int(const Value *v, int i, int64_t n) {
    EigsSlot old = list_slot(v, i);
    v->data.list.items[i] = slot_from_int(n);
    slot_decref(old); return 1;
}
__attribute__((unused))
static inline void list_set_int(Value *v, int i, int64_t n) {
    list_rewrite_int(v, i, n);
}
__attribute__((unused))
static inline int list_get_int(const Value *v, int i, int64_t *out) {
    return slot_int_value(list_slot(v, i), out);
}
__attribute__((unused))
static inline int dict_value_rewrite_int(const Value *v, int i, int64_t n) {
    EigsSlot old = dict_value_slot(v, i);
    v->data.dict.vals[i] = slot_from_int(n);
    slot_decref(old); return 1;
}
__attribute__((unused))
static inline void dict_value_set_int(Value *v, int i, int64_t n) {
    dict_value_rewrite_int(v, i, n);
}
__attribute__((unused))
static inline int dict_value_get_int(const Value *v, int i, int64_t *out) {
    return slot_int_value(dict_value_slot(v, i), out);
}
__attribute__((unused))
static inline void list_append_int(Value *v, int64_t n) {

    if (!list_reserve_one(v)) return;
    v->data.list.items[v->data.list.count++] = slot_from_int(n);
}

/* Remove element i, shifting the tail down; the caller owns the result. */
static inline EigsSlot list_take_slot(Value *list, int i) {
    EigsSlot s = list->data.list.items[i];
    memmove(&list->data.list.items[i], &list->data.list.items[i + 1],
            (size_t)(list->data.list.count - i - 1) * sizeof(EigsSlot));
    list->data.list.count--;
    return s;
}
/* Detach value i (left holding null); the caller owns the result. */
static inline EigsSlot dict_value_take_slot(Value *dict, int i) {
    EigsSlot s = dict->data.dict.vals[i];
    dict->data.dict.vals[i] = slot_null();
    return s;
}
static inline void list_move(Value *list, int dst, int src, int n) {
    memmove(&list->data.list.items[dst], &list->data.list.items[src], (size_t)n * sizeof(EigsSlot));
}
static inline void dict_value_move(Value *dict, int dst, int src, int n) {
    memmove(&dict->data.dict.vals[dst], &dict->data.dict.vals[src], (size_t)n * sizeof(EigsSlot));
}
/* The comparator receives `const EigsSlot *` element pointers. */
static inline void list_sort(Value *list, int (*cmp)(const void *, const void *)) {
    qsort(list->data.list.items, (size_t)list->data.list.count, sizeof(EigsSlot), cmp);
}

/* Raw storage is confined to bulk allocation/movement/destruction code. */
__attribute__((unused))
static inline EigsSlot *list_values_storage(Value *list) { return list->data.list.items; }
static inline EigsSlot **list_values_storage_ref(Value *list) { return &list->data.list.items; }
static inline EigsSlot *dict_values_storage(Value *dict) { return dict->data.dict.vals; }
static inline EigsSlot **dict_values_storage_ref(Value *dict) { return &dict->data.dict.vals; }

#endif
