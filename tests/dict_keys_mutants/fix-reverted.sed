# file: src/eigenscript.c
# Revert the #1141 fix at its site: the multithreaded arm interns into the
# WRITING THREAD's table again, exactly as main did before this change, so a
# key written by a worker dies with the worker. The gate itself is left in
# place, which is what makes this mutant distinct from mt-flag-ignored: the
# branch is still taken, it just no longer re-homes.
/^void dict_set_hashed_raw/,/^}$/ s|interned = (char \*)shared_intern_key(key);|interned = env_intern_name(key);|
