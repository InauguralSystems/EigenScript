# file: src/eigenscript.c
# fable r2 oracle-breaker: eigs_module_cache_put keeps its lock but forgets the unlock on the
# lost-race return. Structural rows count unlocks with `-ge lock`, so they stay green; the losing
# importer then self-deadlocks in eigs_module_cache_get.
/^int eigs_module_cache_put(const char \*abs_path, Value \*dict, Env \*env) {$/,/^}$/ {
    /return 0;                    \/\* another thread won the race \*\//{
        x
        s/.*//
        x
    }
    s|^            pthread_mutex_unlock(&st->module_lock);$|            /* r2 mutant: unlock forgotten on the lost-race exit */|
}
