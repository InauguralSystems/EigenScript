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

static int obscfg_push(Tape *t, const ObsCfgRec *o) {
    if (t->nobscfg == t->obscfgcap) {
        int nc = t->obscfgcap ? t->obscfgcap * 2 : 8;
        ObsCfgRec *nn = realloc(t->obscfg, (size_t)nc * sizeof(ObsCfgRec));
        if (!nn) return 0;
        t->obscfg = nn;
        t->obscfgcap = nc;
    }
    t->obscfg[t->nobscfg++] = *o;
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

/* An `O` record is a CONFIGURATION the reader installs into its own state
 * before it classifies, so every field has to satisfy exactly the invariants
 * the live builtins enforce (obs_window_arg, builtin_set_observer_scale,
 * builtin_set_observer_thresholds). A tape that says `window 0` is not a tape
 * this runtime wrote: installing it divides by zero inside the ring-buffer
 * sizing (`cnt % n`), and a negative or 4e9 window asks calloc for
 * 18446744073709551615 bytes. Tapes travel — #413 attached-tape bundles ship
 * them beside the program — so a corrupt one is refused loudly here, exactly
 * like a torn bundle archive, and never partially applied: a half-installed
 * configuration would print a verdict no live run gave, which is the failure
 * class these records exist to remove.
 *
 * Refusal, not clamping: a clamped window is a configuration the recording
 * run never had, so the label would still be a confident lie — just a
 * different one. */
static int obs_cfg_refuse(const char *why, const char *line) {
    fprintf(stderr, "step: tape observer-configuration record is not one this "
            "runtime could have written (%s): '%s'; refusing to step "
            "(docs/TRACE.md)\n", why, line);
    return 0;
}

static int obs_cfg_rec_ok(const ObsCfgRec *o, const char *line) {
    const char *why = NULL;
    /* `O win <name> 0` is the CLEAR form of the per-binding override and the
     * one legal window outside the range (set_observer_window takes it the
     * same way); the state default has no clear form. */
    if ((o->window != 0 || o->binding == 0) &&
        (o->window < OBSERVER_WINDOW_MIN || o->window > OBSERVER_WINDOW_MAX))
        why = "window depth outside its [4, 64] range";
    else if (o->binding == 0) {
        if (!(o->dh_zero > 0.0) || !(o->dh_small > 0.0) || !(o->h_low > 0.0))
            why = "thresholds must be positive";
        else if (!(o->dh_zero < o->dh_small))
            why = "dh_zero must be less than dh_small";
        else if (!(o->scale > 0.0) || !(o->scale <= 1e300))
            why = "scale must be positive and finite";
    }
    if (!why) return 1;
    return obs_cfg_refuse(why, line);
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
            case 'O': {   /* observer configuration (v3) — folded like S: it
                           * is not a stop event, it governs the records that
                           * FOLLOW it, so its `rec` is the next stored index */
                ObsCfgRec o;
                memset(&o, 0, sizeof o);
                o.rec = t->nrecs;
                o.scope = cur_scope;
                if (strncmp(p + 2, "cfg ", 4) == 0) {
                    char *q = p + 6, *q0;
                    int ok = 1;
                    o.binding  = 0;
                    q0 = q; o.dh_zero  = strtod(q, &q);        ok &= (q != q0);
                    q0 = q; o.dh_small = strtod(q, &q);        ok &= (q != q0);
                    q0 = q; o.h_low    = strtod(q, &q);        ok &= (q != q0);
                    q0 = q; o.window   = (int)strtol(q, &q, 10); ok &= (q != q0);
                    q0 = q; o.scale    = strtod(q, &q);        ok &= (q != q0);
                    if (!ok) return obs_cfg_refuse("truncated record", p);
                    if (!obs_cfg_rec_ok(&o, p)) return 0;
                    obscfg_push(t, &o);
                } else if (strncmp(p + 2, "win ", 4) == 0) {
                    char *nm = p + 6;
                    char *sp = strchr(nm, ' ');
                    if (sp) {
                        char *q = sp + 1, *q0 = q;
                        o.binding = 1;
                        o.window  = (int)strtol(q, &q, 10);
                        /* validated before the name is NUL-terminated in
                         * place, so the refusal can quote the whole line */
                        if (q == q0) return obs_cfg_refuse("truncated record", p);
                        if (!obs_cfg_rec_ok(&o, p)) return 0;
                        *sp = '\0';
                        o.name = nm;
                        obscfg_push(t, &o);
                    }
                }
                r.kind = 0;
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
    free(t->obscfg);
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

/* ---- observer configuration replay (#1044/#1045 follow-up) --------- */

/* Install a configuration into the reader's own EigsState: the runtime's
 * classifiers read it through the g_obs_* macros, so replaying the tape's
 * configuration is exactly "make the state say what the recording state
 * said". A reader with no attached state classifies at the compiled-in
 * defaults, which is what it did before. */
static void obs_cfg_install(const TapeObsCfg *c) {
    if (!eigs_current || !eigs_current->state) return;
    g_obs_dh_zero  = c->dh_zero;
    g_obs_dh_small = c->dh_small;
    g_obs_h_low    = c->h_low;
    g_obs_scale    = c->scale;
    g_obs_window   = c->window;
}

static void obs_cfg_capture(TapeObsCfg *c) {
    if (eigs_current && eigs_current->state) {
        c->dh_zero  = g_obs_dh_zero;
        c->dh_small = g_obs_dh_small;
        c->h_low    = g_obs_h_low;
        c->scale    = g_obs_scale;
        c->window   = g_obs_window;
        return;
    }
    c->dh_zero  = OBSERVER_DH_ZERO_DEFAULT;
    c->dh_small = OBSERVER_DH_SMALL_DEFAULT;
    c->h_low    = OBSERVER_H_LOW_DEFAULT;
    c->scale    = OBSERVER_SCALE_DEFAULT;
    c->window   = OBSERVER_WINDOW_N;
}

/* The one history on the whole tape carrying `name`, or NULL when there is
 * none or more than one. Used only as the last resort below: when a name is
 * unambiguous across the tape, a record naming it can only mean that binding,
 * and applying it there is a fact rather than a guess. */
static const NameHist *obs_win_unique(const Tape *t, const char *name) {
    const NameHist *found = NULL;
    for (int i = 0; i < t->nnames; i++) {
        if (strcmp(t->names[i].name, name) != 0) continue;
        if (found) return NULL;         /* ambiguous — refuse to guess */
        found = &t->names[i];
    }
    return found;
}

/* Which BINDING an `O win <name>` record named. The live call resolved the
 * name innermost-first from its own frame, so the reader resolves it the same
 * way, from the frame instance the record was written in (the writer stamps
 * the scope transition before the record, so that frame is always on the tape
 * even when it has not assigned yet).
 *
 * The result is an identity, not a name: the caller compares it against the
 * history it is folding with `==`. Comparing NAMES here is what leaked a
 * function-local override onto every other binding of that name — the exact
 * failure class this whole change exists to close.
 *
 * Falls back to obs_win_unique only when the scope walk resolves to nothing
 * at all (a binding whose history the call chain cannot reach — a closure
 * over a captured name, whose env parent is its definition site and not its
 * caller). NULL from both means "no binding this record can be proven to
 * govern": the override is then dropped, never sprayed by name. */
static const NameHist *obs_win_target(const Tape *t, const ObsCfgRec *o) {
    uint32_t sc = o->scope;
    for (;;) {
        const NameHist *h = tape_hist_for((Tape *)t, o->name, sc, 0);
        if (h) return h;
        if (sc == 0) return obs_win_unique(t, o->name);
        const ScopeInfo *si = tape_scope_info(t, sc);
        sc = si ? si->parent : 0;
    }
}

void tape_traj_begin(TapeTraj *tr, const Tape *t, const NameHist *h) {
    memset(&tr->slot, 0, sizeof tr->slot);
    tr->t = t;
    tr->h = h;
    tr->ci = 0;
    tr->fed = 0;
    obs_cfg_capture(&tr->saved);
    TapeObsCfg start = { OBSERVER_DH_ZERO_DEFAULT, OBSERVER_DH_SMALL_DEFAULT,
                         OBSERVER_H_LOW_DEFAULT, OBSERVER_SCALE_DEFAULT,
                         OBSERVER_WINDOW_N };
    obs_cfg_install(&start);
}

/* Apply one recorded configuration change to the fold in progress. */
static void obs_cfg_apply(TapeTraj *tr, const ObsCfgRec *o) {
    if (o->binding == 0) {
        TapeObsCfg c = { o->dh_zero, o->dh_small, o->h_low, o->scale,
                         o->window };
        obs_cfg_install(&c);
    } else if (tr->h && strcmp(o->name, tr->h->name) == 0) {
        /* Identity, not name equality: the record governs exactly the
         * binding it resolves to. Two invocations of one function are two
         * histories with the same name, and only the one whose frame made
         * the call carries the override. */
        if (obs_win_target(tr->t, o) == tr->h)
            tr->slot.win_override = (uint8_t)o->window;
    }
}

const char *tape_traj_feed(TapeTraj *tr, const Assign *a) {
    const Tape *t = tr->t;
    while (tr->ci < t->nobscfg && t->obscfg[tr->ci].rec <= a->rec)
        obs_cfg_apply(tr, &t->obscfg[tr->ci++]);
    if (!a->is_num) return NULL;
    observer_slot_record_value(&tr->slot, a->num);
    tr->fed++;
    return observer_slot_report_value(&tr->slot);
}

/* The knobs split by WHEN the runtime consumes them: the window and the
 * scale are read while a value is being RECORDED, the three thresholds while
 * a verdict is being REPORTED (and the window again, for the full-window
 * certifications). So a knob moved after a binding's last assign and before
 * the stop still changes what `report of x` says at that stop — and folding
 * the configuration only up to the last assign dropped exactly those,
 * printing `stable` where the live run printed `converged` for a nine-line
 * program. Settling walks the cursor on to the stop position and re-reads
 * the label under the configuration actually in force there.
 *
 * `pos` is a stop index; a record belongs to it when it precedes the first
 * record of the NEXT stop, which is the same bound the stepper uses to list
 * a step's events. */
const char *tape_traj_settle(TapeTraj *tr, int pos) {
    const Tape *t = tr->t;
    int bound = (pos + 1 < t->nsteps) ? t->steps[pos + 1] : t->nrecs;
    while (tr->ci < t->nobscfg && t->obscfg[tr->ci].rec < bound)
        obs_cfg_apply(tr, &t->obscfg[tr->ci++]);
    return tr->fed ? observer_slot_report_value(&tr->slot) : NULL;
}

void tape_traj_end(TapeTraj *tr) {
    free(tr->slot.v_window);
    free(tr->slot.vr_window);
    free(tr->slot.dh_window);
    memset(&tr->slot, 0, sizeof tr->slot);
    obs_cfg_install(&tr->saved);
}

const char *tape_classify_at(const Tape *t, const NameHist *h, int pos,
                             int *out_numeric) {
    TapeTraj tr;
    tape_traj_begin(&tr, t, h);
    for (int i = 0; i < h->n && h->a[i].step <= pos; i++)
        tape_traj_feed(&tr, &h->a[i]);
    /* The label at the STOP, not at the last assign: a knob moved between
     * the two is on the tape and was in force when the live run reported. */
    const char *label = tape_traj_settle(&tr, pos);
    int fed = tr.fed;   /* the label is a string literal — it outlives _end */
    tape_traj_end(&tr);
    if (out_numeric) *out_numeric = fed;
    return fed ? label : NULL;
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
