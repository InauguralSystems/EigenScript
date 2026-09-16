# file: src/eigenscript.c
# fable's own loader mutant (NOT in tools/loader_mt_mutants.sh): a replaced module-namespace
# table is FREED immediately instead of retired while the process is multithreaded — the
# pre-#1144 free-under-reader, with every lock and the atomic publish left in place.
s|^    if (!module_ns_mt()) { free(old); return; }$|    free(old); return;|
