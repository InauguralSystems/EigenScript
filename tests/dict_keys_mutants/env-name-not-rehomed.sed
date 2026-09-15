# file: src/eigenscript.c
# The module-namespace half of #1141, reverted. The dict key is still
# re-homed, so every plain-dict probe stays green; only the env BINDING NAME
# created by `M.k is v` on a worker goes back to the writing thread's table,
# and `keys of M` walks it after eigs_thread_detach frees it. This is the
# mutant that distinguishes "the dict is fixed" from "the namespace is fixed".
/^void env_set_local_hashed/,/^}$/ {
  s|    env->names\[env->count\] = __builtin_expect(g_vm_multithreaded, 0)|    env->names[env->count] = __builtin_expect(g_vm_multithreaded \&\& 0, 0)|
}
