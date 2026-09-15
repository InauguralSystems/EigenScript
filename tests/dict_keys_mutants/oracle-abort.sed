# file: tests/test_dict_keys_mt.sh
# Control for the crash branch of classify_kill (mechanical-gates §18: a crash
# rendered as silence is the worst failure a gate can have). The oracle dies
# before printing anything, so there is no named FAIL to classify — and that
# must read as KILLED, never as a survivor.
#
# It targets the ORACLE rather than the runtime on purpose: an aborting
# eigenscript still lets every probe row print its own FAIL line, so it would
# exercise the named-check branch, not this one.
s|^PASS=0$|exit 77\nPASS=0|
