# file: src/eigenscript.c
# Revert the #1141-class re-home: the binding NAME a worker's module-level
# code creates in the shared root env goes back to the WRITING THREAD's
# intern table, freed at eigs_thread_detach.
s|? (char \*)shared_intern_key(interned)|? (char *)interned|
