# file: src/trace.c
# Emit the #411 version header AFTER releasing the tape mutex, so a sibling
# state that is already recording can slip a record in between the sink
# becoming visible and its own header reaching it — and can be inside its
# own sink callback while the header is handed over. Killed by
# `set-sink-header` in src/embed_concurrent.c.
/^void trace_set_sink(/,/^}$/ {
    s|^        emit_header();.*$|        /* MUTANT set-sink-header-unlocked: deferred below */|
    s|^    tape_unlock();$|    tape_unlock();\n    if (cb) emit_header();|
}
