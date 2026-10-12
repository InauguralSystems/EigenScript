/* #1665 arm D: direct proving ground for the EigsSlot container storage
 * (B0 API, B10 storage flip). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"

static int failed;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL:%d: %s\n", __LINE__, #x); failed = 1; } } while (0)

static int num_cmp(const void *a, const void *b) {
    double da = eigs_slot_num(*(const EigsSlot *)a, __func__);
    double db = eigs_slot_num(*(const EigsSlot *)b, __func__);
    return (da > db) - (da < db);
}

int main(int argc, char **argv) {
    EigsState *state = eigs_open();
    CHECK(state != NULL);
    if (argc == 2 && strcmp(argv[1], "--escape-view") == 0) {
        /* Planted fault: a builtin returning a numeric view (stack storage)
         * must abort in the real builtin-return compensation path. */
        static EigsView escaped;
        Value *arg = make_list(1);
        list_append_num(arg, 1.0);
        vm_borrow_compensate(arg, slot_view(slot_from_num(1665.0), &escaped), 1, NULL, NULL);
        return 99;
    }
    Value *list = make_list(8);
    Value *nested = make_list(1);
    Value *str = make_str("slot");
    list_append_num(list, 3.0);
    list_append_slot(list, eigs_container_slot(str));
    list_append_slot(list, eigs_container_slot(nested));
    list_append_slot(list, eigs_container_slot(make_null()));
    list_append_slot(list, eigs_container_slot(make_bool(1)));
    val_decref(str); val_decref(nested);

    /* Storage encodings: numbers immediate, null/bool singleton bits, refs heap. */
    EigsSlot *raw = list_values_storage(list);
    CHECK(slot_is_num(raw[0]) && SLOT_NUM_RAW(raw[0]) == 3.0);
    CHECK(slot_is_heap(raw[1]) && slot_is_heap(raw[2]));
    CHECK(raw[3].u == SLOT_NULL_BITS && raw[4].u == SLOT_TRUE_BITS);
    CHECK(str->refcount == 1);   /* one container ref; a list may also be GC-buffered */

    CHECK(slot_type(list_slot(list, 0)) == VAL_NUM);
    CHECK(list_elem_type(list, 1) == VAL_STR);
    CHECK(list_get_ref(list, 0) == NULL && list_get_ref(list, 1) != NULL);
    CHECK(eigs_slot_num(list_slot(list, 0), "test") == 3.0);
    CHECK(eigs_slot_elem_num(list_slot(list, 0), "test") == 3.0);
    double opt = 7.0;
    CHECK(!eigs_slot_opt_num(list_slot(list, 3), &opt, "test") && opt == 7.0);
    CHECK(eigs_slot_opt_num(list_slot(list, 0), &opt, "test") && opt == 3.0);
    {
        EIGS_VIEW(a); EIGS_VIEW(b);
        Value *av = list_get_view(list, 0, &a);
        list_append_num(list, 9.0);
        Value *bv = list_get_view(list, 5, &b);
        CHECK(av != bv && eigs_num_arg(av, "test") == 3.0 && eigs_num_arg(bv, "test") == 9.0);
        CHECK(list_get_view(list, 1, &a) == list_get_ref(list, 1));
    }
    Value *owned = list_get_owned(list, 0);
    Value *returned = list_get_return(list, 0);
    CHECK(owned != returned && owned->type == VAL_NUM && VAL_NUM_RAW(owned) == 3.0);
    val_decref(owned); val_decref(returned);
    list_set_num(list, 0, 4.0);
    list_set_slot_owned(list, 1, slot_from_heap(make_str("owned")));
    CHECK(eigs_slot_num(list_slot(list, 0), "test") == 4.0);
    /* A boxed number or a singleton stored through a heap slot is re-encoded. */
    list_set_slot_owned(list, 2, slot_from_heap(make_num(5.0)));
    CHECK(slot_is_num(list_values_storage(list)[2]));
    list_set_owned(list, 3, make_bool(0));
    CHECK(list_values_storage(list)[3].u == SLOT_FALSE_BITS);
    /* The NaN guard: the default x86 NaN must never be stored as null bits. */
    {
        int strict = g_strict;
        g_strict = 0;
        list_set_num(list, 4, -__builtin_nan(""));
        g_strict = strict;
        CHECK(slot_is_num(list_values_storage(list)[4]));
    }
    EigsSlot taken = list_take_slot(list, 0);
    CHECK(eigs_slot_num(taken, "test") == 4.0);
    slot_decref(taken);
    list_move(list, 0, 0, 1);

    Value *sort = make_list(3);
    list_append_num(sort, 2); list_append_num(sort, 1); list_append_num(sort, 3);
    list_sort(sort, num_cmp);
    CHECK(eigs_slot_num(list_slot(sort, 0), "test") == 1.0);

    /* Zero bits are 0.0: a calloc'd slot array reads as numbers. */
    Value *zeros = make_list(4);
    CHECK(slot_is_num(list_values_storage(zeros)[0]) && zeros->data.list.count == 0);

    Value *dict = make_dict(4);
    dict_set_owned(dict, "n", make_num(2));
    dict_set_owned(dict, "s", make_str("dict"));
    dict_set_owned(dict, "l", make_list(1));
    dict_set_owned(dict, "z", make_null());
    dict_set_owned(dict, "b", make_bool(0));
    int ni = env_hash_find_dict(dict, "n", env_hash_name("n"));
    int si = env_hash_find_dict(dict, "s", env_hash_name("s"));
    CHECK(dict_value_type(dict, ni) == VAL_NUM && dict_value_get_ref(dict, ni) == NULL);
    CHECK(slot_is_num(dict_values_storage(dict)[ni]));
    CHECK(eigs_slot_num(dict_value_slot(dict, ni), "test") == 2.0);
    { EIGS_VIEW(v); CHECK(eigs_num_arg(dict_value_get_view(dict, ni, &v), "test") == 2.0); }
    { EIGS_VIEW(v); Value *zv = dict_get_view(dict, "z", &v);
      CHECK(zv && zv->type == VAL_NULL && dict_get_view(dict, "missing", &v) == NULL); }
    { int found = 0; EigsSlot zs = dict_get_slot(dict, "z", &found);
      CHECK(found && slot_is_null(zs));
      (void)dict_get_slot(dict, "missing", &found); CHECK(!found); }
    owned = dict_value_get_owned(dict, ni); returned = dict_value_get_return(dict, ni);
    CHECK(owned != returned && VAL_NUM_RAW(owned) == 2.0);
    val_decref(owned); val_decref(returned);
    dict_value_set_num(dict, ni, 8.0);
    dict_value_set_slot_owned(dict, si, slot_from_heap(make_str("changed")));
    CHECK(eigs_slot_num(dict_value_slot(dict, ni), "test") == 8.0);
    taken = dict_value_take_slot(dict, ni);
    CHECK(eigs_slot_num(taken, "test") == 8.0 && slot_is_null(dict_value_slot(dict, ni)));
    slot_decref(taken);
    dict_value_set_owned(dict, ni, make_num(8.0));

    val_decref(zeros); val_decref(dict); val_decref(sort); val_decref(list);
    eigs_close(state);
    puts("container slots: PASS");
    return failed;
}
