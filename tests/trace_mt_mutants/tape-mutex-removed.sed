# file: src/trace.c
s/static void tape_lock(void)   { pthread_mutex_lock(\&g_tape_mu); }/static void tape_lock(void)   { }/
s/static void tape_unlock(void) { pthread_mutex_unlock(\&g_tape_mu); }/static void tape_unlock(void) { }/
