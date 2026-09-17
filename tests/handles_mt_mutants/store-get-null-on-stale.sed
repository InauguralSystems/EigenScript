# file: src/ext_store.c
# ROUND 2 / G1: put back the exact shape a blind critic executed — the
# generation check still CATCHES the stale handle, and store_get then turns the
# NULL into a silent `make_null()` with no error. The ABA stops returning the
# wrong record and starts returning nothing, at exit status 0.
/^static Value\* builtin_store_get(/,/^}$/ {
  s|^    Store \*store = store_arg(arg->data.list.items\[0\], "store_get");$|    int mut_why = 0, mut_id = 0;\n    Store *store = get_store_why(arg->data.list.items[0], \&mut_why, \&mut_id);   /* mutant: no raise */|
}
