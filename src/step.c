/* ================================================================
 * EigenScript tape-stepper — `eigenscript --step <tape> [source]`
 * ================================================================
 * The #418 eigsdap v1 surface: an interactive CLI debugger over a
 * recorded trace tape (EIGS_TRACE / --trace / --test --trace-on-fail).
 * Pure reader — the tape is never executed, so stepping BACKWARD is
 * exactly as cheap as forward.
 *
 * The tape model (parse, fold, scope-chain resolution, trajectory
 * classification via the runtime's own #294 ObserverSlot) lives in
 * src/tape_read.c since #539 v3, shared byte-for-byte with the DAP
 * server (src/eigsdap.c) — a mirror implementation could drift; the
 * shared model cannot.
 *
 * Version policy (#411): same rule as replay — the tape names its
 * format and runtime on line 1 and both must match this binary
 * exactly, else refuse with exit 3 (enforced by tape_open).
 *
 * CLI-only (stdio + isatty): listed in the Makefile's CLI_ONLY set,
 * excluded from the embed/LSP/freestanding builds like main.c/repl.c.
 */

#include "eigenscript.h"
#include "trace.h"
#include "tape_read.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

static void print_binding(int pos, const NameHist *h,
                          const char *scope_note) {
    const Assign *last = tape_latest_at(h, pos);
    int count = 0;
    for (int k = 0; k < h->n && h->a[k].step <= pos; k++) count++;
    const char *label = tape_classify_at(h, pos, NULL);
    printf("%s = %s", h->name, last->value);
    if (label) printf("  [%s]", label);
    printf("  (%d assign%s)", count, count == 1 ? "" : "s");
    if (scope_note) printf("  {%s}", scope_note);
    printf("\n");
}

/* #539 v2: bindings shown are the live call chain's, innermost frame
 * first — a function-local i and the top-level i are separate streams
 * (fn-frame bindings get an {in fn} note; a shadowed outer binding of
 * the same name is skipped). Dead frames' locals no longer appear. */
static void show_bindings(const Tape *t, int pos, const char *only) {
    int shown = 0;
    if (only) {
        const NameHist *h = tape_resolve_at(t, pos, only);
        if (h) {
            const ScopeInfo *si = tape_scope_info(t, h->scope);
            char note[160] = "";
            if (si && si->depth > 0)
                snprintf(note, sizeof note, "in %s", si->name);
            print_binding(pos, h, note[0] ? note : NULL);
            shown = 1;
        }
        if (!shown) printf("no binding '%s' at this point\n", only);
        return;
    }
    /* chain walk, innermost first; a name shown once shadows outer ones */
    const char *seen[512]; int nseen = 0;
    uint32_t sc = tape_scope_at(t, pos);
    for (;;) {
        const ScopeInfo *si = tape_scope_info(t, sc);
        char note[160] = "";
        if (si && si->depth > 0) snprintf(note, sizeof note, "in %s", si->name);
        for (int i = 0; i < t->nnames; i++) {
            const NameHist *h = &t->names[i];
            if (h->scope != sc) continue;
            /* #736: the loop machinery's own bindings are implementation
             * detail — keep them out of the unfiltered listing. `p
             * __loop_exit__` still answers: an explicit request is not a
             * leak, and the tape's binding count stays honest. */
            if (trace_name_is_internal(h->name)) continue;
            if (!tape_latest_at(h, pos)) continue;
            int shadowed = 0;
            for (int k = 0; k < nseen; k++)
                if (strcmp(seen[k], h->name) == 0) { shadowed = 1; break; }
            if (shadowed) continue;
            if (nseen < (int)(sizeof(seen)/sizeof(seen[0])))
                seen[nseen++] = h->name;
            print_binding(pos, h, note[0] ? note : NULL);
            shown++;
        }
        if (sc == 0) break;
        sc = si ? si->parent : 0;
    }
    if (!shown) printf("no bindings yet\n");
}

static void show_trajectory(const Tape *t, int pos, const char *name) {
    const NameHist *h = tape_resolve_at(t, pos, name);   /* #539 v2 chain walk */
    if (!h) {
        printf("no binding '%s' at this point\n", name);
        return;
    }
    {
        const ScopeInfo *si = tape_scope_info(t, h->scope);
        if (si && si->depth > 0)
            printf("(%s in %s, frame #%u)\n", name, si->name, h->scope);
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
    free(s.vr_window);
    free(s.dh_window);
    (void)fed;
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
    int orc = tape_open(&t, tape_path, src_path);
    if (orc == 4) return 1;   /* no L records: not a session, not a refusal */
    if (orc != 0) return orc;

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
            if (pos + 1 >= t.nsteps) { printf("at end of tape\n"); continue; }
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

    tape_free(&t);
    return 0;
}
