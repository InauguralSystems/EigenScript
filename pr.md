# Fix GitHub issue #1162

This change makes interned names referenced by state-owned environments survive
attachment teardown without retaining every attachment's full intern table.
Promoted sandbox dictionary keys move to state ownership when the outer sandbox
run ends, so another attachment can release the value before its creator
detaches.  Regression coverage exercises both distinct-thread and same-thread
detach/reattach, including reads of the builtin result and dictionary keys.

## Thread-lifetime fault evidence

The planted fault removed the state-lifetime retention at detach while keeping
the detach/reattach test unchanged.  In the ThreadSanitizer build, the
`host-reattach` slice reported a **heap-use-after-free**: the reader's name
lookup read an `EnvNameIntern.name` allocation freed by the writer attachment's
`env_intern_table_unref` during `eigs_thread_detach`.  Restoring retention for
tables whose names are actually published into a state-owned environment made
the same slice TSan-clean.  The nonescaping `str of 1` loop is the inverse
control: its populated compilation table is not published and the state table
count remains constant across 128 attach/evaluate/detach cycles.
