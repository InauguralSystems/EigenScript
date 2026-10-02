/* One real byte of a two-byte ordinary pipe request. The test-only fsutil
 * object renames write to the shim below, so the production helper sees a
 * positive partial result and (on non-Apple) its own thread's SIGPIPE. No
 * production hook, copied helper, large buffer, or scheduling race is used.
 * Apple prevents pipe-generated signals at descriptor creation; that path
 * preserves the partial result without injecting a signal it cannot generate.
 */
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#include "fsutil.h"

static volatile sig_atomic_t deliveries;
static int shim_calls;
static int suppression_ok;
static int passed, failed, examined;

static void host_sigpipe(int signum) { (void)signum; deliveries++; }

ssize_t eigs_sigpipe_test_write(int fd, const void *buf, size_t count) {
    shim_calls++;
    if (count != 2) { errno = EINVAL; return -1; }
    ssize_t result = write(fd, buf, 1);
    if (result != 1) return result;
#if defined(__APPLE__)
    suppression_ok = fcntl(fd, F_GETNOSIGPIPE) == 1;
#else
    sigset_t mask;
    suppression_ok = pthread_sigmask(SIG_SETMASK, NULL, &mask) == 0 &&
                     sigismember(&mask, SIGPIPE) == 1;
    int error = pthread_kill(pthread_self(), SIGPIPE);
    if (error != 0) { errno = error; return -1; }
#endif
    /* A successful partial syscall may leave errno unchanged or incidental;
     * the helper must preserve the observed value across signal operations. */
    errno = E2BIG;
    return result;
}

static void check(int ok, const char *name) {
    examined++;
    if (ok) { passed++; printf("PASS: %s\n", name); }
    else { failed++; printf("FAIL: %s\n", name); }
}

int main(void) {
    alarm(10);
    struct sigaction action = {0}, current;
    action.sa_handler = host_sigpipe;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGPIPE, &action, NULL) != 0) return 2;
    sigset_t before, oldmask, after, pending;
    if (pthread_sigmask(SIG_SETMASK, NULL, &before) != 0) return 2;
    sigdelset(&before, SIGPIPE);
    sigaddset(&before, SIGUSR1); /* Preserve an unrelated blocked mask bit. */
    if (pthread_sigmask(SIG_SETMASK, &before, &oldmask) != 0) return 2;
    int fd[2];
    if (eigs_pipe_no_sigpipe(fd) != 0) return 2;

    errno = EDOM;
    ssize_t result = eigs_write_no_sigpipe(fd[1], "xy", 2);
    int saved_errno = errno;
    check(shim_calls == 1, "actual production helper called the finite shim once");
    check(suppression_ok, "platform suppression was active during the write");
    check(result == 1, "positive partial byte count is retained");
    check(saved_errno == E2BIG, "write errno survives drain and mask restoration");
    char byte = 0;
    close(fd[1]);
    check(read(fd[0], &byte, 1) == 1 && byte == 'x' && read(fd[0], &byte, 1) == 0,
          "exactly the one-byte payload was transferred");
    close(fd[0]);
    check(sigpending(&pending) == 0 && sigismember(&pending, SIGPIPE) == 0,
          "the write leaves no newly pending SIGPIPE");
    check(deliveries == 0, "the write does not deliver SIGPIPE to the host handler");
    check(pthread_sigmask(SIG_SETMASK, NULL, &after) == 0 &&
          sigismember(&after, SIGPIPE) == 0 && sigismember(&after, SIGUSR1) == 1,
          "original SIGPIPE and unrelated SIGUSR1 mask bits are restored");
    check(sigaction(SIGPIPE, NULL, &current) == 0 && current.sa_handler == host_sigpipe,
          "host SIGPIPE disposition is preserved");
    if (pthread_sigmask(SIG_SETMASK, &oldmask, NULL) != 0) return 2;
    printf("SIGPIPE partial: %d/9 passed, %d failed\n", passed, failed);
    return examined == 9 && passed == 9 && failed == 0 ? 0 : 1;
}
