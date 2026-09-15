# file: src/eigenscript.c
# Take the single-threaded fast path unconditionally. The re-homing code is
# still present and still correct; nothing ever reaches it, which is the
# shape a future "optimisation" of the gate would have.
/^void dict_set_hashed_raw/,/^}$/ s|__builtin_expect(g_vm_multithreaded, 0)|__builtin_expect(0, 0)|
