/*
 * EigenScript Network Extension — raw TCP sockets as tape-recorded
 * nondeterministic inputs (#414).
 * Compiled only when EIGENSCRIPT_EXT_NET=1 (in no default build).
 *
 * The differentiating contract: every nondeterministic outcome —
 * accepted connections, received bytes, bytes-sent counts, dial
 * results, kernel-assigned ports — enters the program through the
 * trace-tape seam (TRACE_NONDET_TAKE/RECORD), so a recorded session
 * replays byte-identically with no network present at all. Under
 * EIGS_REPLAY the TAKE short-circuits before any socket call: no
 * socket is created, bound, connected, read, or written.
 *
 * Replay-determinism rule (the #601 lesson): every ENVIRONMENT outcome
 * is a recorded *value* — null for failure/timeout, a number or buffer
 * for success — never a live-path-only raise. A raise that only the
 * live run takes would desync the tape's N-record stream the moment a
 * `catch` swallows it. Argument-SHAPE errors (wrong type/arity) raise
 * deterministically BEFORE the tape boundary: both runs take the same
 * path and consume no record.
 *
 * net_send is the deliberate contrast to the #148 non-replayable
 * subprocess family: a send's observable effect on the program is its
 * result (bytes sent), and the peer's future responses are themselves
 * recorded — so under replay the send is SUPPRESSED (recorded result
 * served, nothing written) and the world stays consistent. proc_write
 * cannot make that claim: its side effects feed a live child the tape
 * does not pin.
 */

#include "ext_net_internal.h"
#include "ext_names.h"
#include "trace.h"

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

/* Per-call receive cap. An N record has a 64 KiB byte budget and a
 * byte serializes as up to 4 chars ("255,") — 8192 bytes stays well
 * inside it. A truncated record would silently fall back to the live
 * source on replay, exactly the failure audio_capture_read's 2048-
 * sample cap exists to prevent. Loop to drain more. */
#define NET_RECV_MAX 8192

/* Listen backlog. Dial-before-accept relies on it: on loopback a
 * connect completes as soon as the kernel queues it here, which is
 * what lets a single-threaded program be both ends of a socket. */
#define NET_BACKLOG 16

/* ---- helpers ------------------------------------------------------ */

static Value* net_bytes_to_buffer(const unsigned char *bytes, int n) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->refcount = 1;
    v->data.buffer.count = n;
    v->data.buffer.data = xcalloc(n > 0 ? (size_t)n : 1, sizeof(double));
    for (int i = 0; i < n; i++)
        v->data.buffer.data[i] = (double)bytes[i];
    return v;
}

static int net_register_sock(int fd, EigsNetSockKind kind) {
    EigsNetSock *s = xmalloc(sizeof(EigsNetSock));
    s->fd = fd;
    s->kind = kind;
    int id = handle_register(s, HANDLE_NET);
    if (id < 0) { close(fd); free(s); }
    return id;
}

static EigsNetSock* net_lookup(Value *v, EigsNetSockKind kind) {
    if (!v || v->type != VAL_NUM) return NULL;
    EigsNetSock *s = handle_lookup((int)v->data.num, HANDLE_NET);
    if (!s || s->kind != kind) return NULL;
    return s;
}

/* poll() one fd for readability. timeout_ms < 0 blocks. Returns 1 when
 * readable, 0 on timeout/error. */
static int net_wait_readable(int fd, int timeout_ms) {
    struct pollfd p = { .fd = fd, .events = POLLIN };
    int r;
    do { r = poll(&p, 1, timeout_ms); } while (r < 0 && errno == EINTR);
    return r > 0;
}

/* Deterministic shape check shared by the list-form builtins. rt_error
 * RETURNS (the VM's CHECK_ERROR unwinds after the builtin exits), so a
 * failed check must make the caller return immediately — falling
 * through would deref a non-list. Returns 1 ok / 0 raised. Runs before
 * the tape boundary: both runs take the same path, no record consumed. */
static int net_require_list(Value *arg, int min, int max, const char *fn) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < min
        || arg->data.list.count > max) {
        rt_error(EK_TYPE, 0, "%s: expected %d-%d arguments (see docs/BUILTINS.md)",
                 fn, min, max);
        return 0;
    }
    return 1;
}

static int net_num_at(Value *arg, int idx, int fallback) {
    if (!arg || arg->type != VAL_LIST || idx >= arg->data.list.count)
        return fallback;
    Value *v = arg->data.list.items[idx];
    return (v && v->type == VAL_NUM) ? (int)v->data.num : fallback;
}

/* ---- builtins ----------------------------------------------------- */

/* net_listen of port → listener handle id, or null when the bind/listen
 * failed (port taken, privileged port). Port 0 asks the kernel for an
 * ephemeral port — read it back with net_port. Binds 0.0.0.0, matching
 * ext_http's server posture (SECURITY.md: the script is trusted). */
Value* builtin_net_listen(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "net_listen: expected a port number");
        return make_null();
    }
    TRACE_NONDET_TAKE("net_listen");
    int port = (int)arg->data.num;
    if (port < 0 || port > 65535)
        TRACE_NONDET_RECORD("net_listen", make_null());
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) TRACE_NONDET_RECORD("net_listen", make_null());
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr*)&addr, sizeof(addr)) < 0 ||
        listen(fd, NET_BACKLOG) < 0) {
        close(fd);
        TRACE_NONDET_RECORD("net_listen", make_null());
    }
    int id = net_register_sock(fd, NET_SOCK_LISTENER);
    if (id < 0) TRACE_NONDET_RECORD("net_listen", make_null());
    TRACE_NONDET_RECORD("net_listen", make_num(id));
}

/* net_port of listener_id → the locally bound port (the kernel's pick
 * for a port-0 listen), or null on a bad/closed handle. Kernel-chosen,
 * so it rides the tape like every other environment outcome. */
Value* builtin_net_port(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "net_port: expected a listener handle");
        return make_null();
    }
    TRACE_NONDET_TAKE("net_port");
    EigsNetSock *s = net_lookup(arg, NET_SOCK_LISTENER);
    if (!s) TRACE_NONDET_RECORD("net_port", make_null());
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    if (getsockname(s->fd, (struct sockaddr*)&addr, &len) < 0)
        TRACE_NONDET_RECORD("net_port", make_null());
    TRACE_NONDET_RECORD("net_port", make_num(ntohs(addr.sin_port)));
}

/* net_accept of listener_id
 * net_accept of [listener_id, timeout_ms]
 * → connection handle id, or null on timeout / bad handle. No timeout
 * blocks indefinitely. */
Value* builtin_net_accept(Value *arg) {
    int timeout_ms = -1;
    if (arg && arg->type == VAL_LIST) {
        if (!net_require_list(arg, 2, 2, "net_accept")) return make_null();
        timeout_ms = net_num_at(arg, 1, -1);
        arg = arg->data.list.items[0];
    }
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "net_accept: expected a listener handle");
        return make_null();
    }
    TRACE_NONDET_TAKE("net_accept");
    EigsNetSock *s = net_lookup(arg, NET_SOCK_LISTENER);
    if (!s) TRACE_NONDET_RECORD("net_accept", make_null());
    if (!net_wait_readable(s->fd, timeout_ms))
        TRACE_NONDET_RECORD("net_accept", make_null());
    int cfd;
    do { cfd = accept(s->fd, NULL, NULL); } while (cfd < 0 && errno == EINTR);
    if (cfd < 0) TRACE_NONDET_RECORD("net_accept", make_null());
    int id = net_register_sock(cfd, NET_SOCK_CONN);
    if (id < 0) TRACE_NONDET_RECORD("net_accept", make_null());
    TRACE_NONDET_RECORD("net_accept", make_num(id));
}

/* net_dial of [host, port]
 * net_dial of [host, port, timeout_ms]
 * → connection handle id, or null on refusal / resolution failure /
 * timeout. The connect runs nonblocking + poll so the timeout is real;
 * the socket is restored to blocking afterward (recv/send poll first). */
Value* builtin_net_dial(Value *arg) {
    if (!net_require_list(arg, 2, 3, "net_dial")) return make_null();
    Value *host = arg->data.list.items[0];
    if (!host || host->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "net_dial: expected [host, port] with a string host");
        return make_null();
    }
    int port = net_num_at(arg, 1, -1);
    int timeout_ms = net_num_at(arg, 2, -1);
    TRACE_NONDET_TAKE("net_dial");
    if (port < 0 || port > 65535) TRACE_NONDET_RECORD("net_dial", make_null());

    char portstr[8];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints = {0}, *res = NULL;
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host->data.str, portstr, &hints, &res) != 0 || !res)
        TRACE_NONDET_RECORD("net_dial", make_null());

    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0) { freeaddrinfo(res); TRACE_NONDET_RECORD("net_dial", make_null()); }
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, res->ai_addr, res->ai_addrlen);
    freeaddrinfo(res);
    if (rc < 0 && errno == EINPROGRESS) {
        struct pollfd p = { .fd = fd, .events = POLLOUT };
        int pr;
        do { pr = poll(&p, 1, timeout_ms); } while (pr < 0 && errno == EINTR);
        int soerr = 0;
        socklen_t slen = sizeof(soerr);
        if (pr <= 0 ||
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) < 0 || soerr) {
            close(fd);
            TRACE_NONDET_RECORD("net_dial", make_null());
        }
    } else if (rc < 0) {
        close(fd);
        TRACE_NONDET_RECORD("net_dial", make_null());
    }
    fcntl(fd, F_SETFL, flags);
    int id = net_register_sock(fd, NET_SOCK_CONN);
    if (id < 0) TRACE_NONDET_RECORD("net_dial", make_null());
    TRACE_NONDET_RECORD("net_dial", make_num(id));
}

/* net_recv of [conn_id, max_bytes]
 * net_recv of [conn_id, max_bytes, timeout_ms]
 * → buffer of byte values (empty buffer = orderly EOF or reset — the
 * connection is over), or null on timeout / bad handle. max_bytes is
 * clamped to 8192 per call (the N-record budget); loop to drain more.
 * Convert text with str_from_bytes. */
Value* builtin_net_recv(Value *arg) {
    if (!net_require_list(arg, 2, 3, "net_recv")) return make_null();
    Value *conn = arg->data.list.items[0];
    int max = net_num_at(arg, 1, 0);
    int timeout_ms = net_num_at(arg, 2, -1);
    /* A zero-byte recv() returns 0 — indistinguishable from EOF — so a
     * senseless max is a shape error, decided before the tape boundary. */
    if (max < 1) {
        rt_error(EK_VALUE, 0, "net_recv: max_bytes must be >= 1");
        return make_null();
    }
    TRACE_NONDET_TAKE("net_recv");
    EigsNetSock *s = net_lookup(conn, NET_SOCK_CONN);
    if (!s) TRACE_NONDET_RECORD("net_recv", make_null());
    if (max > NET_RECV_MAX) max = NET_RECV_MAX;
    if (!net_wait_readable(s->fd, timeout_ms))
        TRACE_NONDET_RECORD("net_recv", make_null());
    unsigned char buf[NET_RECV_MAX];
    ssize_t n;
    do { n = recv(s->fd, buf, (size_t)max, 0); } while (n < 0 && errno == EINTR);
    if (n < 0) n = 0;   /* reset == connection over == EOF shape */
    TRACE_NONDET_RECORD("net_recv", net_bytes_to_buffer(buf, (int)n));
}

/* net_send of [conn_id, data] — data is a string or a buffer/list of
 * byte values. → number of bytes sent, or -1 on a bad handle / peer
 * gone. Loops until everything is written. Under EIGS_REPLAY the send
 * is suppressed: the recorded count is served and nothing touches a
 * socket (see the header comment for why that is sound here and not
 * for proc_write). */
Value* builtin_net_send(Value *arg) {
    if (!net_require_list(arg, 2, 2, "net_send")) return make_null();
    Value *conn = arg->data.list.items[0];
    Value *data = arg->data.list.items[1];
    if (!data || (data->type != VAL_STR && data->type != VAL_BUFFER
                  && data->type != VAL_LIST)) {
        rt_error(EK_TYPE, 0, "net_send: data must be a string, buffer, or byte list");
        return make_null();
    }
    TRACE_NONDET_TAKE("net_send");
    EigsNetSock *s = net_lookup(conn, NET_SOCK_CONN);
    if (!s) TRACE_NONDET_RECORD("net_send", make_num(-1));

    const unsigned char *bytes;
    unsigned char *owned = NULL;
    size_t len;
    if (data->type == VAL_STR) {
        bytes = (const unsigned char*)data->data.str;
        len = strlen(data->data.str);
    } else {
        int n = data->type == VAL_BUFFER ? data->data.buffer.count
                                         : data->data.list.count;
        owned = xmalloc(n > 0 ? (size_t)n : 1);
        for (int i = 0; i < n; i++) {
            double dv = data->type == VAL_BUFFER
                ? data->data.buffer.data[i]
                : (data->data.list.items[i] &&
                   data->data.list.items[i]->type == VAL_NUM
                       ? data->data.list.items[i]->data.num : 0.0);
            owned[i] = (unsigned char)((int)dv & 0xFF);
        }
        bytes = owned;
        len = (size_t)n;
    }

    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(s->fd, bytes + sent, len - sent, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { free(owned); TRACE_NONDET_RECORD("net_send", make_num(-1)); }
        sent += (size_t)n;
    }
    free(owned);
    TRACE_NONDET_RECORD("net_send", make_num((double)sent));
}

/* net_close of handle_id → null. Deterministic and untraced: closing is
 * idempotent bookkeeping, and under EIGS_REPLAY no handle exists so it
 * is a natural no-op (the audio_capture_close shape). */
Value* builtin_net_close(Value *arg) {
    if (!arg || arg->type != VAL_NUM) {
        rt_error(EK_TYPE, 0, "net_close: expected a socket handle");
        return make_null();
    }
    EigsNetSock *s = handle_lookup((int)arg->data.num, HANDLE_NET);
    if (s) {
        close(s->fd);
        free(s);
        handle_release((int)arg->data.num);
    }
    return make_null();
}

/* ---- registration -------------------------------------------------- */

void register_net_builtins(Env *env) {
#define X(name, fn) env_set_local_owned(env, #name, make_builtin(fn));
    EIGS_NET_BUILTINS(X)
#undef X
}
