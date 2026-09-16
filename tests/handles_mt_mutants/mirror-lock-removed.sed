# file: src/eigenscript.c
# #1161, the MIRROR half: the module namespace's env is still locked, but its
# dict mirror's keys[]/vals[] grow unsynchronized again. A module namespace is
# two structures; locking one of them is not locking the namespace.
/^void dict_set_hashed(/,/^}$/ {
  s|^            env_shared_lock(me);$|            /* mutant: mirror unlocked */;|
  s|^            env_shared_unlock(me);$|            /* mutant: mirror unlocked */;|
}
