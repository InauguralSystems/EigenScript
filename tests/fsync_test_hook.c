#include <stdio.h>
#include <errno.h>
#include <unistd.h>

/* Link-time implementation for EIGS_TEST_HOOKS builds only.  stderr makes the
 * proof observable without adding a filesystem effect to the runtime seam. */
int eigs_test_fsync_hook(int fd, const char *kind) {
    int result = fsync(fd);
    int saved_errno = errno;
    fprintf(stderr, "EIGS_TEST_FSYNC: %s\n", kind);
    errno = saved_errno;
    return result;
}
