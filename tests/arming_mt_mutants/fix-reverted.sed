# file: src/trace.c
# Neutralise the #1145 guard entirely: the arming sets go back to being
# reallocated with no mutex at all.
s|^static inline void arm_lock(void)   { pthread_mutex_lock(&g_arm_mu); }$|static inline void arm_lock(void)   { (void)0; }|
s|^static inline void arm_unlock(void) { pthread_mutex_unlock(&g_arm_mu); }$|static inline void arm_unlock(void) { (void)0; }|
