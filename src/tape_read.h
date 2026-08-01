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

/* Feed name's numeric assigns visible at `pos` through a real
 * ObserverSlot and return the runtime's own trajectory label — NULL
 * when the binding has no numeric trajectory yet. The label is BY
 * CONSTRUCTION what `report_value of x` would have said (#294). */
const char *tape_classify_at(const NameHist *h, int pos, int *out_numeric);

/* The frame instance current at a stop position. */
uint32_t tape_scope_at(const Tape *t, int pos);

/* Resolve a name innermost-first along the reconstructed call chain. */
const NameHist *tape_resolve_at(const Tape *t, int pos, const char *name);

#endif /* EIGENSCRIPT_TAPE_READ_H */
