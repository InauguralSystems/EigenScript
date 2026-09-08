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

/* Decode one UTF-8 character at `s` (`avail` bytes left). Returns its length
 * (1..4) when the bytes form a WELL-FORMED character; 0 when they cannot start
 * one (a stray continuation byte, an overlong form, a surrogate, > U+10FFFF, a
 * bad continuation); and -1 when they are a well-formed PREFIX that the input
 * ends inside — a cut, not corruption. #1048: every diagnostic path that
 * renders bytes the tool did not choose (a lint message, a JSON payload, the
 * parse-error source excerpt) needs the three cases apart — a cut tail is
 * dropped, a corrupt byte is replaced — so the primitive lives here rather
 * than in any one of them. */
int eigs_utf8_step(const unsigned char *s, size_t avail) {
    if (avail == 0) return 0;
    unsigned char c = s[0];
    if (c < 0x80) return 1;
    if (c < 0xC2 || c > 0xF4) return 0;      /* continuation / overlong / > max */
    size_t need = c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4;
    unsigned char lo = 0x80, hi = 0xBF;      /* range of the SECOND byte */
    if (c == 0xE0) lo = 0xA0;                /* no overlong 3-byte forms */
    else if (c == 0xED) hi = 0x9F;           /* no UTF-16 surrogates */
    else if (c == 0xF0) lo = 0x90;           /* no overlong 4-byte forms */
    else if (c == 0xF4) hi = 0x8F;           /* no code point > U+10FFFF */
    for (size_t i = 1; i < need; i++) {
        if (i >= avail) return -1;           /* well-formed so far, input ended */
        unsigned char b = s[i];
        unsigned char blo = (i == 1) ? lo : 0x80, bhi = (i == 1) ? hi : 0xBF;
        if (b < blo || b > bhi) return 0;
    }
    return (int)need;
}

/* Copy `src` into `dst` (`cap` bytes) as VALID UTF-8, whatever `src` holds:
 * every character is copied whole, a byte that is not part of a well-formed
 * character is replaced with U+FFFD, an incomplete sequence at the end is
 * dropped, and a copy that does not fit is truncated on a character boundary
 * and marked "...". Every lint diagnostic funnels through lint_vdiag into
 * this, and so does every path the linter prints, so it is the whole-class
 * guarantee: no rule, present or future, can emit malformed UTF-8 no matter
 * what it interpolates — including one that echoes bytes straight out of the
 * source (E002 quoted the byte it could not tokenize, which is half a
 * character for any non-ASCII input; the lexer now spells it \xNN, and this
 * replaces it if any future path does not). Individual rules must still keep
 * their ACTIONABLE half inside the budget — a truncation here is valid output
 * but a worse message (see w024_emit's shrink-to-fit). */
void eigs_utf8_sanitize(char *dst, size_t cap, const char *src) {
    if (!dst || cap == 0) return;
    dst[0] = '\0';
    if (!src) return;
    const unsigned char *s = (const unsigned char *)src;
    size_t n = strlen(src), i = 0, o = 0;
    size_t hard = cap - 1;                     /* bytes usable before the NUL */
    int clipped = 0;
    while (i < n) {
        int step = eigs_utf8_step(s + i, n - i);
        if (step < 0) { clipped = 1; break; }  /* cut tail: drop, do not halve */
        size_t w = step > 0 ? (size_t)step : 3;
        if (o + w > hard) { clipped = 1; break; }
        if (step > 0) memcpy(dst + o, s + i, w);
        else          memcpy(dst + o, "\xEF\xBF\xBD", 3);   /* U+FFFD */
        o += w;
        i += step > 0 ? (size_t)step : 1;
    }
    if (!clipped) { dst[o] = '\0'; return; }
    if (cap < 5) { dst[0] = '\0'; return; }
    /* Back up over whole characters until "..." fits, then mark the cut. */
    size_t room = cap - 4;
    while (o > room) {
        o--;
        while (o > 0 && ((unsigned char)dst[o] & 0xC0) == 0x80) o--;
    }
    memcpy(dst + o, "...", 4);
}


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
    /* A refused reserve already raised the first diagnostic. The producer may
     * still finish and transfer its poisoned partial buffer, but must not
     * re-enter sandbox_charge and replace that diagnostic with a shortfall. */
    if (!b->refused && payload > charged) {
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
