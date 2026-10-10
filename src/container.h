#ifndef EIGENSCRIPT_CONTAINER_H
#define EIGENSCRIPT_CONTAINER_H

/* Container slot boundary (#1665 arm D).  The representation is Value ** in
 * B0; EIGS_SLOT_REHEARSAL deliberately presents boxed numbers as immediate
 * slots so users of this API can be proved ready for the later storage flip. */
#define EIGS_VIEW_RC (1 << 29)

typedef struct { Value v; } EigsView;

static inline EigsSlot eigs_container_slot(Value *v) {
#ifdef EIGS_SLOT_REHEARSAL
    if (v && v->type == VAL_NUM) return slot_from_num(VAL_NUM_RAW(v));
#endif
    return slot_from_heap(v);
}

/* A slot read is borrowed: it owns no reference and remains valid only until
 * the container is mutated.  In rehearsal a number is an immediate. */
static inline EigsSlot list_slot(const Value *list, int i) {
    return eigs_container_slot(list->data.list.items[i]);
}
static inline EigsSlot dict_value_slot(const Value *dict, int i) {
    return eigs_container_slot(dict->data.dict.vals[i]);
}

/* Return the logical type of a borrowed slot without allocating. */
static inline ValType slot_type(EigsSlot s) {
    if (slot_is_num(s)) return VAL_NUM;
    if (slot_is_null(s)) return VAL_NULL;
    if (slot_is_bool(s)) return VAL_BOOL;
    return slot_as_ptr(s)->type;
}
static inline Value *eigs_slot_ref(EigsSlot s) {
    if (slot_is_null(s)) return make_null();
    if (slot_is_bool(s)) return make_bool(slot_as_bool(s));
    return slot_as_ptr(s);
}
static inline ValType list_elem_type(const Value *list, int i) {
    return slot_type(list_slot(list, i));
}
static inline ValType dict_value_type(const Value *dict, int i) {
    return slot_type(dict_value_slot(dict, i));
}

/* Return the real heap pointer (including the immortal null/bool singleton),
 * or NULL when the element is numeric. */
static inline Value *list_get_ref(const Value *list, int i) {
    Value *v = list->data.list.items[i];
    return v && v->type == VAL_NUM ? NULL : v;
}
static inline Value *dict_value_get_ref(const Value *dict, int i) {
    Value *v = dict->data.dict.vals[i];
    return v && v->type == VAL_NUM ? NULL : v;
}

/* Numeric readers have the same strict/bool behavior as the Value readers:
 * required raises for every non-number, element raises for bool or in strict
 * mode, and optional treats null as absent. */
static inline double eigs_slot_num(EigsSlot s, const char *who) {
    if (slot_is_num(s)) return SLOT_NUM_RAW(s);
    if (slot_is_heap(s) && slot_as_ptr(s)->type == VAL_NUM)
        return eigs_num_arg(slot_as_ptr(s), who);
    return eigs_num_arg_slow(eigs_slot_ref(s), who);
}
static inline double eigs_slot_elem_num(EigsSlot s, const char *who) {
    if (slot_is_num(s)) return SLOT_NUM_RAW(s);
    Value *v = eigs_slot_ref(s);
    if (v && v->type == VAL_NUM) return eigs_num_arg(v, who);
    if (g_strict || (v && v->type == VAL_BOOL)) return eigs_num_arg_slow(v, who);
    return 0.0;
}
static inline int eigs_slot_opt_num(EigsSlot s, double *out, const char *who) {
    if (slot_is_null(s) || (slot_is_heap(s) && slot_as_ptr(s)->type == VAL_NULL)) return 0;
    if (slot_is_num(s)) { *out = SLOT_NUM_RAW(s); return 1; }
    if (slot_is_heap(s) && slot_as_ptr(s)->type == VAL_NUM) {
        *out = eigs_num_arg(slot_as_ptr(s), who); return 1;
    }
    (void)eigs_num_arg_slow(eigs_slot_ref(s), who);
    return 0;
}

/* A numeric view is a caller-owned, allocation-free Value facade.  Reference
 * slots return their real pointer.  The cleanup guard catches retaining or
 * decrefing a numeric facade: its sentinel refcount must be unchanged. */
static inline Value *slot_view(EigsSlot s, EigsView *view) {
    if (!slot_is_num(s) && slot_type(s) != VAL_NUM) return eigs_slot_ref(s);
    view->v.type = VAL_NUM;
    VAL_NUM_RAW(&view->v) = slot_is_num(s) ? SLOT_NUM_RAW(s)
                                           : eigs_num_arg(slot_as_ptr(s), "slot_view");
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
    if (view->v.type == VAL_NUM && view->v.refcount != 0 &&
        view->v.refcount != EIGS_VIEW_RC) {
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

/* Owned/return reads make numeric storage independent.  Reference values are
 * increfed by the owned form; return preserves the builtin direct-child
 * borrow protocol for references while numbers are always fresh. */
static inline Value *list_get_owned(const Value *list, int i) {
    Value *v = list->data.list.items[i];
    if (v->type == VAL_NUM) return make_num(VAL_NUM_RAW(v));
    val_incref(v);
    return v;
}
static inline Value *list_get_return(const Value *list, int i) {
    Value *v = list->data.list.items[i];
    return v->type == VAL_NUM ? make_num(VAL_NUM_RAW(v)) : v;
}
static inline Value *dict_value_get_owned(const Value *dict, int i) {
    Value *v = dict->data.dict.vals[i];
    if (v->type == VAL_NUM) return make_num(VAL_NUM_RAW(v));
    val_incref(v);
    return v;
}
static inline Value *dict_value_get_return(const Value *dict, int i) {
    Value *v = dict->data.dict.vals[i];
    return v->type == VAL_NUM ? make_num(VAL_NUM_RAW(v)) : v;
}

/* Compatibility reads for files not yet migrated in later batches. */
static inline Value *dict_get(Value *dict, const char *key) {
    return dict_get_ref_legacy(dict, key);
}
static inline Value *dict_get_hashed(Value *dict, const char *key, uint32_t h) {
    return dict_get_hashed_ref_legacy(dict, key, h);
}

/* Low-level compatibility accessors retain their pre-flip meaning. */
static inline Value *list_get_borrow(const Value *list, int i) { return list->data.list.items[i]; }
static inline Value *dict_value_get_borrow(const Value *dict, int i) { return dict->data.dict.vals[i]; }
static inline Value *dict_value_compat_ref(const Value *dict, int i) { return dict->data.dict.vals[i]; }
static inline void list_set_owned(Value *list, int i, Value *v) { list->data.list.items[i] = v; }
static inline void dict_value_set_owned(Value *dict, int i, Value *v) { dict->data.dict.vals[i] = v; }
static inline void list_set_borrow(Value *list, int i, Value *v) { val_incref(v); list_set_owned(list, i, v); }
static inline void dict_value_set_borrow(Value *dict, int i, Value *v) { val_incref(v); dict_value_set_owned(dict, i, v); }

/* Slot writes own exactly one container reference.  Owned consumes the slot;
 * append borrows it and therefore increfs.  Every double path applies
 * num_guard.  Before the flip list_set_num retains the exclusive-box reuse. */
static inline Value *eigs_slot_box(EigsSlot s) {
    if (slot_is_num(s)) return make_num(num_guard(SLOT_NUM_RAW(s)));
    Value *v = eigs_slot_ref(s); val_incref(v); return v;
}
static inline void list_set_slot_owned(Value *list, int i, EigsSlot s) {
    Value *old = list->data.list.items[i];
    Value *v = slot_is_num(s) ? make_num(num_guard(SLOT_NUM_RAW(s))) : eigs_slot_ref(s);
    list->data.list.items[i] = v;
    val_decref(old);
}
static inline void dict_value_set_slot_owned(Value *dict, int i, EigsSlot s) {
    Value *old = dict->data.dict.vals[i];
    Value *v = slot_is_num(s) ? make_num(num_guard(SLOT_NUM_RAW(s))) : eigs_slot_ref(s);
    dict->data.dict.vals[i] = v;
    val_decref(old);
}
static inline void list_append_slot(Value *list, EigsSlot s) {
    Value *v = eigs_slot_box(s); list_append_owned(list, v);
}
static inline void list_set_num(Value *list, int i, double d) {
    d = num_guard(d);
#ifndef EIGS_SLOT_REHEARSAL
    Value *old = list->data.list.items[i];
    if (old && old->type == VAL_NUM && old->refcount == 1) { VAL_NUM_RAW(old) = d; return; }
#endif
    list_set_slot_owned(list, i, slot_from_num(d));
}
static inline void list_append_num(Value *list, double d) { list_append_owned(list, make_num(num_guard(d))); }
static inline void dict_value_set_num(Value *dict, int i, double d) {
    d = num_guard(d);
#ifndef EIGS_SLOT_REHEARSAL
    Value *old = dict->data.dict.vals[i];
    if (old && old->type == VAL_NUM && old->refcount == 1) { VAL_NUM_RAW(old) = d; return; }
#endif
    dict_value_set_slot_owned(dict, i, slot_from_num(d));
}
static inline EigsSlot list_take_slot(Value *list, int i) {
    Value *v = list->data.list.items[i];
    EigsSlot s = eigs_container_slot(v);
    if (slot_is_num(s)) val_decref(v);
    memmove(&list->data.list.items[i], &list->data.list.items[i + 1],
            (size_t)(list->data.list.count - i - 1) * sizeof(Value *));
    list->data.list.count--;
    return s;
}
static inline EigsSlot dict_value_take_slot(Value *dict, int i) {
    Value *v = dict->data.dict.vals[i];
    EigsSlot s = eigs_container_slot(v);
    if (slot_is_num(s)) val_decref(v);
    return s;
}
static inline void list_move(Value *list, int dst, int src, int n) {
    memmove(&list->data.list.items[dst], &list->data.list.items[src], (size_t)n * sizeof(Value *));
}
static inline void list_sort(Value *list, int (*cmp)(const void *, const void *)) {
    qsort(list->data.list.items, (size_t)list->data.list.count, sizeof(Value *), cmp);
}

static inline int list_get_num(const Value *list, int i, double *out) { Value *v=list_get_borrow(list,i); if(!v||v->type!=VAL_NUM)return 0; *out=VAL_NUM_RAW(v); return 1; }
static inline int dict_value_get_num(const Value *dict, int i, double *out) { Value *v=dict_value_get_borrow(dict,i); if(!v||v->type!=VAL_NUM)return 0; *out=VAL_NUM_RAW(v); return 1; }
static inline int list_iter_count(const Value *list) { return list->data.list.count; }
static inline Value *list_iter_borrow(const Value *list, int i) { return list_get_borrow(list, i); }
static inline int dict_value_iter_count(const Value *dict) { return dict->data.dict.count; }
static inline Value *dict_value_iter_borrow(const Value *dict, int i) { return dict_value_get_borrow(dict, i); }

/* Raw storage is confined to bulk allocation/movement/destruction code. */
static inline Value **list_values_storage(Value *list) { return list->data.list.items; }
static inline Value ***list_values_storage_ref(Value *list) { return &list->data.list.items; }
static inline Value **dict_values_storage(Value *dict) { return dict->data.dict.vals; }
static inline Value ***dict_values_storage_ref(Value *dict) { return &dict->data.dict.vals; }

#endif
