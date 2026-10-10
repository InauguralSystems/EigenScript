#ifndef EIGENSCRIPT_CONTAINER_H
#define EIGENSCRIPT_CONTAINER_H

/* Container element access boundary (#1665 arm D).
 *
 * Storage is still Value ** in step 1.  Step 2 changes only these helpers to
 * decode EigsSlot storage.  A borrowed getter is valid until the next
 * container mutation and must not be decref'd.  For an immediate numeric slot
 * step 2 will materialise into per-thread scratch Value storage; callers that
 * retain a value must therefore use the owned getter.  This avoids allocating
 * on the overwhelmingly common inspect-and-discard path, while the owned API
 * gives retaining callers a stable heap Value.
 *
 * *_set_owned consumes the caller's reference and writes it into a slot whose
 * previous ownership has already been dealt with by the caller (or which is
 * vacant).  *_set_borrow adds the container's reference before writing.  The
 * setters intentionally do not release the displaced element: this preserves
 * the existing low-level mutation contract and makes replacement ordering
 * explicit at call sites.
 */
static inline Value *list_get_borrow(const Value *list, int i) {
    return list->data.list.items[i];
}
static inline Value *list_get_owned(const Value *list, int i) {
    Value *v = list_get_borrow(list, i);
    val_incref(v);
    return v;
}
static inline void list_set_owned(Value *list, int i, Value *v) {
    list->data.list.items[i] = v;
}
static inline void list_set_borrow(Value *list, int i, Value *v) {
    val_incref(v);
    list_set_owned(list, i, v);
}
static inline int list_get_num(const Value *list, int i, double *out) {
    Value *v = list_get_borrow(list, i);
    if (!v || v->type != VAL_NUM) return 0;
    *out = VAL_NUM_RAW(v);
    return 1;
}
static inline int list_iter_count(const Value *list) { return list->data.list.count; }
static inline Value *list_iter_borrow(const Value *list, int i) { return list_get_borrow(list, i); }

static inline Value *dict_value_get_borrow(const Value *dict, int i) {
    return dict->data.dict.vals[i];
}
static inline Value *dict_value_get_owned(const Value *dict, int i) {
    Value *v = dict_value_get_borrow(dict, i);
    val_incref(v);
    return v;
}
static inline void dict_value_set_owned(Value *dict, int i, Value *v) {
    dict->data.dict.vals[i] = v;
}
static inline void dict_value_set_borrow(Value *dict, int i, Value *v) {
    val_incref(v);
    dict_value_set_owned(dict, i, v);
}
static inline int dict_value_get_num(const Value *dict, int i, double *out) {
    Value *v = dict_value_get_borrow(dict, i);
    if (!v || v->type != VAL_NUM) return 0;
    *out = VAL_NUM_RAW(v);
    return 1;
}
static inline int dict_value_iter_count(const Value *dict) { return dict->data.dict.count; }
static inline Value *dict_value_iter_borrow(const Value *dict, int i) { return dict_value_get_borrow(dict, i); }

/* Raw storage is confined to bulk allocation/movement/destruction code. */
static inline Value **list_values_storage(Value *list) { return list->data.list.items; }
static inline Value ***list_values_storage_ref(Value *list) { return &list->data.list.items; }
static inline Value **dict_values_storage(Value *dict) { return dict->data.dict.vals; }
static inline Value ***dict_values_storage_ref(Value *dict) { return &dict->data.dict.vals; }

#endif
