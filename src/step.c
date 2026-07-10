/* ================================================================
 * EigenScript tape-stepper — `eigenscript --step <tape> [source]`
 * ================================================================
 * The #418 eigsdap v1 surface: an interactive CLI debugger over a
 * recorded trace tape (EIGS_TRACE / --trace / --test --trace-on-fail).
 * Pure reader — the tape is never executed, so stepping BACKWARD is
 * exactly as cheap as forward: position is an index into the tape's
 * L records, and bindings at any position are a fold of the A records
 * before it.
 *
 * Trajectory labels come from the runtime's own #294 value-channel
 * classifier (observer_slot_record_value + observer_slot_report_value):
 * the stepper feeds each binding's reconstructed numeric history through
 * a real ObserverSlot, so a label here is BY CONSTRUCTION what
 * `report_value of x` would have said at that moment — a mirror
 * implementation could drift; this cannot.
 *
 * Version policy (#411): same rule as replay — the tape names its
 * format and runtime on line 1 and both must match this binary
 * exactly, else refuse with exit 3. Version-and-reject, never migrate.
 * A tape viewer that guessed at a foreign encoding would show
 * plausible-but-wrong state, the same silent divergence the header
 * exists to prevent.
 *
 * CLI-only (stdio + isatty): listed in the Makefile's CLI_ONLY set,
 * excluded from the embed/LSP/freestanding builds like main.c/repl.c.
 */

#include "eigenscript.h"
#include "trace.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

/* ---- tape model ------------------------------------------------ */

typedef struct {
    char kind;          /* 'L', 'A', 'N', 'V' */
    int  line;          /* L: source line */
    int  step;          /* index of the L record this event belongs to
                         * (events before the first L clamp to 0) */
    const char *name;   /* A/N: binding / builtin name (into tape buf) */
    const char *value;  /* A/N: serialized value (into tape buf) */
} StepRec;

typedef struct {
    int rec;            /* index into recs[] */
    int step;           /* visible from this position on */
    const char *value;
    double num;
    int is_num;
} Assign;

typedef struct {
    const char *name;
    Assign *a;
    int n, cap;
} NameHist;

typedef struct {
    char    *tape;      /* whole tape file, lines NUL-split in place */
    StepRec *recs;
    int      nrecs;
    int     *steps;     /* rec index of each L record */
    int      nsteps;
    NameHist *names;
    int      nnames, namecap;
    char   **src;       /* optional source lines (1-based view) */
    int      nsrc;
    char    *srcbuf;
} Tape;

/* ---- helpers ---------------------------------------------------- */

static char *read_whole_file(const char *path, long *out_len) {
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

static NameHist *hist_for(Tape *t, const char *name, int create) {
    for (int i = 0; i < t->nnames; i++)
        if (strcmp(t->names[i].name, name) == 0) return &t->names[i];
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
 * Returns 0 on version refusal (caller exits 3), 1 otherwise. */
static int tape_parse(Tape *t, long len) {
    /* count lines for one exact allocation */
    int nlines = 0;
    for (long i = 0; i < len; i++)
        if (t->tape[i] == '\n') nlines++;
    if (len > 0 && t->tape[len - 1] != '\n') nlines++;
    t->recs  = calloc(nlines ? (size_t)nlines : 1, sizeof(StepRec));
    t->steps = calloc(nlines ? (size_t)nlines : 1, sizeof(int));
    if (!t->recs || !t->steps) return 0;

    int first = 1;
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
                    NameHist *h = hist_for(t, r.name, 1);
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
    t->srcbuf = read_whole_file(path, &len);
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

/* ---- trajectory classification ---------------------------------- */

/* Feed name's numeric assigns visible at `pos` through a real
 * ObserverSlot and return the runtime's own label — NULL when the
 * binding has no numeric trajectory yet. */
static const char *classify_at(const NameHist *h, int pos, int *out_numeric) {
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
    free(s.dh_window);
    if (out_numeric) *out_numeric = fed;
    return label;
}

/* Latest assign of `h` visible at `pos`, or NULL. */
static const Assign *latest_at(const NameHist *h, int pos) {
    const Assign *last = NULL;
    for (int i = 0; i < h->n && h->a[i].step <= pos; i++) last = &h->a[i];
    return last;
}

/* ---- display ----------------------------------------------------- */

static void show_stop(const Tape *t, int pos) {
    int rec = t->steps[pos];
    int line = t->recs[rec].line;
    printf("step %d/%d  line %d\n", pos + 1, t->nsteps, line);
    if (t->src && line >= 1 && line <= t->nsrc)
        printf("  | %s\n", t->src[line - 1]);
    /* events that happened during this step (its A/N records) */
    int bound = (pos + 1 < t->nsteps) ? t->steps[pos + 1] : t->nrecs;
    for (int i = rec + 1; i < bound; i++) {
        const StepRec *r = &t->recs[i];
        if (r->kind == 'A') printf("  A %s=%s\n", r->name, r->value);
        if (r->kind == 'N') printf("  N %s=%s\n", r->name, r->value);
    }
}

static void show_bindings(const Tape *t, int pos, const char *only) {
    int shown = 0;
    for (int i = 0; i < t->nnames; i++) {
        const NameHist *h = &t->names[i];
        if (only && strcmp(h->name, only) != 0) continue;
        const Assign *last = latest_at(h, pos);
        if (!last) continue;                 /* not yet assigned here */
        int count = 0;
        for (int k = 0; k < h->n && h->a[k].step <= pos; k++) count++;
        const char *label = classify_at(h, pos, NULL);
        printf("%s = %s", h->name, last->value);
        if (label) printf("  [%s]", label);
        printf("  (%d assign%s)\n", count, count == 1 ? "" : "s");
        shown++;
    }
    if (!shown) {
        if (only) printf("no binding '%s' at this point\n", only);
        else      printf("no bindings yet\n");
    }
}

static void show_trajectory(const Tape *t, int pos, const char *name) {
    const NameHist *h = hist_for((Tape *)t, name, 0);
    if (!h || !latest_at(h, pos)) {
        printf("no binding '%s' at this point\n", name);
        return;
    }
    int total = 0;
    for (int i = 0; i < h->n && h->a[i].step <= pos; i++) total++;
    printf("%s: %d assign%s\n", name, total, total == 1 ? "" : "s");
    /* One slot fed incrementally: the label after the k-th numeric value
     * is exactly what report_value would have said at that moment. */
    ObserverSlot s;
    memset(&s, 0, sizeof s);
    int fed = 0;
    const int SHOW = 20;   /* print at most the last SHOW entries */
    int start = total > SHOW ? total - SHOW : 0;
    if (start > 0) printf("  … %d earlier assign(s) elided\n", start);
    for (int i = 0, k = 0; i < h->n && h->a[i].step <= pos; i++, k++) {
        const char *label = NULL;
        if (h->a[i].is_num) {
            observer_slot_record_value(&s, h->a[i].num);
            fed++;
            label = observer_slot_report_value(&s);
        }
        if (k < start) continue;
        printf("  #%-3d line %-5d %s", k + 1,
               t->recs[t->steps[h->a[i].step]].line, h->a[i].value);
        if (label) printf("   [%s]", label);
        printf("\n");
    }
    free(s.v_window);
    free(s.dh_window);
}

static void show_help(void) {
    printf(
        "commands:\n"
        "  s [n], <enter>   step forward (n lines)\n"
        "  b [n]            step backward\n"
        "  br <line>        set breakpoint; br  lists; del <line> removes\n"
        "  c / rc           continue forward / backward to a breakpoint\n"
        "  j <line> / jb <line>  jump to next / previous stop at <line>\n"
        "  p [name]         bindings here (value + trajectory label)\n"
        "  t <name>         a binding's trajectory up to here\n"
        "  i                tape info\n"
        "  q                quit\n");
}

/* ---- the stepper ------------------------------------------------- */

#define MAX_BP 64

int eigenscript_step(const char *tape_path, const char *src_path) {
    Tape t;
    memset(&t, 0, sizeof t);

    long len = 0;
    t.tape = read_whole_file(tape_path, &len);
    if (!t.tape) {
        fprintf(stderr, "step: cannot read tape '%s'\n", tape_path);
        return 1;
    }
    if (len == 0) {
        fprintf(stderr, "step: empty tape — refusing to step "
                "(docs/TRACE.md)\n");
        free(t.tape);
        return 3;
    }
    if (!tape_parse(&t, len)) {
        /* vline_ok printed the reason; calloc failure has errno unset but
         * the distinction doesn't matter to the caller: no session. */
        free(t.tape); free(t.recs); free(t.steps);
        for (int i = 0; i < t.nnames; i++) free(t.names[i].a);
        free(t.names);
        return 3;
    }
    if (t.nsteps == 0) {
        fprintf(stderr, "step: tape has no line events (L records) — "
                "nothing to step\n");
        free(t.tape); free(t.recs); free(t.steps);
        for (int i = 0; i < t.nnames; i++) free(t.names[i].a);
        free(t.names);
        return 1;
    }
    if (src_path) load_source(&t, src_path);

    int nA = 0, nN = 0;
    for (int i = 0; i < t.nrecs; i++) {
        if (t.recs[i].kind == 'A') nA++;
        if (t.recs[i].kind == 'N') nN++;
    }
    printf("tape %s: %d steps, %d assigns (%d bindings), %d nondet records\n",
           tape_path, t.nsteps, nA, t.nnames, nN);

    int pos = 0;
    int bp[MAX_BP], nbp = 0;
    int tty = isatty(fileno(stdin));
    char buf[512];

    show_stop(&t, pos);
    for (;;) {
        if (tty) { printf("(step) "); fflush(stdout); }
        if (!fgets(buf, sizeof buf, stdin)) break;      /* EOF = quit */
        buf[strcspn(buf, "\n")] = '\0';
        char *cmd = strtok(buf, " \t");
        char *arg = strtok(NULL, " \t");

        if (!cmd || strcmp(cmd, "s") == 0) {            /* step forward */
            int n = arg ? atoi(arg) : 1;
            if (n < 1) n = 1;
            if (pos + 1 >= t.nsteps && n > 0) { printf("at end of tape\n"); continue; }
            pos = (pos + n < t.nsteps) ? pos + n : t.nsteps - 1;
            show_stop(&t, pos);
        } else if (strcmp(cmd, "b") == 0) {             /* step back */
            int n = arg ? atoi(arg) : 1;
            if (n < 1) n = 1;
            if (pos == 0) { printf("at start of tape\n"); continue; }
            pos = (pos - n > 0) ? pos - n : 0;
            show_stop(&t, pos);
        } else if (strcmp(cmd, "c") == 0 || strcmp(cmd, "rc") == 0) {
            int dir = (cmd[0] == 'c') ? 1 : -1;
            int q = pos, hit = 0;
            while (q + dir >= 0 && q + dir < t.nsteps) {
                q += dir;
                int line = t.recs[t.steps[q]].line;
                for (int k = 0; k < nbp; k++)
                    if (bp[k] == line) { hit = 1; break; }
                if (hit) break;
            }
            if (!hit) printf(dir > 0 ? "no breakpoint hit — at end of tape\n"
                                     : "no breakpoint hit — at start of tape\n");
            pos = q;
            show_stop(&t, pos);
        } else if (strcmp(cmd, "br") == 0) {
            if (!arg) {
                if (!nbp) printf("no breakpoints\n");
                for (int k = 0; k < nbp; k++) printf("breakpoint at line %d\n", bp[k]);
            } else if (nbp < MAX_BP) {
                bp[nbp++] = atoi(arg);
                printf("breakpoint at line %d\n", bp[nbp - 1]);
            } else printf("breakpoint table full (%d)\n", MAX_BP);
        } else if (strcmp(cmd, "del") == 0 && arg) {
            int line = atoi(arg), found = 0;
            for (int k = 0; k < nbp; k++)
                if (bp[k] == line) { bp[k] = bp[--nbp]; found = 1; break; }
            printf(found ? "deleted breakpoint at line %d\n"
                         : "no breakpoint at line %d\n", line);
        } else if ((strcmp(cmd, "j") == 0 || strcmp(cmd, "jb") == 0) && arg) {
            int line = atoi(arg);
            int dir = (cmd[1] == '\0') ? 1 : -1;
            int q = pos, hit = 0;
            while (q + dir >= 0 && q + dir < t.nsteps) {
                q += dir;
                if (t.recs[t.steps[q]].line == line) { hit = 1; break; }
            }
            if (!hit) { printf("no %s occurrence of line %d\n",
                               dir > 0 ? "later" : "earlier", line); continue; }
            pos = q;
            show_stop(&t, pos);
        } else if (strcmp(cmd, "p") == 0) {
            show_bindings(&t, pos, arg);
        } else if (strcmp(cmd, "t") == 0 && arg) {
            show_trajectory(&t, pos, arg);
        } else if (strcmp(cmd, "i") == 0) {
            printf("tape %s: %d steps, %d assigns (%d bindings), %d nondet "
                   "records; at step %d/%d\n",
                   tape_path, t.nsteps, nA, t.nnames, nN, pos + 1, t.nsteps);
        } else if (strcmp(cmd, "h") == 0 || strcmp(cmd, "help") == 0) {
            show_help();
        } else if (strcmp(cmd, "q") == 0 || strcmp(cmd, "quit") == 0) {
            break;
        } else {
            printf("unknown command '%s' (h for help)\n", cmd);
        }
    }

    free(t.tape); free(t.recs); free(t.steps);
    for (int i = 0; i < t.nnames; i++) free(t.names[i].a);
    free(t.names);
    free(t.src); free(t.srcbuf);
    return 0;
}
