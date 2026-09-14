# file: src/trace.c
s/if (g_sink_len == TRACE_SINK_LINEBUF || c == '\\n') sink_flush();/if (g_sink_len == TRACE_SINK_LINEBUF) sink_flush();/
/static void tape_emit_end/,/^}/ {
    s/sink_flush();/TAPE_END_FLUSH/
    s/tape_unlock();/sink_flush();/
    s/TAPE_END_FLUSH/tape_unlock();/
}
