# file: src/eigenscript.c
# Put the in-flight load stack back on ONE shared owner (the first thread to
# reach each entry point), i.e. the pre-#1144 per-STATE behaviour.
s|^    EigsThread \*th = eigs_current;$|    static EigsThread *g_mut_first_th; if (!g_mut_first_th) g_mut_first_th = eigs_current; EigsThread *th = g_mut_first_th;|
