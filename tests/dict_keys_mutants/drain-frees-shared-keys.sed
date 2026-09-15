# file: src/eigenscript.c
# The detach path frees the keys the fix promised would outlive every thread:
# the push lands in the WRITING THREAD's intern table instead of the
# process-global one, so env_intern_table_unref() at eigs_thread_detach frees
# the node the parent's dict still points at. The call site is untouched — a
# reviewer reading dict_set_hashed_raw sees a correct fix.
s|    it->next = g_shared_key_interns\[bucket\];|    it->next = g_env_name_interns[bucket];|
s|    g_shared_key_interns\[bucket\] = it;|    g_env_name_interns[bucket] = it;|
