# file: src/trace.c
# Restore the pre-round-4 hand-off: give the sink the WHOLE emit window in one
# call instead of one call per newline-terminated record. A window that stages
# a scope transition (`S <fn> <depth> <serial>`) or an `O cfg` diff in front of
# its A/N record then arrives as ONE multi-record call, and a consumer that
# maps one call to one journal entry (EigenOS M11 — the shape eigs_embed.h and
# docs/EMBEDDING.md promise) silently drops every record after the first.
# The byte STREAM is byte-identical either way, so only a per-CALL check sees
# this: src/embed_concurrent.c's sink/O-cfg multi_rec and calls==lines rows.
/^static void sink_hand_off(const char \*p, size_t left) {$/,/^}$/ {
    s|^    while (left) {$|    if (left) {|
    s|^        size_t rec = 0;$|        size_t rec = left;|
    s|^        while (rec < left .*$||
    s|^        if (rec < left) rec++;.*$||
    s|^        p += rec;$|        (void)p;|
    s|^        left -= rec;$|        left = 0;|
}
