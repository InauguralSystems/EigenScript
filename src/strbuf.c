/*
 * EigenScript growable string buffer.
 * Doubling-growth heap buffer used to replace fixed MAX_STR stack arrays
 * in the lexer, regex_replace, JSON encoder, and value_to_string.
 * All growth is routed through xrealloc_array so OOM and size_t overflow
 * share the xmalloc abort policy.
 */

#include "eigenscript.h"

#define STRBUF_INIT_CAP 64

void strbuf_init(strbuf *b) {
    b->cap = STRBUF_INIT_CAP;
    b->len = 0;
    b->data = xmalloc(b->cap);
    b->data[0] = '\0';
}

void strbuf_reserve(strbuf *b, size_t need) {
    size_t required = b->len + need + 1;
    if (required <= b->cap) return;
    size_t new_cap = b->cap ? b->cap : STRBUF_INIT_CAP;
    while (new_cap < required) {
        if (new_cap > SIZE_MAX / 2) { new_cap = required; break; }
        new_cap *= 2;
    }
    b->data = xrealloc_array(b->data, new_cap, 1);
    b->cap = new_cap;
}

void strbuf_append_char(strbuf *b, char c) {
    strbuf_reserve(b, 1);
    b->data[b->len++] = c;
    b->data[b->len] = '\0';
}

void strbuf_append_n(strbuf *b, const char *s, size_t n) {
    if (n == 0) return;
    strbuf_reserve(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

void strbuf_append(strbuf *b, const char *s) {
    if (!s) return;
    strbuf_append_n(b, s, strlen(s));
}

void strbuf_append_fmt(strbuf *b, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    va_list ap2;
    va_copy(ap2, ap);
    int needed = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (needed < 0) { va_end(ap2); return; }
    strbuf_reserve(b, (size_t)needed);
    vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)needed;
}

char *strbuf_finish(strbuf *b) {
    char *out = b->data;
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
    return out;
}

void strbuf_free(strbuf *b) {
    free(b->data);
    b->data = NULL;
    b->len = 0;
    b->cap = 0;
}
