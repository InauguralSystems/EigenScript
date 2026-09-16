# file: src/trace.c
# Gate the arming mutex on the PER-STATE multithreaded flag — the narrower
# spelling that is 0 on both threads of a two-embed-state host, so the lock is
# never taken in exactly the shape #1145(b) reports.
s|^static inline void arm_lock(void)   { pthread_mutex_lock(&g_arm_mu); }$|static inline void arm_lock(void)   { if (g_vm_multithreaded) pthread_mutex_lock(\&g_arm_mu); }|
s|^static inline void arm_unlock(void) { pthread_mutex_unlock(&g_arm_mu); }$|static inline void arm_unlock(void) { if (g_vm_multithreaded) pthread_mutex_unlock(\&g_arm_mu); }|
