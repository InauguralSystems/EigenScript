# file: src/builtins.c
# #1146 (1), the pre-fix shape: thread_join RESOLVES under handle_mutex and
# RELEASES only after pthread_join has returned, so the slot stays claimable
# for the whole join. Both joiners pass the lookup; both join one tid; the
# process hangs. Deterministic, not a race window — the second joiner is
# guaranteed to see a live slot because nothing removed it.
#
# ROUND 2: re-pointed at the 4-argument handle_lookup (round 2 gave it a `why`
# out-parameter so a failed resolve can say WHICH failure it was). The round-1
# spelling called the 3-argument form and no longer compiled — which the train
# reported as "SURVIVED (no binary)", the §19 misreading this very run then
# fixed: an unbuildable mutant is BROKEN, not caught and not survived.
/^Value\* builtin_thread_join(/,/^}$/ {
  s|^    ThreadHandle \*h = (ThreadHandle\*)handle_claim(hid, hgen, HANDLE_THREAD, \&why);$|    ThreadHandle *h = (ThreadHandle*)handle_lookup(hid, hgen, HANDLE_THREAD, \&why);|
  s|^    free(h);$|    handle_release(hid, hgen);\n    free(h);|
}
