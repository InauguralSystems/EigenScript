# file: src/trace.c
# Commit the record (the sink call + the FILE buffer append) AFTER releasing
# the tape mutex, so a sibling's record can overwrite g_rec_at / g_out_len
# between the unlock and the commit.
/^static void tape_emit_end(void) {$/,/^}$/ {
    s|sink_flush();               /\* commit-under-lock \*/|TAPE_END_UNLOCK|
    s|tape_unlock();|sink_flush();|
    s|TAPE_END_UNLOCK|tape_unlock();|
}
