# file: src/eigenscript.c
# Drop the module-namespace writer mutex, so two attaches can interleave
# inside one table rebuild.
s|pthread_mutex_lock(&g_module_ns_mu);|;|g
s|pthread_mutex_unlock(&g_module_ns_mu);|;|g
