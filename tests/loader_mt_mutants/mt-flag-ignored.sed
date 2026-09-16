# file: src/eigenscript.c
# Ask only the per-STATE `multithreaded` flag, which is 0 on every thread of
# a two-state embed host: the retire list is then drained (and the old table
# freed) while a sibling is still probing it.
s|^    if (eigs_process_thread_count() > 1) return 1;$|    /* mutant: per-state flag only */|
