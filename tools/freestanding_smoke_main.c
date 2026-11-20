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
    if (argc == 2 && argv[1][0] == '-' && argv[1][1] == '-' &&
        argv[1][2] == 's' && argv[1][3] == 't' && argv[1][4] == 'r' &&
        argv[1][5] == 'i' && argv[1][6] == 'c' && argv[1][7] == 't' &&
        argv[1][8] == '-' && argv[1][9] == 'a' && argv[1][10] == 'p' &&
        argv[1][11] == 'i' && argv[1][12] == 0) {
        eigs_state_set_strict_guards(NULL, 1);
        eigs_state_set_strict_arithmetic(NULL, 1);
        EigsState *defaults = eigs_open();
        if (!defaults) return 2;
        EigsValue *v = eigs_eval_string("abs of \"x\"");
        if (v || !eigs_has_error()) return 1;
        eigs_value_release(v);
        eigs_close(defaults);
        puts("strict creation default works");

        EigsState *soft = eigs_open();
        if (!soft) return 2;
        eigs_state_set_strict_guards(soft, 0);
        eigs_state_set_strict_arithmetic(soft, 0);
        v = eigs_eval_string("abs of \"x\"");
        if (!v || eigs_has_error() || eigs_value_as_num(v) != 0.0) return 1;
        eigs_value_release(v);
        eigs_close(soft);

        EigsState *strict = eigs_state_new();
        if (!strict) return 2;
        /* Zero first, so that the nonzero call below is what turns the guards on. */
        eigs_state_set_strict_guards(strict, 0);
        eigs_state_set_strict_arithmetic(strict, 0);
        eigs_state_set_strict_guards(strict, 2);
        eigs_state_set_strict_arithmetic(strict, 2);
        if (!eigs_thread_attach(strict) || eigs_state_init_runtime(strict) != 0) return 2;
        v = eigs_eval_string("abs of \"x\"");
        if (v || !eigs_has_error()) return 1;
        eigs_value_release(v);
        eigs_close(strict);
        puts("strict off setter works");
        puts("strict on setter works");
        return 0;
    }
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
