# file: src/eigenscript.c
# Drop the module-cache mutex — the pre-#1144 unlocked realloc.
s|pthread_mutex_lock(&st->module_lock);|;|g
s|pthread_mutex_unlock(&st->module_lock);|;|g
