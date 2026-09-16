# file: src/trace.c
# Leave the HISTORY tier guarded (as #827 already did with its spawn-time
# wildcard) and take the guard off the OCCURRENCE tier only — the exact
# pre-#1145 asymmetry the issue reports.
/^static int occ_set_has(const char \*name) {$/,/^}$/ {
    s|arm_lock();|;|
    s|arm_unlock();|;|
}
/^void trace_arm_occurrences_name(const char \*name) {$/,/^}$/ {
    s|arm_lock();|;|
    s|arm_unlock();|;|g
}
