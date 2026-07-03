/* ================================================================
 * EigenScript Trace — implementation (Phase 1 + 2).
 * ================================================================
 * Tape format (text, one record per line):
 *   L <line>                    source-line event
 *   A <name>=<value>            name-keyed assignment delta
 *   N <fn>=<value>              nondeterministic builtin return
 *
 * Value encoding:
 *   <num>          numeric (immediate, tracked, or heap VAL_NUM)
 *   null           VAL_NULL / immediate null slot
 *   true|false
 *   "<str…>"       heap string, content truncated at TRACE_STR_MAX
 *   <list:N>       heap list of length N (content in Phase 2.5)
 *   <dict:N>       heap dict of size N
 *   <fn>           heap function/builtin
 *   <buffer:N>     heap buffer of length N
 *   <heap>         other heap types (fallback)
 *
 * Phase 2 also dedupes adjacent identical L events that have no A/N
 * between them — the compiler emits per-statement LINEs and bare
 * repeats are pure noise. An A or N event resets the dirty bit so the
 * next L always fires after progress was made.
 */

#include "eigenscript.h"
#include "trace.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TRACE_STR_MAX     60       /* truncate strings in `A` events */
#define TRACE_NONDET_MAX  65536    /* per-record cap for `N` events;
                                    * over-cap payloads emit a marker so
                                    * tape stays sized for visual debug */

int g_trace_enabled = 0;
int g_replay_enabled = 0;
int g_trace_obs_hist = 0;
int g_trace_hist = 0;
int g_trace_current_line = 0;

/* ----- Phase 3.0a: prev-value table.
 *
 * Open-addressing hash table keyed by interned name pointer. Each entry
 * holds the slot most recently assigned to that name (`current`) and
 * the one immediately before it (`prev`). `prev of x` reads `prev`.
 *
 * Refcount discipline: stored heap/tracked slots are incref'd on store
 * and decref'd on displacement or shutdown. Immediate slots (number,
 * null, bool) are no-ops for slot_incref/decref, so the same code path
 * is correct for every Value shape.
 *
 * The table runs unconditionally — `prev of x` must work whether or
 * not EIGS_TRACE is set, because it's a language-level interrogative,
 * not a debug-tape feature. Per-assign cost is ~one cache line read +
 * a pointer-equality compare. */

typedef struct {
    int      line;
    EigsSlot value;
} HistoryEntry;

/* Observer-state snapshot per assignment, captured only while
 * g_trace_obs_hist is set. Parallel to the history array: history[i]
 * pairs with obs[i - obs_start] when i >= obs_start (obs_start is the
 * history index of the first captured assign — the flag can flip on
 * mid-run when eval/REPL compiles a historical observer query).
 * valid == 0 marks assigns whose slot had no observer state (untracked
 * immediates, e.g. writes inside `unobserved` blocks). */
typedef struct {
    double  entropy;
    double  dH;
    double  last_entropy;
    uint8_t valid;
} ObsHistEntry;

/* Phase 4 snapshot cache: a periodic line-floor index over the history.
 * Segment k summarizes history[k<<HIST_SEG_SHIFT .. (k+1)<<HIST_SEG_SHIFT)
 * as the minimum line stamp in that range. Backward queries skip whole
 * segments whose floor exceeds the query line, turning the per-name scan
 * from O(H) into O(H/SEG + SEG). 64 entries/segment keeps the index at
 * ~1.5% of history size while bounding the residual scan at one segment. */
#define HIST_SEG_SHIFT 6
#define HIST_SEG       (1 << HIST_SEG_SHIFT)

typedef struct {
    const char    *name;
    EigsSlot       prev;
    EigsSlot       current;
    uint8_t        has_current;
    uint8_t        has_prev;
    uint8_t        seg_dead;    /* index alloc failed — it is stale; fall
                                 * back to plain linear scan for this name */
    HistoryEntry  *history;     /* append-only, indexed by assign order */
    int            hist_count;
    int            hist_cap;
    int           *seg_min;     /* per-segment minimum line stamp */
    int            seg_cap;
    ObsHistEntry  *obs;         /* observer snapshots; see ObsHistEntry */
    int            obs_start;
    int            obs_cap;
} PrevEntry;

static PrevEntry *g_prev_tab = NULL;
static int        g_prev_cap = 0;   /* power of two */
static int        g_prev_count = 0;

/* g_trace_current_line (exported, see trace.h) replaces the old static
 * line cache: OP_LINE stores it directly instead of paying a call. */

#define PREV_INIT_CAP 16
#define PREV_LOAD_NUM 3            /* grow when count*4 >= cap*3  (~75%) */
#define PREV_LOAD_DEN 4

static uint32_t prev_hash_ptr(const char *p) {
    /* Fibonacci hash of the pointer bits; interned strings already
     * provide identity, so this just spreads bits across the table. */
    uint64_t x = (uint64_t)(uintptr_t)p;
    x ^= x >> 33;
    x *= 0xff51afd7ed558ccdULL;
    x ^= x >> 33;
    return (uint32_t)x;
}

static PrevEntry *prev_lookup_slot(PrevEntry *tab, int cap, const char *name) {
    uint32_t mask = (uint32_t)(cap - 1);
    uint32_t i = prev_hash_ptr(name) & mask;
    while (tab[i].name && tab[i].name != name) {
        i = (i + 1) & mask;
    }
    return &tab[i];
}

static void prev_grow(void) {
    int new_cap = g_prev_cap ? g_prev_cap * 2 : PREV_INIT_CAP;
    PrevEntry *nt = calloc((size_t)new_cap, sizeof(PrevEntry));
    if (!nt) return;
    for (int i = 0; i < g_prev_cap; i++) {
        PrevEntry *e = &g_prev_tab[i];
        if (!e->name) continue;
        PrevEntry *dst = prev_lookup_slot(nt, new_cap, e->name);
        *dst = *e;
    }
    free(g_prev_tab);
    g_prev_tab = nt;
    g_prev_cap = new_cap;
}

static void prev_record_assign(const char *name, EigsSlot value) {
    if (!name) return;
    if (g_prev_count * PREV_LOAD_DEN >= g_prev_cap * PREV_LOAD_NUM) {
        prev_grow();
        if (!g_prev_tab) return;
    }
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, name);
    if (!e->name) {
        e->name = name;
        g_prev_count++;
    }
    if (e->has_current) {
        /* Shift current -> prev; drop the old prev. */
        if (e->has_prev) slot_decref(e->prev);
        e->prev = e->current;
        e->has_prev = 1;
    }
    slot_incref(value);
    e->current = value;
    e->has_current = 1;

    /* Append to history for `at <line>` queries. Stamp with the
     * current VM line as cached by trace_line. */
    if (e->hist_count >= e->hist_cap) {
        int new_cap = e->hist_cap ? e->hist_cap * 2 : 8;
        HistoryEntry *nh = realloc(e->history, (size_t)new_cap * sizeof(HistoryEntry));
        if (!nh) return;
        e->history = nh;
        e->hist_cap = new_cap;
    }
    slot_incref(value);
    int idx = e->hist_count;
    e->history[idx].line  = g_trace_current_line;
    e->history[idx].value = value;
    e->hist_count++;

    /* Maintain the periodic line-floor index. */
    if (!e->seg_dead) {
        int seg = idx >> HIST_SEG_SHIFT;
        if (seg >= e->seg_cap) {
            int nc = e->seg_cap ? e->seg_cap * 2 : 4;
            int *ns = realloc(e->seg_min, (size_t)nc * sizeof(int));
            if (!ns) {
                e->seg_dead = 1;   /* keep history; queries go linear */
            } else {
                e->seg_min = ns;
                e->seg_cap = nc;
            }
        }
        if (!e->seg_dead) {
            if ((idx & (HIST_SEG - 1)) == 0 || g_trace_current_line < e->seg_min[seg])
                e->seg_min[seg] = g_trace_current_line;
        }
    }

    /* Observer-state capture for `where/why/how ... at <line>`. The
     * OBSERVE op ran before this hook and left a tracked Value with
     * carried-over (dirty) observer state on the stack, so forcing
     * freshness here computes exactly what a live interrogative at
     * this point would see. */
    if (__builtin_expect(g_trace_obs_hist, 0)) {
        if (!e->obs) e->obs_start = idx;
        int oi = idx - e->obs_start;
        if (oi >= 0) {
            if (oi >= e->obs_cap) {
                int nc = e->obs_cap ? e->obs_cap * 2 : 8;
                while (nc <= oi) nc *= 2;
                ObsHistEntry *no = realloc(e->obs, (size_t)nc * sizeof(ObsHistEntry));
                if (no) { e->obs = no; e->obs_cap = nc; }
            }
            if (oi < e->obs_cap) {
                /* #262 Step E: observer state lives on the Env slot, not the
                 * Value — leave the snapshot empty here; OBSERVE_NAME_POST fills
                 * it from the fresh slot via trace_record_obs (runs after the
                 * SET that created this history entry). */
                e->obs[oi].valid = 0;
            }
        }
    }
}

/* #262 Phase-3 D2: patch the observer snapshot for `name`'s most recent
 * history entry from the slot-model trajectory. Called by OBSERVE_NAME_POST
 * after the binding's slot is freshly updated, so `where/why/how is x at L`
 * sources entropy/dH from the Env slot rather than the (Step-E-doomed) Value
 * observer fields. The history entry and its parallel obs slot were created by
 * the preceding prev_record_assign — the SET runs before OBSERVE_NAME_POST —
 * so this overwrites a just-written (and, pre-flip, identical value-sourced)
 * entry, or fills the valid=0 entry left once observed numbers become
 * immediates. `name` must be the interned constant (pointer-keyed lookup).
 * Gated by g_trace_obs_hist at the call site. */
void trace_record_obs(const char *name, double entropy, double dH,
                      double last_entropy) {
    if (!g_prev_tab || !name) return;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, name);
    if (!e->name || e->hist_count == 0 || !e->obs) return;
    int idx = e->hist_count - 1;
    int oi = idx - e->obs_start;
    if (oi < 0 || oi >= e->obs_cap) return;
    ObsHistEntry *o = &e->obs[oi];
    o->entropy = entropy;
    o->dH = dH;
    o->last_entropy = last_entropy;
    o->valid = 1;
}

int trace_query_prev(const char *interned_name, EigsSlot *out) {
    if (!interned_name || !out || !g_prev_tab) return 0;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, interned_name);
    if (!e->name || !e->has_prev) return 0;
    *out = e->prev;
    slot_incref(*out);
    return 1;
}

/* Walk history backward — entries are appended in execution order, so
 * the array is monotone-ish but not strictly sorted (a backward jump
 * could in principle re-execute earlier lines; the latest such write
 * is the answer, which is exactly what backward scan from the end
 * gives us).
 *
 * The line-floor index prunes the walk: a segment whose minimum line
 * stamp exceeds the query line cannot contain a hit, so it is skipped
 * in one compare. When a segment's floor is ≤ the query line it holds
 * at least one qualifying entry, and the backward scan inside it finds
 * the latest one — which is the global answer, since all later segments
 * were ruled out. Loop-heavy histories (many assigns stamped with the
 * same few lines) skip in O(H/SEG); the residual scan is ≤ SEG entries. */
static int find_hist_idx_at_or_before(PrevEntry *e, int line) {
    int i = e->hist_count - 1;
    if (e->seg_min && !e->seg_dead) {
        while (i >= 0) {
            int seg = i >> HIST_SEG_SHIFT;
            int seg_start = seg << HIST_SEG_SHIFT;
            if (e->seg_min[seg] > line) {
                i = seg_start - 1;
                continue;
            }
            for (; i >= seg_start; i--) {
                if (e->history[i].line <= line) return i;
            }
        }
        return -1;
    }
    for (; i >= 0; i--) {
        if (e->history[i].line <= line) return i;
    }
    return -1;
}

int trace_query_at(int kind, const char *interned_name, int line, EigsSlot *out) {
    if (!interned_name || !out || !g_prev_tab) return 0;
    PrevEntry *e = prev_lookup_slot(g_prev_tab, g_prev_cap, interned_name);
    if (!e->name) return 0;

    if (kind == 1) {
        /* `who is x at L` — binding name is timeless. */
        Value *s = make_str(interned_name);
        *out = slot_from_value(s);
        return 1;
    }

    if (kind == 2) {
        /* `when is x at L` — count of assignments with line ≤ L. */
        int count = 0;
        for (int i = 0; i < e->hist_count; i++) {
            if (e->history[i].line <= line) count++;
        }
        *out = slot_from_num((double)count);
        return 1;
    }

    int idx = find_hist_idx_at_or_before(e, line);
    if (idx < 0) return 0;

    if (kind >= 3 && kind <= 5) {
        /* where/why/how — read the observer snapshot captured at that
         * assign. Mirrors the live INTERROGATE formulas. */
        if (!e->obs || idx < e->obs_start ||
            idx - e->obs_start >= e->obs_cap) return 0;
        ObsHistEntry *o = &e->obs[idx - e->obs_start];
        if (!o->valid) return 0;
        double r = (kind == 3) ? o->entropy
                 : (kind == 4) ? o->dH
                 : (o->last_entropy > 0 ? 1.0 - o->entropy / o->last_entropy
                                        : 1.0);
        *out = slot_from_num(r);
        return 1;
    }

    if (kind == 0) {
        /* `what is x at L` — value at most recent assign ≤ L. */
        *out = e->history[idx].value;
        slot_incref(*out);
        return 1;
    }

    if (kind == 6) {
        /* `prev of x at L` — value at the assign immediately preceding
         * the one that produced `x`'s state at L. */
        if (idx < 1) return 0;
        *out = e->history[idx - 1].value;
        slot_incref(*out);
        return 1;
    }

    return 0;
}

Value *trace_state_at(int line) {
    Value *out = make_dict(g_prev_count > 0 ? g_prev_count : 8);
    if (!out || !g_prev_tab) return out;
    for (int i = 0; i < g_prev_cap; i++) {
        PrevEntry *e = &g_prev_tab[i];
        if (!e->name || e->hist_count == 0) continue;
        int idx = find_hist_idx_at_or_before(e, line);
        if (idx < 0) continue;
        Value *v = slot_to_value(e->history[idx].value);
        dict_set(out, e->name, v);
        val_decref(v);
    }
    return out;
}

static FILE *g_trace_fp = NULL;
static int   g_trace_initialized = 0;

/* Line dedupe state. g_last_line < 0 means "no line written yet, always
 * emit". g_line_dirty == 1 means an A or N event landed since the last
 * L, so the next L is meaningful even if numerically identical. */
static int g_last_line  = -1;
static int g_line_dirty = 0;

/* ----- Embed byte-sink seam (trace_set_sink).
 *
 * The freestanding profile has no filesystem, so EIGS_TRACE's fopen is
 * compiled out there — but the tape itself is just bytes. An embedder
 * (EigenOS M11: the machine journal) installs a sink callback and the
 * emit primitives below hand it complete record lines (newline
 * included); a record longer than the staging buffer arrives in
 * chunks, still in order. Installing a sink enables recording exactly
 * like EIGS_TRACE does hosted; the two paths are independent sinks of
 * the same byte stream (in practice an embedder uses one or the
 * other). All emitters funnel through tp_putc/tp_puts/tp_printf. */
static void (*g_trace_sink)(const char *bytes, size_t len, void *ud) = NULL;
static void *g_trace_sink_ud = NULL;
#define TRACE_SINK_LINEBUF 4096
static char   g_sink_buf[TRACE_SINK_LINEBUF];
static size_t g_sink_len = 0;

static void sink_flush(void) {
    if (g_trace_sink && g_sink_len) {
        g_trace_sink(g_sink_buf, g_sink_len, g_trace_sink_ud);
        g_sink_len = 0;
    }
}

static int trace_out_active(void) {
    return g_trace_fp != NULL || g_trace_sink != NULL;
}

static void tp_putc(int c) {
    if (g_trace_sink) {
        g_sink_buf[g_sink_len++] = (char)c;
        if (g_sink_len == TRACE_SINK_LINEBUF || c == '\n') sink_flush();
    }
    if (g_trace_fp) fputc(c, g_trace_fp);
}

static void tp_write(const char *s, size_t n) {
    for (size_t i = 0; i < n; i++) tp_putc(s[i]);
}

static void tp_puts(const char *s) { tp_write(s, strlen(s)); }

static void tp_printf(const char *fmt, ...) {
    char buf[128];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    if (n <= 0) return;
    if (n >= (int)sizeof buf) n = (int)sizeof buf - 1;
    tp_write(buf, (size_t)n);
}

void trace_set_sink(void (*cb)(const char *, size_t, void *), void *ud) {
    if (cb) {
        g_trace_sink = cb;
        g_trace_sink_ud = ud;
        g_sink_len = 0;
        g_last_line = -1;
        g_line_dirty = 0;
        g_trace_enabled = 1;
        g_trace_hist = 1;
    } else {
        sink_flush();
        g_trace_sink = NULL;
        g_trace_sink_ud = NULL;
        if (!g_trace_fp) g_trace_enabled = 0;
    }
}

/* Forward decl — implementation below; called from trace_init. */
static void trace_replay_init(void);

void trace_init(void) {
    if (g_trace_initialized) return;
    g_trace_initialized = 1;

    /* g_trace_enabled now means "a tape is open" (it used to be set
     * unconditionally so the prev-table worked; that made every program
     * pay history-recording costs — see g_trace_hist in trace.h). The
     * compiler turns on g_trace_hist when the program actually contains
     * a temporal query; a tape implies full recording, so set both
     * below once the tape opens. */

    /* Phase 3 — if EIGS_REPLAY is set, open that tape for streaming reads.
     * Done first so trace_init can succeed even if EIGS_TRACE is unset. */
    trace_replay_init();

#if EIGENSCRIPT_FREESTANDING
    /* Tape files need a filesystem; EIGS_TRACE is a hosted tool. The
     * in-memory temporal machinery (g_trace_hist etc.) is unaffected. */
    return;
#else
    const char *path = getenv("EIGS_TRACE");
    if (!path || !*path) return;

    /* NB: bare fopen("w") here means the trace file's mode is 0666 & ~umask
     * — under a permissive umask it could land world-writable (CodeQL
     * cpp/world-writable-file-creation #101). Left as-is because the path
     * comes from the EIGS_TRACE env var, which already carries the accepted
     * cpp/path-injection alert #107 at this line; any rewrite that uses
     * open() instead of fopen() moves the sink line and CodeQL files a
     * "new" path-injection alert in addition to keeping #107 open. The
     * trace file is opt-in (env var off by default) and the surrounding
     * filesystem is operator-controlled, so the residual exposure is
     * limited. */
    g_trace_fp = fopen(path, "w");
    if (!g_trace_fp) {
        fprintf(stderr, "trace: cannot open EIGS_TRACE=%s: %s\n",
                path, strerror(errno));
        return;
    }
    setvbuf(g_trace_fp, NULL, _IOFBF, 64 * 1024);
    g_trace_enabled = 1;
    g_trace_hist = 1;
#endif /* !EIGENSCRIPT_FREESTANDING */
}

/* ----- Phase 3: replay reader.
 *
 * Streams an existing tape (written by a prior EIGS_TRACE run) and serves
 * the N records to nondet builtins in order via trace_replay_take. L and
 * A records are skipped — the contract is that nondet outcomes appear in
 * the same order both runs, not that line numbers line up exactly. */

static FILE *g_replay_fp = NULL;
static char *g_replay_line = NULL;     /* growable read buffer */
static size_t g_replay_cap = 0;
static int   g_replay_strict = 0;      /* EIGS_REPLAY_STRICT=1: mismatch is fatal */

/* Embed replay source (trace_set_replay_mem): the whole tape as bytes,
 * copied in (the embedder's buffer may go away). The freestanding
 * counterpart of EIGS_REPLAY — EigenOS M11 reads the journal from its
 * store and hands it here. */
static char  *g_replay_mem = NULL;
static size_t g_replay_mem_len = 0;
static size_t g_replay_mem_pos = 0;

int trace_set_replay_mem(const char *bytes, size_t len, int strict) {
    free(g_replay_mem);
    g_replay_mem = NULL;
    g_replay_mem_len = 0;
    g_replay_mem_pos = 0;
    if (!bytes) {
        if (!g_replay_fp) g_replay_enabled = 0;
        return 1;
    }
    g_replay_mem = malloc(len > 0 ? len : 1);
    if (!g_replay_mem) return 0;
    memcpy(g_replay_mem, bytes, len);
    g_replay_mem_len = len;
    g_replay_strict = strict;
    g_replay_enabled = 1;
    return 1;
}

static void trace_replay_init(void) {
#if EIGENSCRIPT_FREESTANDING
    return;   /* tape files need a filesystem; replay is a hosted tool */
#else
    const char *path = getenv("EIGS_REPLAY");
    if (!path || !*path) return;
    g_replay_fp = fopen(path, "r");
    if (!g_replay_fp) {
        fprintf(stderr, "trace: cannot open EIGS_REPLAY=%s: %s\n",
                path, strerror(errno));
        return;
    }
    const char *strict = getenv("EIGS_REPLAY_STRICT");
    g_replay_strict = (strict && strict[0] && strcmp(strict, "0") != 0);
    g_replay_enabled = 1;
#endif /* !EIGENSCRIPT_FREESTANDING */
}

static void replay_shutdown(void) {
#if !EIGENSCRIPT_FREESTANDING
    if (g_replay_fp) { fclose(g_replay_fp); g_replay_fp = NULL; }
#endif
    free(g_replay_line); g_replay_line = NULL; g_replay_cap = 0;
    free(g_replay_mem);  g_replay_mem = NULL;
    g_replay_mem_len = 0; g_replay_mem_pos = 0;
    g_replay_enabled = 0;
}

/* getline that does not need _GNU_SOURCE — keeps a growable buffer in the
 * file-static slot, reads up to and including the next newline (or EOF).
 * Returns the length (newline NOT included, NUL-terminated) or -1 at EOF. */
static int read_tape_line(void) {
    if (g_replay_mem) {
        /* serve the next newline-terminated line from the memory tape */
        if (g_replay_mem_pos >= g_replay_mem_len) return -1;
        if (g_replay_cap < 256) {
            g_replay_cap = 256;
            g_replay_line = realloc(g_replay_line, g_replay_cap);
            if (!g_replay_line) { g_replay_cap = 0; return -1; }
        }
        size_t len = 0;
        while (g_replay_mem_pos < g_replay_mem_len) {
            char c = g_replay_mem[g_replay_mem_pos++];
            if (c == '\n') break;
            if (len + 2 > g_replay_cap) {
                size_t nc = g_replay_cap * 2;
                char *nb = realloc(g_replay_line, nc);
                if (!nb) return -1;
                g_replay_line = nb; g_replay_cap = nc;
            }
            g_replay_line[len++] = c;
        }
        g_replay_line[len] = '\0';
        return (int)len;
    }
    if (!g_replay_fp) return -1;
    if (g_replay_cap < 256) {
        g_replay_cap = 256;
        g_replay_line = realloc(g_replay_line, g_replay_cap);
        if (!g_replay_line) { g_replay_cap = 0; return -1; }
    }
    size_t len = 0;
    int c;
    while ((c = fgetc(g_replay_fp)) != EOF) {
        if (len + 2 > g_replay_cap) {
            size_t nc = g_replay_cap * 2;
            char *nb = realloc(g_replay_line, nc);
            if (!nb) return -1;
            g_replay_line = nb; g_replay_cap = nc;
        }
        if (c == '\n') break;
        g_replay_line[len++] = (char)c;
    }
    if (c == EOF && len == 0) return -1;
    g_replay_line[len] = '\0';
    return (int)len;
}

/* Un-escape a tape-format quoted string in place. Reads the byte stream
 * starting at `*p` (which must point one past the opening quote), writes
 * the decoded bytes to `out` (max `out_cap-1` plus NUL), advances `*p`
 * past the closing quote. Returns the decoded length on success, -1 on
 * malformed input. Handles \", \\, \n, \r, \xNN; everything else literal. */
static int unescape_string(const char **p, char *out, int out_cap) {
    int n = 0;
    const char *s = *p;
    while (*s && *s != '"') {
        if (n + 1 >= out_cap) return -1;
        if (*s == '\\') {
            s++;
            switch (*s) {
                case '"':  out[n++] = '"';  s++; break;
                case '\\': out[n++] = '\\'; s++; break;
                case 'n':  out[n++] = '\n'; s++; break;
                case 'r':  out[n++] = '\r'; s++; break;
                case 'x': {
                    s++;
                    int hi = -1, lo = -1;
                    if (s[0]) hi = (s[0] >= '0' && s[0] <= '9') ? s[0] - '0'
                                  : (s[0] >= 'a' && s[0] <= 'f') ? s[0] - 'a' + 10
                                  : (s[0] >= 'A' && s[0] <= 'F') ? s[0] - 'A' + 10 : -1;
                    if (hi >= 0 && s[1]) lo = (s[1] >= '0' && s[1] <= '9') ? s[1] - '0'
                                  : (s[1] >= 'a' && s[1] <= 'f') ? s[1] - 'a' + 10
                                  : (s[1] >= 'A' && s[1] <= 'F') ? s[1] - 'A' + 10 : -1;
                    if (hi < 0 || lo < 0) return -1;
                    out[n++] = (char)((hi << 4) | lo);
                    s += 2;
                    break;
                }
                default: return -1;
            }
        } else {
            out[n++] = *s++;
        }
    }
    if (*s != '"') return -1;
    *p = s + 1;
    out[n] = '\0';
    return n;
}

/* Parse one value from the tape encoding. Cursor-style: advances `*p`
 * past the parsed value. Returns a Value with +1 refcount on success.
 *
 * Recognized shapes:
 *   null | true | false              immediates
 *   <num>                            strtod-parseable
 *   "<str>"                          escapes per unescape_string
 *   [v, v, …]                        list
 *   b[num, num, …]                   buffer (the leading 'b' disambiguates
 *                                    from a list of bare numbers)
 *   {"k": v, …}                      dict
 *
 * Markers like <fn>, <heap>, <list:N>, …<truncated…> are NOT replayable;
 * the caller falls back to live source in that case. */
static void skip_ws(const char **p) { while (**p == ' ') (*p)++; }

static int at_token_boundary(char c) {
    return c == '\0' || c == ' ' || c == ',' || c == ']' || c == '}' || c == ':';
}

static Value *parse_value_p(const char **p) {
    skip_ws(p);
    char c = **p;
    if (c == '\0') return NULL;

    if (strncmp(*p, "null", 4) == 0 && at_token_boundary((*p)[4])) {
        *p += 4; return make_null();
    }
    if (strncmp(*p, "true", 4) == 0 && at_token_boundary((*p)[4])) {
        *p += 4; return make_num(1.0);
    }
    if (strncmp(*p, "false", 5) == 0 && at_token_boundary((*p)[5])) {
        *p += 5; return make_num(0.0);
    }

    if (c == '"') {
        const char *q = *p + 1;
        size_t cap = strlen(q) + 1;
        char *buf = malloc(cap);
        if (!buf) return NULL;
        int n = unescape_string(&q, buf, (int)cap);
        if (n < 0) { free(buf); return NULL; }
        Value *v = make_str(buf);
        free(buf);
        *p = q;
        return v;
    }

    if (c == 'b' && (*p)[1] == '[') {
        *p += 2;
        skip_ws(p);
        double *data = NULL;
        int count = 0, cap = 0;
        if (**p != ']') {
            for (;;) {
                skip_ws(p);
                char *end = NULL;
                double d = strtod(*p, &end);
                if (end == *p) { free(data); return NULL; }
                if (count >= cap) {
                    int nc = cap ? cap * 2 : 8;
                    double *nd = realloc(data, (size_t)nc * sizeof(double));
                    if (!nd) { free(data); return NULL; }
                    data = nd; cap = nc;
                }
                data[count++] = d;
                *p = end;
                skip_ws(p);
                if (**p == ',') { (*p)++; continue; }
                if (**p == ']') break;
                free(data); return NULL;
            }
        }
        (*p)++;
        Value *v = xcalloc(1, sizeof(Value));
        v->type = VAL_BUFFER;
        v->refcount = 1;
        v->data.buffer.count = count;
        v->data.buffer.data = xcalloc(count > 0 ? (size_t)count : 1, sizeof(double));
        if (count > 0) memcpy(v->data.buffer.data, data, (size_t)count * sizeof(double));
        free(data);
        return v;
    }

    if (c == '[') {
        (*p)++;
        skip_ws(p);
        Value *list = make_list(8);
        if (**p == ']') { (*p)++; return list; }
        for (;;) {
            Value *elem = parse_value_p(p);
            if (!elem) { val_decref(list); return NULL; }
            list_append(list, elem);
            val_decref(elem);
            skip_ws(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == ']') break;
            val_decref(list); return NULL;
        }
        (*p)++;
        return list;
    }

    if (c == '{') {
        (*p)++;
        skip_ws(p);
        Value *dict = make_dict(8);
        if (**p == '}') { (*p)++; return dict; }
        for (;;) {
            skip_ws(p);
            if (**p != '"') { val_decref(dict); return NULL; }
            const char *q = *p + 1;
            size_t kcap = strlen(q) + 1;
            char *kbuf = malloc(kcap);
            if (!kbuf) { val_decref(dict); return NULL; }
            int n = unescape_string(&q, kbuf, (int)kcap);
            if (n < 0) { free(kbuf); val_decref(dict); return NULL; }
            *p = q;
            skip_ws(p);
            if (**p != ':') { free(kbuf); val_decref(dict); return NULL; }
            (*p)++;
            Value *val = parse_value_p(p);
            if (!val) { free(kbuf); val_decref(dict); return NULL; }
            dict_set(dict, kbuf, val);
            val_decref(val);
            free(kbuf);
            skip_ws(p);
            if (**p == ',') { (*p)++; continue; }
            if (**p == '}') break;
            val_decref(dict); return NULL;
        }
        (*p)++;
        return dict;
    }

    /* <fn>, <heap>, <list:N>, <dict:N>, <buffer:N>, …<truncated…> —
     * not replayable. Caller falls back to live source. */
    if (c == '<' || (unsigned char)c == 0xE2) return NULL;

    char *end = NULL;
    double d = strtod(*p, &end);
    if (end == *p) return NULL;
    *p = end;
    return make_num(d);
}

static Value *parse_value(const char *s) {
    const char *p = s;
    skip_ws(&p);
    Value *v = parse_value_p(&p);
    if (!v) return NULL;
    skip_ws(&p);
    if (*p != '\0') { val_decref(v); return NULL; }
    return v;
}

int trace_replay_take(const char *fn, Value **out) {
    if ((!g_replay_fp && !g_replay_mem) || !out) return 0;
    for (;;) {
        int len = read_tape_line();
        if (len < 0) {
            /* Tape exhausted — turn off replay so future calls skip the
             * read overhead, and let the builtin run normally. */
            replay_shutdown();
            return 0;
        }
        if (len < 2 || g_replay_line[0] != 'N' || g_replay_line[1] != ' ')
            continue;  /* skip L, A, blanks, anything else */

        char *p = g_replay_line + 2;
        char *eq = strchr(p, '=');
        if (!eq) continue;
        *eq = '\0';
        const char *rec_name = p;
        const char *rec_val  = eq + 1;

        if (fn && strcmp(rec_name, fn) != 0) {
            if (g_replay_strict) {
                fprintf(stderr, "trace: replay name mismatch — tape has '%s', "
                        "program called '%s' (EIGS_REPLAY_STRICT — aborting)\n",
                        rec_name, fn);
                /* _exit, not exit: an abort must not run atexit teardown
                 * (half-executed program state) and keeps the status
                 * deterministic under sanitizers, whose leak checker
                 * would otherwise override the code at forced exits.
                 * Freestanding has no _exit; abort() is a HAL root
                 * (halt) and a strict mismatch on bare metal is a
                 * panic by any name. */
#if EIGENSCRIPT_FREESTANDING
                abort();
#else
                _exit(3);
#endif
            }
            fprintf(stderr, "trace: replay name mismatch — expected '%s', got '%s' (using anyway)\n",
                    fn, rec_name);
        }
        Value *v = parse_value(rec_val);
        if (!v) return 0;   /* unparseable — fall through to live source */
        *out = v;
        return 1;
    }
}

void trace_shutdown(void) {
#if !EIGENSCRIPT_FREESTANDING
    if (g_trace_fp) {
        fflush(g_trace_fp);
        fclose(g_trace_fp);
        g_trace_fp = NULL;
    }
#endif
    sink_flush();
    g_trace_sink = NULL;
    g_trace_sink_ud = NULL;
    g_trace_enabled = 0;

    if (g_prev_tab) {
        for (int i = 0; i < g_prev_cap; i++) {
            PrevEntry *e = &g_prev_tab[i];
            if (!e->name) continue;
            if (e->has_prev)    slot_decref(e->prev);
            if (e->has_current) slot_decref(e->current);
            for (int j = 0; j < e->hist_count; j++)
                slot_decref(e->history[j].value);
            free(e->history);
            free(e->seg_min);
            free(e->obs);
        }
        free(g_prev_tab);
        g_prev_tab = NULL;
        g_prev_cap = 0;
        g_prev_count = 0;
    }

    replay_shutdown();
}

void trace_line(int line) {
    /* OP_LINE stores g_trace_current_line directly; this function is
     * only called when a tape is open (g_trace_enabled). */
    if (!trace_out_active()) return;
    if (line == g_last_line && !g_line_dirty) return;
    tp_printf("L %d\n", line);
    g_last_line  = line;
    g_line_dirty = 0;
}

/* Strings get quoted + truncated. \, ", \n, \r escaped so the tape is
 * one event per text line. Truncation marker is a trailing '…' (UTF-8
 * ellipsis) inside the closing quote. */
static void write_string(const char *s) {
    if (!s) { tp_puts("\"\""); return; }
    tp_putc('"');
    int written = 0;
    for (const char *p = s; *p && written < TRACE_STR_MAX; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"' || c == '\\') { tp_putc('\\'); tp_putc(c); written += 2; }
        else if (c == '\n')        { tp_puts("\\n"); written += 2; }
        else if (c == '\r')        { tp_puts("\\r"); written += 2; }
        else                       { tp_putc(c);    written += 1; }
    }
    if ((int)strlen(s) > TRACE_STR_MAX) tp_puts("…");
    tp_putc('"');
}

/* Format a heap or tracked Value*. Numeric heap values unwrap to their
 * number; collections show their size for at-a-glance scanning. */
static void write_value_ptr(Value *v) {
    if (!v) { tp_puts("null"); return; }
    switch (v->type) {
        case VAL_NUM:          tp_printf("%.17g", v->data.num); break;
        case VAL_NULL:         tp_puts("null"); break;
        case VAL_STR:          write_string(v->data.str); break;
        case VAL_LIST:         tp_printf("<list:%d>", v->data.list.count); break;
        case VAL_DICT:         tp_printf("<dict:%d>", v->data.dict.count); break;
        case VAL_FN:           tp_puts("<fn>"); break;
        case VAL_BUILTIN:      tp_puts("<builtin>"); break;
        case VAL_BUFFER:       tp_printf("<buffer:%d>", v->data.buffer.count); break;
        case VAL_JSON_RAW:     tp_puts("<json>"); break;
        case VAL_TEXT_BUILDER: tp_puts("<text>"); break;
        default:               tp_puts("<heap>"); break;
    }
}

static void write_slot(EigsSlot s) {
    if (slot_is_num(s))  { tp_printf("%.17g", s.d); return; }
    if (slot_is_null(s)) { tp_puts("null"); return; }
    if (slot_is_bool(s)) { tp_puts(slot_as_bool(s) ? "true" : "false"); return; }
    if (slot_is_heap(s)) { write_value_ptr(slot_as_ptr(s)); return; }
    tp_puts("<unknown>");
}

void trace_assign(const char *name, EigsSlot value) {
    /* Prev-map update runs regardless of EIGS_TRACE — `prev of x` is a
     * language feature, not a tape feature. The tape write below is
     * still gated on a tape (file or sink) being open. */
    prev_record_assign(name, value);

    if (!trace_out_active()) return;
    if (!name) name = "?";
    tp_puts("A ");
    tp_puts(name);
    tp_putc('=');
    write_slot(value);
    tp_putc('\n');
    g_line_dirty = 1;
}

/* ----- Full-fidelity writer for nondet records.
 *
 * Recursive emission of lists/dicts; full string content; cap the whole
 * record at TRACE_NONDET_MAX bytes. The `budget` is decremented on every
 * byte written. When budget runs out, the rest of the record collapses
 * to a single "…<truncated:RESIDUAL>" marker so Phase 3 replay knows the
 * record cannot be used for full determinism. */

static void wf_putc(int c, int *budget) {
    if (*budget <= 0 || !trace_out_active()) return;
    tp_putc(c); (*budget)--;
}
static void wf_puts(const char *s, int *budget) {
    if (!trace_out_active()) return;
    while (*s && *budget > 0) { tp_putc(*s++); (*budget)--; }
}
static void wf_printf(int *budget, const char *fmt, ...) {
    if (*budget <= 0 || !trace_out_active()) return;
    char buf[64];
    va_list ap; va_start(ap, fmt);
    int n = vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if (n >= (int)sizeof(buf)) n = (int)sizeof(buf) - 1;
    if (n > *budget) n = *budget;
    tp_write(buf, (size_t)n);
    *budget -= n;
}

static void write_string_full(const char *s, int *budget) {
    wf_putc('"', budget);
    if (s) {
        for (const char *p = s; *p && *budget > 0; p++) {
            unsigned char c = (unsigned char)*p;
            if (c == '"' || c == '\\') { wf_putc('\\', budget); wf_putc(c, budget); }
            else if (c == '\n')        { wf_puts("\\n", budget); }
            else if (c == '\r')        { wf_puts("\\r", budget); }
            else if (c < 0x20)         { wf_printf(budget, "\\x%02x", c); }
            else                       { wf_putc(c, budget); }
        }
    }
    wf_putc('"', budget);
}

static void write_value_ptr_full(Value *v, int *budget) {
    if (*budget <= 0) return;
    if (!v) { wf_puts("null", budget); return; }
    switch (v->type) {
        case VAL_NUM:  wf_printf(budget, "%.17g", v->data.num); break;
        case VAL_NULL: wf_puts("null", budget); break;
        case VAL_STR:  write_string_full(v->data.str, budget); break;
        case VAL_LIST: {
            wf_putc('[', budget);
            int n = v->data.list.count;
            for (int i = 0; i < n && *budget > 0; i++) {
                if (i) wf_puts(", ", budget);
                write_value_ptr_full(v->data.list.items[i], budget);
            }
            wf_putc(']', budget);
            break;
        }
        case VAL_DICT: {
            wf_putc('{', budget);
            int n = v->data.dict.count;
            for (int i = 0; i < n && *budget > 0; i++) {
                if (i) wf_puts(", ", budget);
                write_string_full(v->data.dict.keys[i], budget);
                wf_puts(": ", budget);
                write_value_ptr_full(v->data.dict.vals[i], budget);
            }
            wf_putc('}', budget);
            break;
        }
        case VAL_BUFFER: {
            /* Leading 'b' disambiguates from VAL_LIST: both serialize the
             * bracketed numeric body, but only buffers are restored as
             * VAL_BUFFER on replay. */
            wf_putc('b', budget);
            wf_putc('[', budget);
            int n = v->data.buffer.count;
            for (int i = 0; i < n && *budget > 0; i++) {
                if (i) wf_puts(", ", budget);
                wf_printf(budget, "%.17g", v->data.buffer.data[i]);
            }
            wf_putc(']', budget);
            break;
        }
        case VAL_FN:       wf_puts("<fn>", budget); break;
        case VAL_BUILTIN:  wf_puts("<builtin>", budget); break;
        default:           wf_puts("<heap>", budget); break;
    }
}

void trace_nondet_value(const char *fn, Value *v) {
    if (!trace_out_active()) return;
    if (!fn) fn = "?";
    tp_puts("N ");
    tp_puts(fn);
    tp_putc('=');
    int budget = TRACE_NONDET_MAX;
    write_value_ptr_full(v, &budget);
    if (budget <= 0) tp_puts("…<truncated>");
    tp_putc('\n');
    g_line_dirty = 1;
}
