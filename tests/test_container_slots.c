/* #1665 B0: direct proving ground for the Value** slot boundary. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "eigs_embed.h"
#include "eigenscript.h"
#include "vm.h"

static int failed;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL:%d: %s\n", __LINE__, #x); failed = 1; } } while (0)

static int num_cmp(const void *a, const void *b) {
    const Value *va = *(Value *const *)a, *vb = *(Value *const *)b;
    double da = eigs_num_arg(va, __func__), db = eigs_num_arg(vb, __func__);
    return (da > db) - (da < db);
}

int main(int argc, char **argv) {
    EigsState *state = eigs_open();
    CHECK(state != NULL);
#ifdef EIGS_SLOT_TEST_HOOK
    if (argc == 2 && strcmp(argv[1], "--escape-view") == 0) {
        Value *arg = make_list(1);
        list_append_num(arg, 1.0);
        vm_borrow_compensate(arg, eigs_test_builtin_number_view(), 1, NULL, NULL);
        return 99;
    }
#else
    (void)argc; (void)argv;
#endif
    Value *list = make_list(8);
    Value *nested = make_list(1);
    Value *str = make_str("slot");
    list_append_num(list, 3.0);
    list_append_slot(list, eigs_container_slot(str));
    list_append_slot(list, eigs_container_slot(nested));
    list_append_slot(list, eigs_container_slot(make_null()));
    list_append_slot(list, eigs_container_slot(make_bool(1)));
    val_decref(str); val_decref(nested);

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
    CHECK(owned != list_get_borrow(list, 0) && returned != list_get_borrow(list, 0));
    val_decref(owned); val_decref(returned);
    list_set_num(list, 0, 4.0);
    list_set_slot_owned(list, 1, slot_from_heap(make_str("owned")));
    CHECK(eigs_slot_num(list_slot(list, 0), "test") == 4.0);
    EigsSlot taken = list_take_slot(list, 0);
    CHECK(eigs_slot_num(taken, "test") == 4.0);
    slot_decref(taken);
    list_move(list, 0, 0, 1);

    Value *sort = make_list(3);
    list_append_num(sort, 2); list_append_num(sort, 1); list_append_num(sort, 3);
    list_sort(sort, num_cmp);
    CHECK(eigs_slot_num(list_slot(sort, 0), "test") == 1.0);

    Value *dict = make_dict(4);
    dict_set_owned(dict, "n", make_num(2));
    dict_set_owned(dict, "s", make_str("dict"));
    dict_set_owned(dict, "l", make_list(1));
    dict_set_owned(dict, "z", make_null());
    dict_set_owned(dict, "b", make_bool(0));
    int ni = env_hash_find_dict(dict, "n", env_hash_name("n"));
    int si = env_hash_find_dict(dict, "s", env_hash_name("s"));
    CHECK(dict_value_type(dict, ni) == VAL_NUM && dict_value_get_ref(dict, ni) == NULL);
    CHECK(eigs_slot_num(dict_value_slot(dict, ni), "test") == 2.0);
    { EIGS_VIEW(v); CHECK(eigs_num_arg(dict_value_get_view(dict, ni, &v), "test") == 2.0); }
    owned = dict_value_get_owned(dict, ni); returned = dict_value_get_return(dict, ni);
    CHECK(owned != dict_value_get_borrow(dict, ni) && returned != dict_value_get_borrow(dict, ni));
    val_decref(owned); val_decref(returned);
    dict_value_set_num(dict, ni, 8.0);
    dict_value_set_slot_owned(dict, si, slot_from_heap(make_str("changed")));
    CHECK(eigs_slot_num(dict_value_slot(dict, ni), "test") == 8.0);
    taken = dict_value_take_slot(dict, ni);
    CHECK(eigs_slot_num(taken, "test") == 8.0);
    slot_decref(taken);
    dict_value_set_owned(dict, ni, make_num(8.0));

    val_decref(dict); val_decref(sort); val_decref(list);
    eigs_close(state);
    puts("container slots: PASS");
    return failed;
}
