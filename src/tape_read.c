/* ================================================================
 * EigenScript tape reader — implementation. See tape_read.h.
 * ================================================================
 * Extracted verbatim from step.c for #539 v3 (the DAP server), so the
 * stepper and the DAP server share one model. The stderr wording keeps
 * the historical "step:" prefix — it is the tape-reader speaking,
 * whichever front-end drove it.
 */

#include "eigenscript.h"
#include "trace.h"
#include "tape_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

static char *read_whole_file_priv(const char *path, long *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) { fclose(f); return NULL; }
    char *buf = malloc((size_t)len + 1);
    if (!buf) { fclose(f); return NULL; }
    if (len > 0 && fread(buf, 1, (size_t)len, f) != (size_t)len) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    buf[len] = '\0';
    if (out_len) *out_len = len;
    return buf;
}

NameHist *tape_hist_for(Tape *t, const char *name, uint32_t scope,
                        int create) {
    for (int i = 0; i < t->nnames; i++)
        if (t->names[i].scope == scope &&
            strcmp(t->names[i].name, name) == 0) return &t->names[i];
    if (!create) return NULL;
    if (t->nnames == t->namecap) {
        int nc = t->namecap ? t->namecap * 2 : 16;
        NameHist *nn = realloc(t->names, (size_t)nc * sizeof(NameHist));
        if (!nn) return NULL;
        t->names = nn;
        t->namecap = nc;
    }
    NameHist *h = &t->names[t->nnames++];
    h->name = name;
    h->scope = scope;
    h->a = NULL;
    h->n = h->cap = 0;
    return h;
}

static int hist_push(NameHist *h, Assign a) {
    if (h->n == h->cap) {
        int nc = h->cap ? h->cap * 2 : 8;
        Assign *na = realloc(h->a, (size_t)nc * sizeof(Assign));
        if (!na) return 0;
        h->a = na;
        h->cap = nc;
    }
    h->a[h->n++] = a;
    return 1;
}

/* Scope-instance table + reconstruction stack (parse time). On
 * S(fn, depth, serial): if the serial is already on the stack we are
 * RETURNING into that frame — pop to it. Otherwise this is a new frame
 * instance: pop everything at the same or deeper depth (frames the tape
 * silently returned out of — they never assigned again), then push with
 * parent = the new top. */
ScopeInfo *tape_scope_info(const Tape *t, uint32_t serial) {
    for (int i = 0; i < t->nscopes; i++)
        if (t->scopes[i].serial == serial) return (ScopeInfo *)&t->scopes[i];
    return NULL;
}

static ScopeInfo *scope_add(Tape *t, uint32_t serial, const char *name,
                            int depth, uint32_t parent) {
    if (t->nscopes == t->scopecap) {
        int nc = t->scopecap ? t->scopecap * 2 : 16;
        ScopeInfo *ns = realloc(t->scopes, (size_t)nc * sizeof(ScopeInfo));
        if (!ns) return NULL;
        t->scopes = ns;
        t->scopecap = nc;
    }
    ScopeInfo *si = &t->scopes[t->nscopes++];
    si->serial = serial;
    si->name = name;
    si->depth = depth;
    si->parent = parent;
    return si;
}

/* #411 header check — the replay rule, with "step" wording. */
static int vline_ok(const char *p) {
    if (p[0] != 'V' || p[1] != ' ') {
        if (p[0] == 'V')
            fprintf(stderr, "step: malformed tape version header '%s'; "
                    "refusing to step (docs/TRACE.md)\n", p);
        else
            fprintf(stderr, "step: tape has no version header — recorded by "
                    "a pre-versioning EigenScript or not a tape; refusing "
                    "to step (docs/TRACE.md)\n");
        return 0;
    }
    char *end = NULL;
    long fmt = strtol(p + 2, &end, 10);
    if (end == p + 2 || *end != ' ') {
        fprintf(stderr, "step: malformed tape version header '%s'; "
                "refusing to step (docs/TRACE.md)\n", p);
        return 0;
    }
    if (fmt != TRACE_FORMAT_VERSION) {
        fprintf(stderr, "step: tape format v%ld, this binary reads v%d — "
                "refusing to step; re-record on this version "
                "(docs/TRACE.md)\n", fmt, TRACE_FORMAT_VERSION);
        return 0;
    }
    if (strcmp(end + 1, EIGENSCRIPT_VERSION) != 0) {
        fprintf(stderr, "step: tape recorded on EigenScript %s, this binary "
                "is %s — refusing to step; a tape is valid only for the "
                "version that recorded it (docs/TRACE.md)\n",
                end + 1, EIGENSCRIPT_VERSION);
        return 0;
    }
    return 1;
}

/* Parse the NUL-split tape buffer into recs/steps/name histories.
 * Returns 0 on version refusal, 1 otherwise. */
static int tape_parse(Tape *t, long len) {
    int nlines = 0;
    for (long i = 0; i < len; i++)
        if (t->tape[i] == '\n') nlines++;
    if (len > 0 && t->tape[len - 1] != '\n') nlines++;
    t->recs  = calloc(nlines ? (size_t)nlines : 1, sizeof(StepRec));
    t->steps = calloc(nlines ? (size_t)nlines : 1, sizeof(int));
    if (!t->recs || !t->steps) return 0;

    int first = 1;
    uint32_t sstack[256];       /* scope-serial stack (only assigning frames
                                 * appear; overflow degrades to flat scope,
                                 * never corrupts) */
    int sdepth = 0;
    uint32_t cur_scope = 0;
    char *p = t->tape, *end = t->tape + len;
    while (p < end) {
        char *nl = memchr(p, '\n', (size_t)(end - p));
        if (nl) *nl = '\0';
        if (first) {
            if (!vline_ok(p)) return 0;
            first = 0;
        }
        StepRec r = {0};
        r.kind = p[0];
        r.step = t->nsteps > 0 ? t->nsteps - 1 : 0;
        r.scope = cur_scope;
        switch (p[0]) {
            case 'V':
                if (!vline_ok(p)) return 0;   /* mid-stream session header */
                break;
            case 'L':
                r.line = atoi(p + 2);
                t->steps[t->nsteps] = t->nrecs;
                r.step = t->nsteps;
                t->nsteps++;
                break;
            case 'A': case 'N': {
                char *eq = strchr(p + 2, '=');
                if (!eq) { r.kind = 0; break; }   /* torn record: skip */
                *eq = '\0';
                r.name  = p + 2;
                r.value = eq + 1;
                if (r.kind == 'A') {
                    NameHist *h = tape_hist_for(t, r.name, cur_scope, 1);
                    if (h) {
                        Assign a;
                        a.rec = t->nrecs;
                        a.step = r.step;
                        a.value = r.value;
                        char *ne = NULL;
                        a.num = strtod(r.value, &ne);
                        a.is_num = (ne != r.value && *ne == '\0');
                        hist_push(h, a);
                    }
                }
                break;
            }
            case 'S': {                            /* #539 v2 scope transition */
                char *nm = p + 2;
                char *sp1 = strchr(nm, ' ');
                if (!sp1) { r.kind = 0; break; }
                *sp1 = '\0';
                int depth = atoi(sp1 + 1);
                char *sp2 = strchr(sp1 + 1, ' ');
                uint32_t serial = sp2 ? (uint32_t)strtoul(sp2 + 1, NULL, 10) : 0;
                int on_stack = -1;
                for (int k = sdepth - 1; k >= 0; k--)
                    if (sstack[k] == serial) { on_stack = k; break; }
                if (on_stack >= 0) {
                    sdepth = on_stack + 1;         /* returned into it */
                } else {
                    while (sdepth > 0) {
                        ScopeInfo *top = tape_scope_info(t, sstack[sdepth - 1]);
                        if (top && top->depth < depth) break;
                        sdepth--;                  /* silently-exited frames */
                    }
                    uint32_t parent = sdepth > 0 ? sstack[sdepth - 1] : 0;
                    scope_add(t, serial, nm, depth, parent);
                    if (sdepth < (int)(sizeof(sstack)/sizeof(sstack[0])))
                        sstack[sdepth++] = serial;
                }
                cur_scope = serial;
                r.kind = 0;                        /* folded, not kept */
                break;
            }
            default:
                r.kind = 0;                        /* unknown: skip */
                break;
        }
        if (r.kind) t->recs[t->nrecs++] = r;
        p = nl ? nl + 1 : end;
    }
    return 1;
}

static void load_source(Tape *t, const char *path) {
    long len = 0;
    t->srcbuf = read_whole_file_priv(path, &len);
    if (!t->srcbuf) {
        fprintf(stderr, "step: cannot read source '%s' (continuing without "
                "source display)\n", path);
        return;
    }
    int nlines = 1;
    for (long i = 0; i < len; i++)
        if (t->srcbuf[i] == '\n') nlines++;
    t->src = calloc((size_t)nlines + 1, sizeof(char *));
    if (!t->src) return;
    char *p = t->srcbuf, *end = t->srcbuf + len;
    while (p < end && t->nsrc < nlines) {
        t->src[t->nsrc++] = p;
        char *nl = memchr(p, '\n', (size_t)(end - p));
        if (!nl) break;
        *nl = '\0';
        p = nl + 1;
    }
}

void tape_free(Tape *t) {
    free(t->tape); free(t->recs); free(t->steps);
    for (int i = 0; i < t->nnames; i++) free(t->names[i].a);
    free(t->names);
    free(t->scopes);
    free(t->src); free(t->srcbuf);
    memset(t, 0, sizeof *t);
}

int tape_open(Tape *t, const char *tape_path, const char *src_path) {
    memset(t, 0, sizeof *t);
    long len = 0;
    t->tape = read_whole_file_priv(tape_path, &len);
    if (!t->tape) {
        fprintf(stderr, "step: cannot read tape '%s'\n", tape_path);
        return 1;
    }
    if (len == 0) {
        fprintf(stderr, "step: empty tape — refusing to step "
                "(docs/TRACE.md)\n");
        tape_free(t);
        return 3;
    }
    if (!tape_parse(t, len)) {
        tape_free(t);
        return 3;
    }
    if (t->nsteps == 0) {
        fprintf(stderr, "step: tape has no line events (L records) — "
                "nothing to step\n");
        tape_free(t);
        return 4;
    }
    if (src_path) load_source(t, src_path);
    return 0;
}

const char *tape_classify_at(const NameHist *h, int pos, int *out_numeric) {
    ObserverSlot s;
    memset(&s, 0, sizeof s);
    int fed = 0;
    for (int i = 0; i < h->n && h->a[i].step <= pos; i++) {
        if (!h->a[i].is_num) continue;
        observer_slot_record_value(&s, h->a[i].num);
        fed++;
    }
    const char *label = fed ? observer_slot_report_value(&s) : NULL;
    free(s.v_window);
    free(s.vr_window);
    free(s.dh_window);
    if (out_numeric) *out_numeric = fed;
    return label;
}

const Assign *tape_latest_at(const NameHist *h, int pos) {
    const Assign *last = NULL;
    for (int i = 0; i < h->n && h->a[i].step <= pos; i++) last = &h->a[i];
    return last;
}

/* The frame instance current at a stop position = the scope of the
 * last record in that step's window (A records carry their exact
 * scope; an assign-free stretch inherits the last transition). */
uint32_t tape_scope_at(const Tape *t, int pos) {
    int bound = (pos + 1 < t->nsteps) ? t->steps[pos + 1] : t->nrecs;
    for (int i = bound - 1; i >= 0; i--)
        if (t->recs[i].scope) return t->recs[i].scope;
    return 0;
}

const NameHist *tape_resolve_at(const Tape *t, int pos, const char *name) {
    uint32_t sc = tape_scope_at(t, pos);
    for (;;) {
        const NameHist *h = tape_hist_for((Tape *)t, name, sc, 0);
        if (h && tape_latest_at(h, pos)) return h;
        if (sc == 0) return NULL;
        const ScopeInfo *si = tape_scope_info(t, sc);
        sc = si ? si->parent : 0;
    }
}
