# file: src/eigs_embed.c
# Reintroduce the round-2 #1143 decide-then-decrement TOCTOU: read the live
# state count, THEN release, and decide on the stale read. Two concurrent
# eigs_close calls both see count == 2, neither believes it is last, and the
# process tape survives with zero live states.
#
# This mutant has NO behavioural kill and is not expected to gain one: the
# critic measured it killed 0/10 by the whole behavioural train and 0/2000 by
# a barrier'd double-close stress, on the FIXED tree and on the bug alike —
# the window is a few instructions wide and unobservable from a harness. It
# is enrolled because the class is closed STRUCTURALLY, and the structural
# check kills it deterministically: tests/test_trace_mt.sh's
# `close-count-toctou` rows fail on the count read inside eigs_close and on
# the count reader gaining a second caller.
s|    int last_state = eigs_process_state_release();|    int last_state = (eigs_process_state_count() == 1);\n    eigs_process_state_release();|
