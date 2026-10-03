# file: src/builtins.c
# #1173: resolve a program-held task handle as a raw slot, recreating the ABA.
/^static Task \*task_handle_resolve(/,/^}$/ {
  s|Task \*t = (Task \*)handle_lookup(id, gen, HANDLE_TASK, \&why);|Task *t = (Task *)handle_lookup_slot(id, HANDLE_TASK); /* mutant: generation ignored */|
}
