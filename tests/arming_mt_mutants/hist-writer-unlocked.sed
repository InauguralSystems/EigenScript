# file: src/trace.c
# fable's own arming mutant (NOT in tools/arming_mt_mutants.sh): the HISTORY tier's writer
# (trace_arm_history_name) drops its hold while arm_lock()/arm_unlock() stay real and every
# other site stays locked — the two-state `prev of` shape reallocs g_arm_names unguarded.
/^void trace_arm_history_name(const char \*name) {$/,/^}$/ {
    s|^    arm_lock();  .*$|    /* mutant: no hold */|
    s|^    if (arm_set_has_locked(name)) { arm_unlock(); return; }$|    if (arm_set_has_locked(name)) { return; }|
    s|        if (!nn) { arm_unlock(); trace_arm_history_all(); return; }|        if (!nn) { trace_arm_history_all(); return; }|
    s|    if (!copy) { arm_unlock(); trace_arm_history_all(); return; }|    if (!copy) { trace_arm_history_all(); return; }|
    s|^    arm_unlock();$|    /* mutant: no release */|
}
