# file: src/eigenscript.c
# #1161: restore the old "shared env" predicate. `parent == NULL` is true of
# the sealed roots and FALSE of every imported module's namespace env, so the
# #607 lock stops engaging for exactly the envs two workers extend.
s|^    return __builtin_expect(g_vm_multithreaded, 0) \&\& e->mt_shared;$|    return __builtin_expect(g_vm_multithreaded, 0) \&\& e->parent == NULL;   /* mutant */|
