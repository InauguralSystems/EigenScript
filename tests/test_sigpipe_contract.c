#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include "eigs_embed.h"

static void host_sigpipe(int signum) { (void)signum; }

static int disposition_is_host(void) {
    struct sigaction current;
    return sigaction(SIGPIPE, NULL, &current) == 0 && current.sa_handler == host_sigpipe;
}

static int run_eval(const char *source) {
    EigsState *state = eigs_open();
    if (!state) return 0;
    EigsValue *value = eigs_eval_string(source);
    if (value) eigs_value_release(value);
    int ok = value != NULL && disposition_is_host();
    eigs_close(state);
    return ok;
}

static void *check_while_serving(void *unused) {
    (void)unused;
    usleep(200000);
    _exit(disposition_is_host() ? 0 : 1);
}

int main(int argc, char **argv) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = host_sigpipe;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, NULL) != 0 || argc != 2) return 2;

    if (strcmp(argv[1], "proc") == 0)
        return run_eval("p is proc_spawn of ([\"true\"])\n") ? 0 : 1;
    if (strcmp(argv[1], "early") == 0)
        return run_eval("http_early_bind of 0\n") ? 0 : 1;
    if (strcmp(argv[1], "serve") == 0) {
        pthread_t checker;
        if (pthread_create(&checker, NULL, check_while_serving, NULL) != 0) return 2;
        EigsState *state = eigs_open();
        if (!state) return 2;
        (void)eigs_eval_string("http_serve of 0\n");
        return 2;
    }
    return 2;
}
