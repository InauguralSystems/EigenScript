#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include "eigs_embed.h"
#include "fsutil.h"

static volatile sig_atomic_t deliveries;
static void host_sigpipe(int signum) { (void)signum; deliveries++; }

static int disposition_is_host(void) {
    struct sigaction current;
    return sigaction(SIGPIPE, NULL, &current) == 0 && current.sa_handler == host_sigpipe;
}

static int run_eval(const char *source, const char *expected) {
    EigsState *state = eigs_open();
    if (!state) return 0;
    EigsValue *value = eigs_eval_string(source);
    const char *text = value ? eigs_value_as_string(value) : NULL;
    int ok = value != NULL && !eigs_has_error() && disposition_is_host() &&
             (!expected || (text && strcmp(text, expected) == 0));
    if (value) eigs_value_release(value);
    eigs_close(state);
    return disposition_is_host() && ok;
}

static int io_contract(int use_send) {
    int fd[2];
    if ((use_send ? socketpair(AF_UNIX, SOCK_STREAM, 0, fd) : eigs_pipe_no_sigpipe(fd)) != 0)
        return 0;
    /* Positive ordinary I/O: preserve errno and deliver the byte. */
    int writer = use_send ? fd[0] : fd[1];
    int reader = use_send ? fd[1] : fd[0];
    errno = EDOM;
    ssize_t n = use_send ? eigs_send_no_sigpipe(writer, "x", 1, 0)
                         : eigs_write_no_sigpipe(writer, "x", 1);
    int ok = n == 1 && errno == EDOM;
#if defined(__APPLE__)
    if (!use_send) ok = fcntl(writer, F_GETNOSIGPIPE) == 1 && ok;
#endif
    char byte;
    ok = read(reader, &byte, 1) == 1 && byte == 'x' && ok;
    close(reader);

    sigset_t oldmask, current, pending, block;
    if (pthread_sigmask(SIG_SETMASK, NULL, &oldmask) != 0) return 0;
    n = use_send ? eigs_send_no_sigpipe(writer, "x", 1, 0)
                 : eigs_write_no_sigpipe(writer, "x", 1);
    ok = n == -1 && errno == EPIPE && ok;
    ok = sigpending(&pending) == 0 && !sigismember(&pending, SIGPIPE) && ok;
    ok = pthread_sigmask(SIG_SETMASK, NULL, &current) == 0 &&
         sigismember(&current, SIGPIPE) == sigismember(&oldmask, SIGPIPE) && ok;
    ok = disposition_is_host() && deliveries == 0 && ok;

    /* A signal pending before our write belongs to the host. */
    sigemptyset(&block);
    sigaddset(&block, SIGPIPE);
    if (pthread_sigmask(SIG_BLOCK, &block, NULL) != 0) return 0;
    if (raise(SIGPIPE) != 0) return 0;
    n = use_send ? eigs_send_no_sigpipe(writer, "x", 1, 0)
                 : eigs_write_no_sigpipe(writer, "x", 1);
    ok = n == -1 && errno == EPIPE && ok;
    ok = sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) && ok;
    ok = pthread_sigmask(SIG_SETMASK, NULL, &current) == 0 &&
         sigismember(&current, SIGPIPE) && ok;
    ok = disposition_is_host() && deliveries == 0 && ok;
    /* Consume only in test teardown, with no wait if the assertion failed. */
    if (sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE)) {
        int signum;
        ok = sigwait(&block, &signum) == 0 && signum == SIGPIPE && ok;
    }
    ok = pthread_sigmask(SIG_SETMASK, &oldmask, NULL) == 0 && ok;
    close(writer);
    return ok;
}

static struct sockaddr_in server_addr;
static void *check_while_serving(void *unused) {
    (void)unused;
    /* A real response proves execution reached accept/handle_request, after
     * the old process-wide SIG_IGN site. A sleep alone could pass too early. */
    for (int attempt = 0; attempt < 100; attempt++) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) _exit(2);
        if (connect(fd, (struct sockaddr *)&server_addr, sizeof(server_addr)) == 0) {
            static const char request[] = "GET / HTTP/1.0\r\n\r\n";
            char reply[16];
            if (eigs_send_no_sigpipe(fd, request, sizeof(request) - 1, 0) !=
                (ssize_t)(sizeof(request) - 1)) _exit(2);
            ssize_t n = recv(fd, reply, sizeof(reply), 0);
            close(fd);
            _exit(n >= 5 && memcmp(reply, "HTTP/", 5) == 0 && disposition_is_host() ? 0 : 1);
        }
        close(fd);
        usleep(20000);
    }
    _exit(2);
}

int main(int argc, char **argv) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = host_sigpipe;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, NULL) != 0 || argc != 2) return 2;
    /* Bound a stalled control without a platform-specific timeout tool. */
    alarm(10);

    if (strcmp(argv[1], "proc") == 0)
        return run_eval("p is proc_spawn of ([\"true\"])\n", NULL) ? 0 : 1;
    if (strcmp(argv[1], "write") == 0) return io_contract(0) ? 0 : 1;
    if (strcmp(argv[1], "send") == 0) return io_contract(1) ? 0 : 1;
    if (strcmp(argv[1], "early") == 0)
        return run_eval("http_early_bind of 0\n", "bound") ? 0 : 1;
    if (strcmp(argv[1], "serve") == 0) {
        int probe = socket(AF_INET, SOCK_STREAM, 0);
        if (probe < 0) return 2;
        memset(&server_addr, 0, sizeof(server_addr));
        server_addr.sin_family = AF_INET;
        server_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(probe, (struct sockaddr *)&server_addr, sizeof(server_addr)) != 0) return 2;
        socklen_t addrlen = sizeof(server_addr);
        if (getsockname(probe, (struct sockaddr *)&server_addr, &addrlen) != 0) return 2;
        close(probe);
        char source[64];
        snprintf(source, sizeof(source), "http_serve of %u\n", (unsigned)ntohs(server_addr.sin_port));
        pthread_t checker;
        if (pthread_create(&checker, NULL, check_while_serving, NULL) != 0) return 2;
        EigsState *state = eigs_open();
        if (!state) return 2;
        (void)eigs_eval_string(source);
        return 2;
    }
    return 2;
}
