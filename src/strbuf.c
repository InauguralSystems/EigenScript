/*
 * EigenScript growable string buffer.
 * Doubling-growth heap buffer used to replace fixed MAX_STR stack arrays
 * in the lexer, regex_replace, JSON encoder, and value_to_string.
 * All growth is routed through xrealloc_array so OOM and size_t overflow
 * share the xmalloc abort policy.
 */

#include "eigenscript.h"
#include "vm.h"   /* sandbox_charge */

#define STRBUF_INIT_CAP 64

void strbuf_init(strbuf *b) {
    b->cap = STRBUF_INIT_CAP;
    b->len = 0;
    b->refused = 0;
    b->data = xmalloc(b->cap);
    b->data[0] = '\0';
}

/* Growth is a sandbox chokepoint for every strbuf consumer (JSON encoder,
 * regex_replace, value_to_string): charging the DELTA here closes the whole
 * output-proportional-allocator class at once instead of per builtin — three
 * review rounds each found one more uncharged builtin (concat, then join/
 * str_replace, then text_builder/split) before the charge moved to the
 * chokepoints (2026-08-17). The delta alone never covers the initial
 * STRBUF_INIT_CAP bytes (and can leave a grown buffer's tail payload
 * unaccounted), so strbuf_finish charges the remaining payload shortfall at
 * the ownership transfer — together they charge every retained strbuf-backed
 * string exactly once (#965 fix1). On refusal the buffer is POISONED: no
 * growth, all further appends no-op, and sandbox_charge has already raised
 * the catchable EK_SANDBOX that fails the sandboxed run. Outside an armed
 * sandbox the charge is a no-op and behavior is unchanged. */
void strbuf_reserve(strbuf *b, size_t need) {
    if (b->refused) return;
    size_t required = b->len + need + 1;
    if (required <= b->cap) return;
    size_t new_cap = b->cap ? b->cap : STRBUF_INIT_CAP;
    while (new_cap < required) {
        if (new_cap > SIZE_MAX / 2) { new_cap = required; break; }
        new_cap *= 2;
    }
    if (!sandbox_charge(new_cap - b->cap)) {
        b->refused = 1;
        return;
    }
    b->data = xrealloc_array(b->data, new_cap, 1);
    b->cap = new_cap;
}

void strbuf_append_char(strbuf *b, char c) {
    strbuf_reserve(b, 1);
    if (b->refused) return;
    b->data[b->len++] = c;
    b->data[b->len] = '\0';
}

void strbuf_append_n(strbuf *b, const char *s, size_t n) {
    if (n == 0) return;
    strbuf_reserve(b, n);
    if (b->refused || b->len + n + 1 > b->cap) return;
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
    if (b->refused || b->len + (size_t)needed + 1 > b->cap) { va_end(ap2); return; }
    vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap2);
    va_end(ap2);
    b->len += (size_t)needed;
}

char *strbuf_finish(strbuf *b) {
    /* #965 (fix1): the growth chokepoint (strbuf_reserve) charges only cap
     * DELTAS, so the STRBUF_INIT_CAP initial bytes are never accounted — and
     * a grown buffer can still hold payload past its charged growth. The
     * ownership transfer is the one place a strbuf becomes a RETAINED
     * program value, so the payload shortfall is charged here: every
     * strbuf-backed string is then charged exactly once (deltas at reserve,
     * remainder at finish), never twice, never zero — small json_encode
     * results included. strbuf_free retains nothing and charges nothing.
     * Refusal follows the make_list precedent (the charge already raised
     * catchable EK_SANDBOX); no-op outside an armed sandbox. */
    size_t charged = b->cap >= STRBUF_INIT_CAP ? b->cap - STRBUF_INIT_CAP : 0;
    size_t payload = b->len + 1;
    if (payload > charged) {
        if (!sandbox_charge(payload - charged)) { /* raised; proceed */ }
    }
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
