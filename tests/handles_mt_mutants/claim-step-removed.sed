# file: src/eigenscript.c
# #1146 (1): handle_claim resolves but does NOT detach the slot, so every
# holder of the handle can claim it. Two concurrent joiners then both call
# pthread_join on one tid — POSIX UB, and on glibc the second never wakes.
# The kill is the CLOCK, not a wrong answer: handles_double_join stops.
/^void\* handle_claim(/,/^}$/ {
  s|^        sl->ptr = NULL;.*$|        /* mutant: claim step removed */;|
}
