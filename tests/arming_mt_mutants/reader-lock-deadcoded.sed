# file: src/trace.c
# A critic's round-2 oracle-breaker: the READER's lock is still THERE, it is
# just never executed. A per-site grep finds the text and passes; only a
# runtime witness (the two-state harness under ThreadSanitizer) can tell
# presence from execution. This mutant exists to keep that distinction
# honest — see the train header's witness column.
/^static int arm_set_has(const char \*name) {$/,/^}$/ {
    s|^    arm_lock();$|    if (0) {\n    arm_lock();\n    }|
    s|^    arm_unlock();$|    if (0) {\n    arm_unlock();\n    }|
}
