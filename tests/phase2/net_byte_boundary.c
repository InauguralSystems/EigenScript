/* R1.6d-D1: raw stored buffer bytes reach the actual net_send client.
 * A real socketpair verifies that a refusal sends no valid prefix. */
#define EIGENSCRIPT_EXT_NET 1
#include "eigenscript_all.c"
#include "../../src/ext_net.c"

static int checks, failures;
static void check(int ok) { checks++; if (!ok) failures++; }
static void clear_error(void) {
    eigs_clear_error_value();
    g_has_error = g_error_print_pending = 0;
    g_error_msg[0] = g_error_raw[0] = 0;
    g_math_flags = 0;
}
int main(void) {
    EigsState *st = eigs_open();
    if (!st) return 2;
    g_try_depth = 1;
    const double bad[] = { NAN, INFINITY, -INFINITY, NAN, 1.5, 256.0, 255.0 };
    for (int strict = 0; strict <= 1; strict++) {
        for (int i = 0; i < 7; i++) {
            int fd[2];
            if (socketpair(AF_UNIX, SOCK_STREAM, 0, fd) != 0) return 2;
            Value *handle = make_int((int64_t)net_register_sock(fd[0], NET_SOCK_CONN));
            Value *size = make_int(3);
            Value *buffer = builtin_buffer(size);
            val_decref(size);
            buffer->data.buffer.data[0] = 65.0;
            buffer->data.buffer.data[1] = bad[i];
            buffer->data.buffer.data[2] = i == 3 ? INFINITY : 66.0;
            Value *args = make_list_heap(2);
            list_append(args, handle);
            list_append(args, buffer);
            g_strict = strict;
            clear_error();
            Value *answer = builtin_net_send(args);
            int raised = g_has_error;
            unsigned char received[8];
            ssize_t n = recv(fd[1], received, sizeof received, MSG_DONTWAIT);
            check(!!raised == (i < 6));
            check(i == 6 || g_error_kind == EK_VALUE);
            unsigned flags = strict && (i == 0 || i == 3) ? EIGS_MATH_INVALID : 0;
            check(g_math_flags == flags);
            const char *diagnostic = (i == 0 || i == 3)
                ? (strict ? "not a number" : "expected a finite number")
                : (i == 1 || i == 2) ? "expected a finite number"
                : i == 4 ? "no integer representation" : "outside [0, 255]";
            check(i == 6 || strstr(g_error_raw, diagnostic) != NULL);
            if (i < 6) {
                check(n == -1 && (errno == EAGAIN || errno == EWOULDBLOCK));
            } else {
                check(n == 3 && received[0] == 65 && received[1] == 255 && received[2] == 66);
                check(answer && answer->type == VAL_INT && VAL_I64_RAW(answer) == 3);
            }
            val_decref(answer);
            clear_error();
            Value *closed = builtin_net_close(handle);
            val_decref(closed);
            close(fd[1]);
            val_decref(args);
            val_decref(buffer);
            val_decref(handle);
        }
    }
    g_try_depth = 0;
    clear_error();
    eigs_close(st);
    printf("phase2-net-byte: %s checks=%d failures=%d\n", failures ? "FAIL" : "PASS", checks, failures);
    return failures ? 1 : 0;
}
