# file: src/trace.c
# Remove the sink-only staging rewind in sink_flush. Every record is still
# whole and every byte still reaches the sink, so the tape oracles stay
# green — but the output buffer now grows WITH THE TAPE on the one profile
# (freestanding, EigenOS M11's journal) that has no file to spill to.
# Killed by `sink-only-bounded` in src/embed_concurrent.c, which pins
# trace_out_capacity() across >= 10 MB of sink bytes.
s|^    if (!g_trace_fp) g_out_len = g_rec_at;.*$|    if (!g_trace_fp) { /* MUTANT sink-only-no-drop: no rewind */ }|
