/* Test-only observation at the real libpq boundary. Never logs credentials. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libpq-fe.h>

PGconn *PQconnectdbParams(const char *const *keywords,
                         const char *const *values, int expand_dbname) {
    PGconn *(*real_connect)(const char *const *, const char *const *, int) =
        dlsym(RTLD_NEXT, "PQconnectdbParams");
    const char *path = getenv("EIGS_DB_CONNECT_TRACE");
    if (path) {
        FILE *trace = fopen(path, "a");
        if (!trace) abort();
        int found = 0;
        for (size_t i = 0; keywords[i]; i++) {
            if (strcmp(keywords[i], "connect_timeout") == 0) {
                fprintf(trace, "timeout=%s\n", values[i] ? values[i] : "<null>");
                found++;
            }
        }
        fprintf(trace, "count=%d expand_dbname=%d\n", found, expand_dbname);
        if (fclose(trace) != 0) abort();
    }
    if (!real_connect) abort();
    return real_connect(keywords, values, expand_dbname);
}
