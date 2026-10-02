# file: src/task.c
# A blocked join that forgets its generation can resolve a recycled slot.
s/Task \*jt = (Task \*)handle_lookup(target, target_gen, HANDLE_TASK, \&why);/Task *jt = sched_lookup(s, target); \/\* mutant: blocked join generation discarded *\//
