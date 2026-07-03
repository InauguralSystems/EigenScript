/* Harness entry for the freestanding-profile smoke: mirrors how EigenOS
 * consumes the runtime — through eigs_embed.h with SOURCE STRINGS, never
 * a filesystem path. The harness itself is hosted (argv[1] is the
 * program text), the runtime under test is the freestanding profile. */
#include <stdio.h>
#include "../src/eigs_embed.h"

/* A one-module source provider, standing in for EigenOS's ROM bundle:
 * proves `import` works in the freestanding profile with no filesystem. */
static const char *fs_smoke_provider(const char *name, void *ud) {
    (void)ud;
    if (name && name[0]=='t' && name[1]=='i' && name[2]=='n' && name[3]=='y' && !name[4])
        return "t is 41\nanswer is t + 1\n";
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: %s '<eigenscript source>'\n", argv[0]); return 2; }
    EigsState *st = eigs_open();
    if (!st) { fprintf(stderr, "eigs_open failed\n"); return 2; }
    eigs_set_source_provider(fs_smoke_provider, 0);
    EigsValue *v = eigs_eval_string(argv[1]);
    int rc = 0;
    if (eigs_has_error()) {
        const char *msg = eigs_last_error_message();
        fprintf(stderr, "error: %s\n", msg ? msg : "(no message)");
        rc = 1;
    }
    if (v) eigs_value_release(v);
    eigs_close(st);
    return rc;
}
