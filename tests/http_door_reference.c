/* The reference of EigenScript#2370: what the server's door decides for the
 * bytes of one request. Written from the issue's text, before the server's C,
 * and sharing no code with src/ext_http.c. It feeds the vendored llhttp one
 * byte at a time. Time limits are not its business.
 *
 *   http_door_reference FILE HEAD_LIMIT BODY_LIMIT
 *
 * prints one line:
 *   none
 *   refused STATUS CAUSE INDEX       (INDEX of the byte that decides it)
 *   refused STATUS CAUSE stopped     (the client stopped: cause 9)
 *   served METHOD TARGET_HEX HEAD_START HEAD_LEN BODY_HEX COUNT
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "llhttp.h"

typedef struct { unsigned char *p; size_t n, room; } Bytes;

static void put(Bytes *b, const char *at, size_t n) {
    if (b->n + n + 1 > b->room) {
        b->room = (b->n + n + 1) * 2;
        b->p = realloc(b->p, b->room);
        if (!b->p) { perror("realloc"); exit(2); }
    }
    memcpy(b->p + b->n, at, n);
    b->n += n;
}

/* Where the decided byte sits in the stream. */
enum { HEAD, BODY, SIZE_LINE, DATA, TRAILER };

static struct {
    size_t index;              /* the byte being fed */
    int phase;
    long head_start;           /* -1 until on_method */
    size_t head_end;           /* the LF of the empty line */
    int head_done, chunk_header, complete;
    Bytes url, protocol, name, value, te, body;
    int field_is_te, te_seen, in_value;
    uint64_t chunk_size;
} R = { .head_start = -1 };

static int lower(int c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }

static int name_is(const Bytes *b, const char *want) {
    size_t n = strlen(want);
    if (b->n != n) return 0;
    for (size_t i = 0; i < n; i++)
        if (lower(b->p[i]) != want[i]) return 0;
    return 1;
}

static int on_method(llhttp_t *p, const char *at, size_t n) {
    (void)p; (void)at; (void)n;
    if (R.head_start < 0) R.head_start = (long)R.index;
    return 0;
}
static int on_url(llhttp_t *p, const char *at, size_t n) { (void)p; put(&R.url, at, n); return 0; }
static int on_protocol(llhttp_t *p, const char *at, size_t n) {
    (void)p;
    if (!R.head_done) put(&R.protocol, at, n);
    return 0;
}
static int on_header_field(llhttp_t *p, const char *at, size_t n) {
    (void)p;
    if (!R.head_done) put(&R.name, at, n);
    return 0;
}
static int on_header_field_complete(llhttp_t *p) {
    (void)p;
    if (!R.head_done) {
        R.field_is_te = name_is(&R.name, "transfer-encoding");
        R.name.n = 0;
        R.value.n = 0;
    }
    return 0;
}
static int on_header_value(llhttp_t *p, const char *at, size_t n) {
    (void)p;
    if (!R.head_done) put(&R.value, at, n);
    return 0;
}
static int on_header_value_complete(llhttp_t *p) {
    (void)p;
    if (!R.head_done && R.field_is_te) {
        if (R.te_seen) put(&R.te, ",", 1);
        put(&R.te, (const char *)R.value.p ? (const char *)R.value.p : "", R.value.n);
        R.te_seen = 1;
    }
    R.value.n = 0;
    R.field_is_te = 0;
    return 0;
}
static int on_headers_complete(llhttp_t *p) { (void)p; R.head_done = 1; return 0; }
static int on_body(llhttp_t *p, const char *at, size_t n) { (void)p; put(&R.body, at, n); return 0; }
static int on_chunk_header(llhttp_t *p) { R.chunk_header = 1; R.chunk_size = p->content_length; return 0; }
static int on_message_complete(llhttp_t *p) { (void)p; R.complete = 1; return 0; }

/* Cause 6: every Transfer-Encoding line, joined by commas, cut at the commas
 * and trimmed of spaces and tabs, must be one element: chunked, any case. */
static int te_is_one_chunked(void) {
    size_t n = R.te.n, start = 0, elements = 0;
    int ok = 1;
    for (size_t i = 0; i <= n; i++) {
        if (i < n && R.te.p[i] != ',') continue;
        size_t a = start, b = i;
        while (a < b && (R.te.p[a] == ' ' || R.te.p[a] == '\t')) a++;
        while (b > a && (R.te.p[b - 1] == ' ' || R.te.p[b - 1] == '\t')) b--;
        elements++;
        Bytes e = { R.te.p + a, b - a, 0 };
        if (!name_is(&e, "chunked")) ok = 0;
        start = i + 1;
    }
    return ok && elements == 1;
}

static void hex(const unsigned char *p, size_t n) {
    if (n == 0) { fputs("-", stdout); return; }
    for (size_t i = 0; i < n; i++) printf("%02x", p[i]);
}

static int is_hex(int c) {
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
}

int main(int argc, char **argv) {
    if (argc != 4) { fprintf(stderr, "usage: %s FILE HEAD_LIMIT BODY_LIMIT\n", argv[0]); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    Bytes in = {0};
    char buf[65536];
    size_t got;
    while ((got = fread(buf, 1, sizeof buf, f)) > 0) put(&in, buf, got);
    fclose(f);
    uint64_t head_limit = strtoull(argv[2], NULL, 10);
    uint64_t body_limit = strtoull(argv[3], NULL, 10);

    llhttp_settings_t s;
    llhttp_settings_init(&s);
    s.on_method = on_method;
    s.on_url = on_url;
    s.on_protocol = on_protocol;
    s.on_header_field = on_header_field;
    s.on_header_field_complete = on_header_field_complete;
    s.on_header_value = on_header_value;
    s.on_header_value_complete = on_header_value_complete;
    s.on_headers_complete = on_headers_complete;
    s.on_body = on_body;
    s.on_chunk_header = on_chunk_header;
    s.on_message_complete = on_message_complete;
    llhttp_t parser;
    llhttp_init(&parser, HTTP_REQUEST, &s);

    uint64_t count = 0, chunk_sum = 0, data_left = 0;
    size_t digits = 0;
    int in_digits = 1, skip_next = 0, line_start = 1;

    if (in.n == 0) { puts("none"); return 0; }
    for (R.index = 0; R.index < in.n; R.index++) {
        unsigned char c = in.p[R.index];
        /* Is this byte held against the head's limit? Decided by its place. */
        int counted = 1;
        switch (R.phase) {
        case HEAD: counted = 1; break;
        case BODY: counted = 0; break;
        case SIZE_LINE:
            if (skip_next) { counted = 0; skip_next = 0; }
            else if (c == '\r') { counted = 0; skip_next = 1; }
            else if (in_digits && is_hex(c)) { counted = digits >= 16; digits++; }
            else { in_digits = 0; counted = 1; }
            break;
        case DATA: counted = 0; data_left--; break;
        case TRAILER:
            if (skip_next) { counted = 0; skip_next = 0; }
            else if (line_start && c == '\r') { counted = 0; skip_next = 1; }
            else { counted = 1; line_start = c == '\n'; }
            break;
        }
        if (counted && count + 1 > head_limit) {
            printf("refused 431 1 %zu\n", R.index);
            return 0;
        }
        count += counted;

        int was_done = R.head_done;
        R.chunk_header = 0;
        enum llhttp_errno err = llhttp_execute(&parser, (const char *)&in.p[R.index], 1);
        if (err == HPE_PAUSED_H2_UPGRADE) {
            printf("refused 505 3 %zu\n", R.index);
            return 0;
        }
        if (err != HPE_OK && err != HPE_PAUSED && err != HPE_PAUSED_UPGRADE) {
            printf("refused 400 2 %zu\n", R.index);
            return 0;
        }
        if (R.head_done && !was_done) {
            if (R.protocol.n && !(R.protocol.n == 4 && memcmp(R.protocol.p, "HTTP", 4) == 0)) {
                printf("refused 400 4 %zu\n", R.index);
                return 0;
            }
            if (!(parser.http_major == 1 && (parser.http_minor == 0 || parser.http_minor == 1))) {
                printf("refused 505 5 %zu\n", R.index);
                return 0;
            }
            if (R.te_seen && !te_is_one_chunked()) {
                printf("refused 501 6 %zu\n", R.index);
                return 0;
            }
            if ((parser.flags & F_CONTENT_LENGTH) && parser.content_length > body_limit) {
                printf("refused 413 7 %zu\n", R.index);
                return 0;
            }
            R.phase = (parser.flags & F_CHUNKED) ? SIZE_LINE : BODY;
            R.head_end = R.index;
        }
        if (R.chunk_header) {
            if (R.chunk_size > body_limit - chunk_sum) {
                printf("refused 413 8 %zu\n", R.index);
                return 0;
            }
            chunk_sum += R.chunk_size;
            if (R.chunk_size > 0) {
                R.phase = DATA;
                data_left = R.chunk_size + 2;
            } else {
                R.phase = TRAILER;
                line_start = 1;
            }
            skip_next = 0;
        } else if (R.phase == DATA && data_left == 0) {
            R.phase = SIZE_LINE;
            digits = 0;
            in_digits = 1;
            skip_next = 0;
        }
        if (R.complete) {
            printf("served %s ", llhttp_method_name((llhttp_method_t)parser.method));
            hex(R.url.p, R.url.n);
            printf(" %ld %zu ", R.head_start, R.head_end - (size_t)R.head_start + 1);
            hex(R.body.p, R.body.n);
            printf(" %llu\n", (unsigned long long)count);
            return 0;
        }
    }
    puts("refused 400 9 stopped");
    return 0;
}
