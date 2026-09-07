/* ================================================================
 * EigenScript tape reader — the shared tape model behind the CLI
 * stepper (`--step`, src/step.c) and the DAP server (src/eigsdap.c).
 * ================================================================
 * #539 v3 extracted this from step.c so the DAP server is a protocol
 * skin over the SAME model rather than a mirror that could drift.
 *
 * Pure reader — the tape is never executed. Position is an index into
 * the tape's L records; bindings at any position are a fold of the A
 * records before it; the call chain is reconstructed from the v2 S
 * records. Stepping backward is exactly as cheap as forward.
 *
 * Version policy (#411): the tape names its format and runtime on
 * line 1 and both must match this binary exactly, else tape_open
 * refuses with 3. Version-and-reject, never migrate.
 *
 * CLI-only class (Makefile CLI_ONLY): stdio-based, excluded from the
 * embed/LSP/freestanding builds like step.c itself.
 */
#ifndef EIGENSCRIPT_TAPE_READ_H
#define EIGENSCRIPT_TAPE_READ_H

#include <stdint.h>

/* One observer-configuration change recovered from the tape's `O` records
 * (#1044/#1045 follow-up). `rec` is the index of the first stored record the
 * change governs: `O` records are folded like `S` records, so the change
 * applies from that index ONWARD (test `rec <= assign->rec`).
 *
 * A verdict is a function of the assignments AND of these knobs, so a reader
 * that ignores them classifies at the state defaults and prints a label the
 * live run never gave. See docs/TRACE.md. */
typedef struct {
    int      rec;
    int      binding;       /* 0 = state-level `O cfg`; 1 = per-binding `O win` */
    double   dh_zero, dh_small, h_low, scale;   /* binding == 0 */
    int      window;        /* binding == 0: state default; 1: the override */
    const char *name;       /* binding == 1: the overridden binding */
    uint32_t scope;         /* binding == 1: frame instance the call resolved from */
} ObsCfgRec;

typedef struct {
    char kind;          /* 'L', 'A', 'N', 'V' */
    int  line;          /* L: source line */
    int  step;          /* index of the L record this event belongs to
                         * (events before the first L clamp to 0) */
    const char *name;   /* A/N: binding / builtin name (into tape buf) */
    const char *value;  /* A/N: serialized value (into tape buf) */
    uint32_t scope;     /* #539 v2: frame-instance serial this record
                         * belongs to (from the preceding S record;
                         * 0 = before any S). */
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
    uint32_t scope;     /* one history per (scope-instance, name) */
    Assign *a;
    int n, cap;
} NameHist;

/* One row per frame instance seen on the tape (S records). parent =
 * the frame instance beneath it on the reconstructed call stack at
 * push time, 0 for the base frame. */
typedef struct {
    uint32_t serial;
    const char *name;   /* chunk name: fn, <module>, <lambda> (into tape buf) */
    int depth;
    uint32_t parent;
} ScopeInfo;

typedef struct {
    char    *tape;      /* whole tape file, lines NUL-split in place */
    StepRec *recs;
    int      nrecs;
    int     *steps;     /* rec index of each L record */
    int      nsteps;
    NameHist *names;
    int      nnames, namecap;
    ScopeInfo *scopes;
    int      nscopes, scopecap;
    char   **src;       /* optional source lines (1-based view) */
    int      nsrc;
    char    *srcbuf;
    ObsCfgRec *obscfg;  /* observer-configuration changes, in tape order */
    int      nobscfg, obscfgcap;
} Tape;

/* Read + version-check + parse a tape (and optionally its source file)
 * into *t. Returns 0 on success; 1 when the tape is unreadable; 3 on a
 * version/format refusal or empty tape (the replay rule — the reason
 * is printed to stderr); 4 when the tape parsed but has no L records.
 * On any nonzero return *t is already freed. */
int  tape_open(Tape *t, const char *tape_path, const char *src_path);
void tape_free(Tape *t);

/* The (scope-instance, name) history, or NULL. */
NameHist  *tape_hist_for(Tape *t, const char *name, uint32_t scope, int create);
ScopeInfo *tape_scope_info(const Tape *t, uint32_t serial);

/* Latest assign of `h` visible at position `pos`, or NULL. */
const Assign *tape_latest_at(const NameHist *h, int pos);

/* ---- Trajectory replay (#294, made configuration-faithful by the
 * #1044/#1045 follow-up).
 *
 * The ONE place a tape's assigns are folded into a real ObserverSlot; `--step`
 * and the DAP server both drive it, so the label they print cannot drift from
 * each other or from the runtime's own classifier. It installs the observer
 * configuration the tape recorded — the state defaults, then every `O` record
 * up to the assign being fed — and restores the caller's configuration at
 * tape_traj_end, so a reader never leaks a tape's knobs into its own state.
 * tape_traj_settle then carries the configuration on to the STOP position,
 * because a verdict is reported there and not at the last assign.
 *
 * Requires eigenscript.h (ObserverSlot); every caller includes it first. */
typedef struct { double dh_zero, dh_small, h_low, scale; int window; } TapeObsCfg;

typedef struct {
    struct ObserverSlot slot;
    TapeObsCfg   saved;     /* the caller's configuration, restored at _end */
    const Tape  *t;
    const NameHist *h;      /* the BINDING being folded — identity, not name:
                             * an `O win` record is a property of one
                             * (scope-instance, name) binding, so it may only
                             * be applied to the history it resolves to */
    int          ci;        /* cursor into t->obscfg */
    int          fed;       /* numeric values folded so far */
} TapeTraj;

void        tape_traj_begin(TapeTraj *tr, const Tape *t, const NameHist *h);
/* Fold one assign; returns the label AFTER it, or NULL for a non-numeric
 * assign (which still advances the recorded configuration). */
const char *tape_traj_feed(TapeTraj *tr, const Assign *a);
/* Advance the configuration cursor to stop position `pos` and re-read the
 * label: the thresholds (and the window's full-window certifications) are
 * consumed when a verdict is REPORTED, so a knob moved after the binding's
 * last assign and before the stop still governs what the live run printed
 * there. Returns NULL when nothing numeric has been folded. Call after the
 * feed loop, before tape_traj_end. */
const char *tape_traj_settle(TapeTraj *tr, int pos);
void        tape_traj_end(TapeTraj *tr);

/* Feed name's numeric assigns visible at `pos` through a real
 * ObserverSlot and return the runtime's own trajectory label — NULL
 * when the binding has no numeric trajectory yet. The label is BY
 * CONSTRUCTION what `report_value of x` would have said (#294) at that stop,
 * under the configuration the tape recorded as being in force there
 * (docs/TRACE.md names the one residual: an override on a name a closure
 * captured, which the recorded call chain cannot resolve). */
const char *tape_classify_at(const Tape *t, const NameHist *h, int pos,
                             int *out_numeric);

/* The frame instance current at a stop position. */
uint32_t tape_scope_at(const Tape *t, int pos);

/* Resolve a name innermost-first along the reconstructed call chain. */
const NameHist *tape_resolve_at(const Tape *t, int pos, const char *name);

#endif /* EIGENSCRIPT_TAPE_READ_H */
