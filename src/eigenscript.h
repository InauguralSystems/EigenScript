/*
 * EigenScript Language Runtime — public header.
 * Core types, parser, evaluator, value constructors, arena allocator.
 * Extension types live in private headers (model_internal.h, ext_http_internal.h, ext_db_internal.h).
 */

#ifndef EIGENSCRIPT_H
#define EIGENSCRIPT_H

/* Extension flags — set to 0 to compile a minimal language-only binary.
 * Override at compile time: gcc -DEIGENSCRIPT_EXT_HTTP=0 ... */
#ifndef EIGENSCRIPT_EXT_HTTP
#define EIGENSCRIPT_EXT_HTTP 1
#endif
#ifndef EIGENSCRIPT_EXT_MODEL
#define EIGENSCRIPT_EXT_MODEL 1
#endif
#ifndef EIGENSCRIPT_EXT_DB
#define EIGENSCRIPT_EXT_DB 1
#endif
#ifndef EIGENSCRIPT_EXT_AUTH
#define EIGENSCRIPT_EXT_AUTH 1
#endif
#ifndef EIGENSCRIPT_EXT_GFX
#define EIGENSCRIPT_EXT_GFX 0
#endif

/* Freestanding profile (docs/FREESTANDING.md) — the no-libc/EigenOS
 * carve-out. Compiles out everything that needs a host OS beyond the
 * HAL roots + mini-libc/libm allowlist (tools/freestanding_allowlist.txt):
 * filesystem builtins (incl. load_file/import), subprocess, terminal raw
 * mode, libc regex (route to EigenRegex's regex_compat), the trace-tape
 * file sinks, and the JIT (interpreter-only; exec pages are a deferred
 * HAL root). Gated in CI by tools/freestanding_check.sh. The entry point
 * is eigs_embed.h, not main.c. */
#ifndef EIGENSCRIPT_FREESTANDING
#define EIGENSCRIPT_FREESTANDING 0
#endif

/* The JIT is x86-64-only and compiled out of the freestanding profile
 * (executable pages are a deferred HAL root). All arch gates in jit.c /
 * vm.c go through this so the two conditions can't drift. */
#if defined(__x86_64__) && !EIGENSCRIPT_FREESTANDING
#define EIGS_JIT_ENABLED 1
#else
#define EIGS_JIT_ENABLED 0
#endif

/* EIGS_POISON (`make poison`): fill memory the allocator stack hands out
 * fresh or parks dirty with 0xAA instead of leaving it zero/stale. Hosted
 * glibc hands back zero pages, so an uninitialized read is a benign 0 here
 * but wild garbage on a non-glibc substrate (the EigenOS freestanding port)
 * — a layout-sensitive heisenbug class the sanitizer gates can't see (MSan
 * is deferred). Poison makes the read deterministic on every layout, so the
 * hosted suite names it. Sites: xmalloc fresh blocks, xrealloc grown tails,
 * and the env freelist's parked dormant arrays (names/values/assign_counts
 * + hash.hashes/indices — reuse deliberately does not clear them; the
 * generation gate itself is NOT poisoned). arena_alloc, xcalloc and the num
 * freelist zero-fill by documented contract and stay untouched. Pairs with
 * MALLOC_PERTURB_ (raw malloc/realloc sites) at suite time. Zero cost off. */
#ifdef EIGS_POISON
#define EIGS_POISON_BYTE 0xAA
#define EIGS_POISON_MEM(p, n) memset((p), EIGS_POISON_BYTE, (n))
#else
#define EIGS_POISON_MEM(p, n) ((void)0)
#endif

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <stdint.h>
#include <limits.h>
#include <setjmp.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <dirent.h>
#include <pthread.h>   /* EigsState carries the per-state lock — see below */
#include <fcntl.h>
#include <time.h>
#include <poll.h>
#include <regex.h>

/* ---- Language limits ---- */

#define MAX_TOKENS      65536
#define MAX_INDENT      64
#define MAX_VARS        512   /* lint-only; Env uses dynamic arrays */
#define ENV_INIT_CAP    16
/* The loop machinery binds two implicit names into the *function* env at
 * runtime (__loop_iterations__, __loop_exit__ — vm.c) that local_count does
 * not account for. env_reserve_slots reserves this much extra CAPACITY (not
 * count) so a loop in a body whose local_count sits exactly at a power-of-two
 * boundary can't realloc env->values mid-execution. That realloc frees the
 * array the JIT's %r12 (fn_env->values) cache points at — a use-after-free the
 * re-entrant sandbox_run/vm_execute churn turns into "cannot index num" (#291). */
#define ENV_LOOP_BIND_HEADROOM 2
#define MAX_LIST        1024
#define MAX_PARAMS      16
#define MAX_MATCH_CASES 64

/* ---- Tokenizer ---- */

typedef enum {
    TOK_NUM, TOK_STR, TOK_IDENT,
    TOK_IS, TOK_OF, TOK_DEFINE, TOK_AS,
    TOK_IF, TOK_ELSE, TOK_ELIF, TOK_LOOP, TOK_WHILE,
    TOK_RETURN, TOK_AND, TOK_OR, TOK_NOT,
    TOK_FOR, TOK_IN, TOK_NULL,
    TOK_WHAT, TOK_WHO, TOK_WHEN, TOK_WHERE, TOK_WHY, TOK_HOW,
    TOK_PREV, TOK_AT,
    TOK_CONVERGED, TOK_STABLE, TOK_IMPROVING, TOK_OSCILLATING, TOK_DIVERGING, TOK_EQUILIBRIUM,
    TOK_TRY, TOK_CATCH, TOK_BREAK, TOK_CONTINUE, TOK_IMPORT,
    TOK_MATCH, TOK_CASE,
    TOK_UNOBSERVED,
    TOK_LOCAL,
    TOK_PLUS, TOK_MINUS, TOK_STAR, TOK_SLASH, TOK_PERCENT,
    TOK_LT, TOK_GT, TOK_LE, TOK_GE, TOK_EQ, TOK_NE, TOK_ASSIGN,
    TOK_LPAREN, TOK_RPAREN, TOK_LBRACKET, TOK_RBRACKET,
    TOK_COMMA, TOK_COLON, TOK_DOT,
    TOK_LBRACE, TOK_RBRACE,
    TOK_PIPE, TOK_ARROW,
    TOK_AMP, TOK_BITOR, TOK_CARET, TOK_SHL, TOK_SHR, TOK_TILDE,
    TOK_PLUS_EQ, TOK_MINUS_EQ, TOK_STAR_EQ, TOK_SLASH_EQ, TOK_PERCENT_EQ,
    TOK_AMP_EQ, TOK_BITOR_EQ, TOK_CARET_EQ, TOK_SHL_EQ, TOK_SHR_EQ,
    TOK_NEWLINE, TOK_INDENT, TOK_DEDENT,
    TOK_EOF
} TokType;

typedef struct {
    TokType type;
    double num_val;
    char *str_val;
    int line;
    int col;    /* 0-based column offset */
    int len;    /* source lexeme length (for spans: semantic tokens, hover) */
} Token;

typedef struct {
    Token *tokens;
    int count;
    int capacity;
} TokenList;

/* ---- AST ---- */

typedef enum {
    AST_NUM, AST_STR, AST_IDENT, AST_NULL,
    AST_BINOP, AST_UNARY, AST_ASSIGN, AST_RELATION,
    AST_IF, AST_LOOP, AST_FUNC, AST_RETURN,
    AST_BLOCK, AST_LIST, AST_INDEX, AST_LISTCOMP, AST_FOR,
    AST_PROGRAM,
    AST_INTERROGATE, AST_PREDICATE,
    AST_TRY, AST_DICT, AST_DOT, AST_BREAK, AST_CONTINUE, AST_DOT_ASSIGN, AST_IMPORT,
    AST_MATCH, AST_LAMBDA, AST_UNOBSERVED, AST_INDEX_ASSIGN, AST_LIST_PATTERN_ASSIGN,
    AST_SLICE
} ASTType;

typedef struct ASTNode ASTNode;
typedef struct Env Env;

struct ASTNode {
    ASTType type;
    int line;
    int col;    /* 0-based column offset */
    uint32_t name_hash; /* cached hash for identifier/name-bearing nodes */
    uint8_t parenthesized; /* expression was written as ( expr ) — a
                            * parenthesized literal list is a single call
                            * argument, never spread (#355) */
    union {
        double num;
        char *str;
        struct { char *name; } ident;
        struct { char op[4]; ASTNode *left; ASTNode *right; } binop;
        struct { char op[4]; ASTNode *operand; } unary;
        struct { char *name; ASTNode *expr; int local_only; } assign;
        struct { ASTNode *left; ASTNode *right; } relation;
        struct { ASTNode *cond; ASTNode **if_body; int if_count; ASTNode **else_body; int else_count; } cond;
        struct { ASTNode *cond; ASTNode **body; int body_count; } loop;
        struct { char *name; char **params; ASTNode **param_defaults; int param_count; int first_default; ASTNode **body; int body_count; } func;
        struct { ASTNode *expr; } ret;
        struct { ASTNode **stmts; int count; } block;
        struct { ASTNode **elems; int count; } list;
        struct { ASTNode *target; ASTNode *index; } index;
        struct { ASTNode *expr; char *var; ASTNode *iter; ASTNode *filter; } listcomp;
        struct { char *var; ASTNode *iter; ASTNode **body; int body_count; } forloop;
        struct { ASTNode **stmts; int count; } program;
        struct { int kind; ASTNode *expr; ASTNode *at_expr; } interrogate;
        struct { int kind; } predicate;
        struct { ASTNode **try_body; int try_count; char *err_name; ASTNode **catch_body; int catch_count; } trycatch;
        struct { ASTNode **keys; ASTNode **vals; int count; } dict;
        struct { ASTNode *target; char *key; } dot;
        struct { ASTNode *target; char *key; ASTNode *expr; } dot_assign;
        struct { ASTNode *target; ASTNode *index; ASTNode *expr; char compound_op[4]; } index_assign;
        struct { char *module_name; } import;
        struct { ASTNode *expr; ASTNode **patterns; ASTNode ***bodies; int *body_counts; int case_count; } match;
        struct { char **params; int param_count; ASTNode *body; } lambda;
        struct { char **names; uint32_t *name_hashes; int name_count; ASTNode *expr; } list_pattern_assign;
        struct { ASTNode *target; ASTNode *start; ASTNode *end; } slice; /* start/end NULL = omitted */
    } data;
};

/* ---- Value types ---- */

typedef enum {
    VAL_NUM, VAL_STR, VAL_LIST, VAL_FN, VAL_BUILTIN, VAL_NULL, VAL_JSON_RAW, VAL_DICT, VAL_BUFFER, VAL_TEXT_BUILDER
} ValType;

typedef struct Value Value;
typedef Value* (*BuiltinFn)(Value* arg);

/* EigsSlot union — full inline helpers in value_slot.h, which is
 * included below after the Value struct is fully declared. We need the
 * raw union here because Env::values is EigsSlot*. */
#ifndef EIGENSCRIPT_EIGSSLOT_UNION_DEFINED
#define EIGENSCRIPT_EIGSSLOT_UNION_DEFINED
typedef union { double d; uint64_t u; } EigsSlot;
#endif

/* Hash index for O(1) variable lookup.  Sits alongside the linear
 * names/values arrays so iteration order and env_decref are unchanged. */
#define ENV_HASH_INIT_CAP 32  /* must be power of 2 */

typedef struct {
    uint32_t *hashes;       /* hash of name */
    int      *indices;      /* index into Env::names/values, or -1 */
    uint32_t *generations;  /* per-slot generation marker */
    int       mask;         /* capacity - 1 (for & masking) */
    uint32_t  generation;   /* current generation; slot is occupied iff generations[i] == this */
} EnvHash;

/* #262: slot-keyed observer state — the ONLY observer model. Keyed to a
 * variable BINDING (env + slot index), not the recyclable Value object, so
 * aliasing/temp-built iterates track their own trajectory. The per-Value
 * observer fields were removed in Step E. See issue #262. */
typedef struct ObserverSlot {
    double  entropy, last_entropy, dH, prev_dH;
    int     obs_age;
    double *dh_window;          /* lazily allocated, OBSERVER_WINDOW_N doubles */
    uint8_t dh_window_head, dh_window_count;
    uint8_t used;               /* 1 once this slot has been observed */
    /* #294 value-signal channel: the entropy window above tracks
     * entropy(value) — a lossy proxy that goes flat in mid-magnitude regions
     * (so a real value-oscillation reads "stable"). This parallel window tracks
     * the value's OWN relative step Δv/(1+|v|), so `report_value of x`
     * classifies the value trajectory directly. Same windowed logic/thresholds
     * as the entropy channel; only the observed signal differs. */
    double  last_value;         /* last observed numeric value (Δv source) */
    double *v_window;           /* lazily allocated, OBSERVER_WINDOW_N relative-deltas */
    uint8_t v_window_head, v_window_count;
    uint8_t v_used;             /* 1 once a numeric value has been recorded */
} ObserverSlot;

struct Env {
    char **names;
    EigsSlot *values;   /* slot-typed bindings (immediates live in-place) */
    int *assign_counts; /* per-slot assignment counter for 'when is' */
    int count;
    int capacity;
    Env *parent;        /* lexical parent; an OWNED reference (env_incref'd
                         * by env_new, dropped by env_decref's destructor) */
    int heap_allocated;
    int captured;
    int env_refcount;   /* honest owner count: creator/frame + closures
                         * (make_fn) + child envs (parent link) + a chunk's
                         * parked env_cache. 0 -> destroyed. */
    uint32_t binding_version; /* bumped on every new-binding add or env recycle;
                               * used by VM inline caches to detect shadowing */
    /* Cycle-collector registry of captured envs (intrusive list; see
     * gc_collect_cycles in eigenscript.c and docs/CLOSURE_CYCLE_GC.md). */
    Env *gc_next;
    Env *gc_prev;
    unsigned char in_gc_list;
    EnvHash hash;
    /* #262 Phase-1: self-managed slot-keyed observer array (own capacity,
     * grown in observer_slot_update; freed/reset at env teardown/park). NULL
     * until the first shadow observation under EIGS_OBS_SHADOW. */
    struct ObserverSlot *obs;
    int obs_cap;
};

struct Value {
    ValType type;
    union {
        double num;
        char *str;
        struct { Value **items; int count; int capacity; } list;
        struct { char *name; char **params; uint32_t *param_hashes; int param_count; ASTNode **body; int body_count; Env *closure; } fn;
        BuiltinFn builtin;
        struct { char **keys; Value **vals; int count; int capacity; EnvHash hash; } dict;
        struct { double *data; int count; int rows, cols; } buffer;  /* rows==0 => unshaped 1-D (count is length); rows>0 => 2-D, rows*cols==count */
        struct { char *data; size_t len; size_t cap; int parts; } text_builder;
    } data;
    /* #262 Step E: observer state (entropy/dH/window/obs_age/dirty) lived here
     * in the value-path model; it now lives only on the per-binding Env slot
     * (ObserverSlot). The Value carries no observer state. */
    int refcount;       /* reference counting GC: 0 = unmanaged, >0 = tracked */
    unsigned char arena; /* 1 if arena-allocated (don't free) */
    /* #307: Bacon-Rajan "possible root" flag. Set when a LIST/DICT that lost a
     * ref (but isn't dead) is parked on the value-candidate buffer for the next
     * cycle collection; cleared when the buffer is drained. Lives in the
     * struct's tail padding (no size change) and is zero-initialized by every
     * Value allocator (xcalloc / arena_alloc memset / freelist reuse memset). */
    unsigned char gc_buffered;
};

/* Window length for the per-Value dH ring buffer. Predicates require
 * a full window (count == OBSERVER_WINDOW_N) for "converged"-class
 * checks and a partial window (count >= 3) for trend-class checks. */
#define OBSERVER_WINDOW_N 10

/* Returns the current fill of v's dH window (0..OBSERVER_WINDOW_N). */
size_t observer_window_size(const Value *v);

/* #262 Phase-1 prototype slot-keyed observer API (behind EIGS_OBS_SHADOW). */
void observer_slot_update(struct Env *e, int idx, Value *newval);
/* #262 Phase-3 D: slot update from a raw immediate number (no Value needed). */
void observer_slot_update_num(struct Env *e, int idx, double num);
void observer_slot_reset(struct Env *e);
/* Observed-loop halting on an explicit env (no VM-frame dependency): one
 * iteration of OP_LOOP_STALL_CHECK / OP_LOOP_CAP_CHECK. Returns 1 when the loop
 * should exit (observer stalled 100 iters, or the absolute cap). Lets the AOT
 * run the same halting as the interpreter/JIT. (vm.c) */
int eigs_loop_stall_step(struct Env *e);
int eigs_loop_cap_step(struct Env *e);
/* Implemented in vm.c: drops the last-observed-slot tracker if it points at e
 * (called from observer_slot_reset so a torn-down env can't be read stale). */
void vm_obs_slot_dropped(struct Env *e);
int  observer_slot_converged(const struct ObserverSlot *s);
int  observer_slot_equilibrium(const struct ObserverSlot *s);
int  observer_slot_improving(const struct ObserverSlot *s);
int  observer_slot_diverging(const struct ObserverSlot *s);
int  observer_slot_oscillating(const struct ObserverSlot *s);
int  observer_slot_stable(const struct ObserverSlot *s);
/* Classify a slot into a report band (mirrors builtin_report's priority).
 * Returns a static string; NULL if the slot is unusable. */
const char *observer_slot_report(const struct ObserverSlot *s);
/* #294 value-signal report: classify the binding's VALUE trajectory (not its
 * entropy) — "oscillating"/"converged"/"stable"/"moving"/"equilibrium". */
const char *observer_slot_report_value(const struct ObserverSlot *s);

/* Returns the dH at offset back from most recent (0 = most recent).
 * Caller must ensure offset < observer_window_size(v). */
double observer_window_get(const Value *v, size_t offset_back);

/* Windowed `improving` predicate (#207): NET entropy descent (sum<0) over the
 * window AND a sustained majority (>=60%) of genuine descent steps (dH <
 * -dh_small, honoring the #187 gray band). Shared by vm.c and builtins.c. */
int observer_improving(const Value *v);

/* Windowed `diverging` predicate (#208): mirror of observer_improving — NET
 * entropy ascent (sum>0) AND >=60% genuine ascent steps (dH > +dh_small).
 * Shared by vm.c and builtins.c. */
int observer_diverging(const Value *v);

/* Windowed `oscillating` predicate (#206): >= ceil(N/3) = 4 dH sign flips
 * across the window, each flip's two samples clearing dh_zero (deadband
 * escape, stays on dh_zero per #187). Shared by vm.c and builtins.c. */
int observer_oscillating(const Value *v);

/* Windowed `equilibrium` predicate (#209): full window (count==N), zero-mean
 * (|mean|<dh_zero) and low variance (<dh_zero^2). Shared by vm.c and builtins.c. */
int observer_equilibrium(const Value *v);

/* Windowed `stable` predicate (#205): full window, every |dH|<dh_small, entropy
 * >= h_low, and no consecutive sign flips (both clearing dh_zero). Shared by
 * vm.c and builtins.c. */
int observer_stable(const Value *v);

/* ---- Arena allocator ---- */

#define ARENA_BLOCK_SIZE (16 * 1024 * 1024)
#define ARENA_MAX_BLOCKS 64

typedef struct {
    char *blocks[ARENA_MAX_BLOCKS];
    int block_count;
    int current_block;
    size_t offset;
    int mark_block;
    size_t mark_offset;
    int active;
    size_t total_allocated;
    char **strings;
    int string_count;
    int string_capacity;
    int mark_string_count;
    char **fallbacks;       /* heap allocations from arena overflow */
    int fallback_count;
    int fallback_capacity;
    int mark_fallback_count;
} Arena;

/* ---- Per-thread execution context ---------------------------------
 *
 * EigsThread carries every datum that used to be a __thread global so
 * the runtime can host multiple interpreter states side by side. Set
 * up by eigs_thread_attach (state.h), reachable as `eigs_current` on
 * any OS thread that has entered a state.
 *
 * Hot fields live up front so the compiler can fold the indirection
 * into a single `[fs:TLS + offset]` addressing mode — same cost as
 * the legacy direct __thread access. Identifiers used everywhere in
 * the runtime (g_arena, g_returning, ...) are macros that expand to
 * `eigs_current->field`.
 *
 * The struct is fully transparent to internal TUs; the public
 * embedding API (Phase 10, embed.h) will expose it through accessor
 * functions only, so the field layout can still evolve. */
typedef struct EigsState  EigsState;
typedef struct EigsThread EigsThread;
struct VM;
struct EigsJitCache;
struct EigsChunk;
/* Defined in ext_http_internal.h when EIGENSCRIPT_EXT_HTTP is built;
 * forward-decl here so EigsState can carry an opaque pointer without
 * the header (eigenscript.h is included by everything). */
struct EigsHttpServer;

/* Opaque-pointer handle table — one row per outstanding Store/Thread/
 * Channel resource. Sized per-state; index 0 reserved as invalid. */
#define HANDLE_TABLE_SIZE 256

typedef enum {
    HANDLE_STORE,
    HANDLE_THREAD,
    HANDLE_CHANNEL
} HandleType;

typedef struct {
    void      *ptr;
    HandleType type;
} EigsHandleSlot;

/* Import-time module cache entry (Phase 0a of the package design).
 * Keyed on absolute resolved path; dict + env are counted refs. */
typedef struct {
    char  *path;
    Value *dict;
    Env   *env;
} EigsModuleCacheEntry;

/* Per-thread freelist + intern table sizing — surfaced here so EigsThread
 * can carry the storage inline and so state.c can drain at detach.
 * (Phase 8: these moved off file-static __thread storage in eigenscript.c.) */
#define NUM_FREELIST_CAP          4096
#define ENV_FREELIST_CAP          1024
#define ENV_FREELIST_MAX_BINDINGS 64
#define ENV_NAME_INTERN_BUCKETS   4096

typedef struct EnvNameIntern {
    char                 *name;
    uint32_t              hash;
    struct EnvNameIntern *next;
} EnvNameIntern;

/* Per-interpreter-instance config + shared registry. Transparent for
 * internal TUs (Phase 10's embed.h wraps it behind accessors). */
struct EigsState {
    pthread_mutex_t threads_lock;
    EigsThread     *threads;
    /* Observer-classification thresholds (set_observer_threshold builtin).
     * Per-state because they're interpreter configuration, not execution
     * state; one knob per host application, shared across worker threads. */
    double          obs_dh_zero;    /* |dH| < this → "zero change"  (default 0.001) */
    double          obs_dh_small;   /* |dH| < this → "small change" (default 0.01)  */
    double          obs_h_low;      /* entropy < this → "low info"  (default 0.1)   */
    /* Global lexical scope for the script + REPL line bodies + sourced
     * modules (load_file). Owned by main/eigenlsp; set after env_new. */
    Env            *global_env;
    /* Filesystem anchors for `import` / `load_file` resolution. */
    char            script_dir[4096];
    char            exe_dir[4096];
    /* Import-time module cache — populated on first import of a path,
     * read on subsequent imports of the same path. Single-writer in
     * practice (main thread imports at startup); no internal lock. */
    EigsModuleCacheEntry *module_cache;
    size_t          module_cache_count;
    size_t          module_cache_cap;
    /* Opaque-pointer handle table (Store/Thread/Channel ids). Locked
     * via handle_mutex since spawn workers can release handles too. */
    EigsHandleSlot  handle_table[HANDLE_TABLE_SIZE];
    pthread_mutex_t handle_mutex;
    int             handle_next;
    /* Set to 1 by builtin_spawn before pthread_create; stays 1 for the
     * state's lifetime. Gates the LOCK-prefixed __atomic_* RMW in
     * val_incref / val_decref / chunk_incref / chunk_decref /
     * env_incref / env_decref / slot_incref / slot_decref. Single-
     * threaded states (the common case — DMG, MiniSat, Tidepool, REPL)
     * keep it at 0 and skip the atomic ~20-cycle penalty on x86. */
    int             multithreaded;
    /* Cycle-collector registry — the intrusive list of captured envs and its
     * live count. Per-STATE (not per-thread) so candidates created on any
     * thread survive that thread's death and stay collectable at exit; gc_lock
     * guards list maintenance and is taken only while `multithreaded` (single-
     * threaded states pay nothing). Collection runs only when single-threaded
     * (gc_collect_impl bails under MT), so it needs no lock. */
    Env            *gc_envs;
    int             gc_captured_live;
    pthread_mutex_t gc_lock;
    /* #307: value-candidate buffer — LIST/DICT "possible roots" parked by
     * gc_note_possible_root for the next collection (Bacon-Rajan). Per-STATE
     * like the env registry, but only ever touched single-threaded (the hook
     * is gated off under MT), so it needs no lock. The buffer holds one pin
     * apiece; gc_collect_cycles feeds it in as seeds, then drains the pins. */
    Value         **gc_val_buf;
    int             gc_val_count;
    int             gc_val_cap;
    /* JIT tuning thresholds (entry / per-iter / OSR). Each state
     * reads its own copy from EIGS_JIT_ENTRY_THRESHOLD /
     * EIGS_JIT_ITER_THRESHOLD / EIGS_JIT_OSR_THRESHOLD at state_new,
     * so two co-located embedded states can tune independently. */
    int             jit_entry_threshold;
    int             jit_iter_threshold;
    int             jit_osr_threshold;
    /* ext_http per-interpreter server config (routes, static prefix,
     * CORS, early-bind fd). Allocated by register_http_builtins on
     * first registration; freed by ext_http_state_destroy at state
     * teardown. NULL when EXT_HTTP isn't built or registration hasn't
     * run yet. Carried as an opaque pointer so eigenscript.h stays
     * independent of the ext_http internal layout. */
    struct EigsHttpServer *ext_http_server;
};

struct EigsThread {
    EigsState  *state;
    Arena       arena;
    /* Control-flow propagation (return/break/continue out of nested
     * blocks). All three are checked + cleared by the interpreter
     * walk and the VM dispatch loop. */
    struct Value *return_val;
    int          returning;
    int          breaking;
    int          continuing;
    /* Error reporting / try-catch. */
    int          parse_errors;
    int          has_error;
    int          try_depth;
    int          first_error_line;
    int          first_error_col;   /* 0-based column of the first error, or 0 */
    char         error_msg[4096];
    char         first_error_msg[256];
    struct Value *error_value;      /* thrown payload for structured catch */
    /* Observer execution state — current observer and "unobserved {}"
     * scope depth (incremented on entry, decremented on exit; non-zero
     * suppresses assign-count bumps so observer interrogatives don't
     * count instrumentation traffic). */
    /* #262 Phase-2: last observed binding as (env, slot) for slot-keyed
     * observer reads. Per-thread, parallel to last_observer. idx < 0 = none.
     * Behind EIGS_OBS_SHADOW. */
    struct Env   *last_obs_slot_env;
    int           last_obs_slot_idx;
    int           unobserved_depth;
    /* Dynamic caller scope for env-aware builtins (env_get/env_set
     * polymorphic dispatch needs to know "who called me"). */
    struct Env   *builtin_call_env;
    /* Phase 5: VM execution state. Heap-allocated (the VM struct is
     * ~1MB — stack + frames). Allocated lazily in vm_init on first
     * vm_execute; freed in eigs_thread_detach. */
    struct VM           *vm;
    /* Loop-stall accounting (scoped per call frame via CallFrame.saved_*). */
    int                  loop_stall_count;
    int                  loop_iterations;
    const char          *loop_exit_reason;
    /* Per-thread JIT state — chunk → thunk cache, chunk hotness
     * registry, and stop-opcode diagnostics. Lazily initialized;
     * cache + chunks array freed in eigs_thread_detach. */
    struct EigsJitCache *jit_cache;
    struct EigsChunk   **jit_chunks;
    int                  jit_chunks_count;
    int                  jit_chunks_cap;
    int                  jit_compiled_chunks;
    int                  jit_scanned_chunks;
    uint32_t             jit_stop_counts[256];
    uint32_t             jit_stop_at_zero;
    uint32_t             jit_compiled_count;
    /* Target scope for load_file (sourced modules push into the
     * caller's scope, not the global env). NULL = state->global_env. */
    Env                 *load_env;
    /* #373: nonzero while compiling a load_file'd / imported module.
     * Function-body writes then never bind through to a loader-env
     * global that happened to exist at compile time — the write
     * compiles as a fresh local instead. Reads stay dynamic. */
    int                  compile_module_boundary;
    /* Per-import resolution base (Phase 0b). Empty = fall back to
     * state->script_dir. OP_IMPORT saves/restores around module body. */
    char                 import_resolve_dir[4096];
    /* Cycle-collector per-thread state (docs/CLOSURE_CYCLE_GC.md).
     * gc_threshold drives the off-hot-path collection trigger; gc_enabled
     * gates registration; in_gc is the re-entrancy guard. The candidate
     * REGISTRY (gc_envs, gc_captured_live) lives on EigsState — shared across
     * the state's threads, lock-guarded — so MT-created cycles stay
     * collectable; collection still runs only single-threaded. */
    int                  gc_threshold;
    int                  gc_enabled;
    int                  in_gc;
    /* Per-thread freelists + intern table (Phase 8). The freelists hold
     * recyclable Value/Env memory that survives until thread detach;
     * eigs_thread_drain_caches frees the held memory before the struct
     * itself goes away. Interns own their `name` strings. */
    Value               *num_freelist;
    int                  num_freelist_count;
    Env                 *env_freelist;
    int                  env_freelist_count;
    EnvNameIntern       *env_name_interns[ENV_NAME_INTERN_BUCKETS];
    /* Recursion-depth guards (parse/tokenize/value_to_string/JSON/native
     * call). Reset per top-level entry; reside here so multiple states
     * sharing an OS thread don't see each other's mid-walk depth. */
    int                  parse_depth;
    int                  tokenize_depth;
    int                  vts_depth;
    int                  json_depth;
    int                  native_call_depth;
    /* Registry list — set by eigs_thread_attach. */
    EigsThread *next;
};

/* Phase 8: free freelist + intern memory held on the thread. Called from
 * eigs_thread_detach before the EigsThread struct itself is released. */
void eigs_thread_drain_caches(EigsThread *th);

extern __thread EigsThread *eigs_current;

#define g_arena             (eigs_current->arena)
#define g_return_val        (eigs_current->return_val)
#define g_returning         (eigs_current->returning)
#define g_breaking          (eigs_current->breaking)
#define g_continuing        (eigs_current->continuing)
#define g_parse_errors      (eigs_current->parse_errors)
#define g_has_error         (eigs_current->has_error)
#define g_try_depth         (eigs_current->try_depth)
#define g_first_error_line  (eigs_current->first_error_line)
#define g_first_error_col   (eigs_current->first_error_col)
#define g_error_msg         (eigs_current->error_msg)
#define g_first_error_msg   (eigs_current->first_error_msg)
#define g_error_value       (eigs_current->error_value)
#define g_last_obs_slot_env (eigs_current->last_obs_slot_env)
#define g_last_obs_slot_idx (eigs_current->last_obs_slot_idx)
#define g_unobserved_depth  (eigs_current->unobserved_depth)
#define g_builtin_call_env  (eigs_current->builtin_call_env)
#define g_vm                  (*eigs_current->vm)
#define g_loop_stall_count    (eigs_current->loop_stall_count)
#define g_loop_iterations     (eigs_current->loop_iterations)
#define g_loop_exit_reason    (eigs_current->loop_exit_reason)
#define g_jit_cache           (eigs_current->jit_cache)
#define g_chunks              (eigs_current->jit_chunks)
#define g_chunks_count        (eigs_current->jit_chunks_count)
#define g_chunks_cap          (eigs_current->jit_chunks_cap)
#define g_jit_compiled_chunks (eigs_current->jit_compiled_chunks)
#define g_jit_scanned_chunks  (eigs_current->jit_scanned_chunks)
#define g_jit_stop_counts     (eigs_current->jit_stop_counts)
#define g_jit_stop_at_zero    (eigs_current->jit_stop_at_zero)
#define g_jit_compiled_count  (eigs_current->jit_compiled_count)
#define g_obs_dh_zero       (eigs_current->state->obs_dh_zero)
#define g_obs_dh_small      (eigs_current->state->obs_dh_small)
#define g_obs_h_low         (eigs_current->state->obs_h_low)
#define g_global_env          (eigs_current->state->global_env)
#define g_script_dir          (eigs_current->state->script_dir)
#define g_exe_dir             (eigs_current->state->exe_dir)
#define g_load_env            (eigs_current->load_env)
#define g_compile_module_boundary (eigs_current->compile_module_boundary)
#define g_import_resolve_dir  (eigs_current->import_resolve_dir)
#define g_vm_multithreaded    (eigs_current->state->multithreaded)
#define g_gc_envs             (eigs_current->state->gc_envs)
#define g_gc_captured_live    (eigs_current->state->gc_captured_live)
#define g_gc_val_buf          (eigs_current->state->gc_val_buf)
#define g_gc_val_count        (eigs_current->state->gc_val_count)
#define g_gc_val_cap          (eigs_current->state->gc_val_cap)
#define g_gc_threshold        (eigs_current->gc_threshold)
#define g_gc_enabled          (eigs_current->gc_enabled)
#define g_in_gc               (eigs_current->in_gc)
#define g_num_freelist        (eigs_current->num_freelist)
#define g_num_freelist_count  (eigs_current->num_freelist_count)
#define g_env_freelist        (eigs_current->env_freelist)
#define g_env_freelist_count  (eigs_current->env_freelist_count)
#define g_env_name_interns    (eigs_current->env_name_interns)
#define g_parse_depth         (eigs_current->parse_depth)
#define g_tokenize_depth      (eigs_current->tokenize_depth)
#define g_vts_depth           (eigs_current->vts_depth)
#define g_json_depth          (eigs_current->json_depth)
#define g_native_call_depth   (eigs_current->native_call_depth)
#define g_entry_threshold     (eigs_current->state->jit_entry_threshold)
#define g_iter_threshold      (eigs_current->state->jit_iter_threshold)
#define g_osr_threshold       (eigs_current->state->jit_osr_threshold)

/* Cycle collector floor: never collect more often than every 64 captured-
 * env registrations. State.c reads this when initializing EigsThread. */
#define GC_THRESHOLD_MIN 64

/* #307: value-candidate buffer drains a collection once this many LIST/DICT
 * "possible roots" have parked. Bounds the transient memory the buffer pins
 * keep alive between collections (each pinned candidate holds its subtree). */
#define GC_VAL_THRESHOLD 1024

/* ---- OOM-safe allocation wrappers ----
 * Abort with a diagnostic on allocation failure. Used by value constructors
 * and the arena allocator, where a NULL return would immediately crash.
 * The _array variants guard against size_t overflow in nmemb*size. */
void* xmalloc(size_t size);
void* xcalloc(size_t nmemb, size_t size);
void* xrealloc(void *p, size_t size);
char* xstrdup(const char *s);
size_t safe_size_mul(size_t a, size_t b);
void* xmalloc_array(size_t nmemb, size_t size);
void* xcalloc_array(size_t nmemb, size_t size);
void* xrealloc_array(void *p, size_t nmemb, size_t size);
/* fopen wrapper for any write mode ("w"/"wb"/"w+"/"a"/...). Pins the
 * created file's mode to 0644 regardless of process umask, so a permissive
 * umask cannot leave the file world-writable. Use for any newly-created
 * file; read-only fopen("r") may call fopen directly. */
FILE* xfopen_write(const char *path, const char *mode);

/* ---- Growable string buffer ----
 * Heap-backed, doubling growth. Used to replace fixed MAX_STR stack
 * buffers in the lexer, regex_replace, JSON encoder, value_to_string. */
typedef struct {
    char  *data;
    size_t len;
    size_t cap;
} strbuf;

void   strbuf_init(strbuf *b);
void   strbuf_reserve(strbuf *b, size_t need);
void   strbuf_append_char(strbuf *b, char c);
void   strbuf_append(strbuf *b, const char *s);
void   strbuf_append_n(strbuf *b, const char *s, size_t n);
void   strbuf_append_fmt(strbuf *b, const char *fmt, ...);
char  *strbuf_finish(strbuf *b);
void   strbuf_free(strbuf *b);

void arena_init(void);
void arena_destroy(void);
void* arena_alloc(size_t size);
void arena_track_string(char *s);
void arena_mark_pos(void);
void arena_reset_to_mark(void);
void free_weight_val(Value *v);

/* ---- Value constructors ---- */

Value* make_num(double n);
Value* promote_if_arena(Value *v);
void recycle_intermediate(Value *v);
Value* make_str(const char *s);
Value* make_str_owned(char *s);
Value* make_null(void);
Value* make_list(int capacity);
Value* make_list_heap(int capacity);
Value* make_text_builder(void);
Value* make_fn(const char *name, char **params, int param_count, Env *closure);
Value* make_builtin(BuiltinFn fn);
Value* make_dict(int capacity);
void dict_set(Value *dict, const char *key, Value *val);
void dict_set_owned(Value *dict, const char *key, Value *val);
/* Deep-copy a value for cross-thread channel transfer (#293): re-homes dict
 * keys into a process-global intern table so they survive the sender thread's
 * detach. Returns a heap value (refcount 1). */
Value *val_clone_for_send(Value *v);
Value* dict_get(Value *dict, const char *key);
void list_append(Value *list, Value *item);
void list_append_owned(Value *list, Value *item);

/* Bytecode chunk refcounting (full type + API in vm.h). free_val drops a
 * VAL_FN's chunk ref without needing the chunk layout. */
struct EigsChunk;
void chunk_incref(struct EigsChunk *chunk);
void chunk_decref(struct EigsChunk *chunk);
Value* call_eigs_fn(Value *fn, Value *arg);
uint32_t env_hash_name(const char *name);
char    *env_intern_name(const char *name);
void free_value(Value *v);

/* ---- Reference counting (atomic for thread safety) ----
 * Relaxed increment: caller already holds a reference, so no ordering needed.
 * Acquire-release decrement: release ensures writes are visible before the
 * refcount store; acquire ensures the thread that sees 0 observes all prior
 * writes before calling free_value. */
/* Numeric invariant: EigenScript has no NaN or Infinity.
 * All numeric operations route through this guard.
 * NaN -> 0; values escaping the finite number line saturate at
 * +/-1e308 instead of becoming Infinity. */
static inline double num_guard(double x) {
    if (x != x) return 0.0;            /* NaN */
    if (x > 1e308) return 1e308;       /* +Inf or overflow */
    if (x < -1e308) return -1e308;     /* -Inf or underflow */
    return x;
}

/* The g_vm_multithreaded flag (state->multithreaded, bridge macro above)
 * is set to 1 by builtin_spawn before pthread_create, then stays 1.
 * Single-threaded scripts (the common case — DMG, MiniSat, Tidepool,
 * REPL) keep it at 0, which lets val_incref/decref, slot_incref/decref,
 * and env_refcount sites skip the LOCK-prefixed atomic RMW (mandatory
 * on x86 for any __atomic_*_fetch). The branch is well-predicted to
 * false until spawn() fires. */

/* #307: Bacon-Rajan possible-root hook. A LIST/DICT that lost a ref but stayed
 * alive may now be the root of a garbage value cycle; buffer it for the next
 * cycle collection. Out-of-line (keeps val_decref/slot_decref lean) and gated
 * inside on GC-enabled / not-collecting / single-threaded. */
void gc_note_possible_root(Value *v);

static inline void val_incref(Value *v) {
    if (v && !v->arena) {
        if (__builtin_expect(g_vm_multithreaded, 0))
            __atomic_add_fetch(&v->refcount, 1, __ATOMIC_RELAXED);
        else
            v->refcount++;
    }
}
static inline void val_decref(Value *v) {
    if (v && !v->arena) {
        int newrc;
        if (__builtin_expect(g_vm_multithreaded, 0))
            newrc = __atomic_sub_fetch(&v->refcount, 1, __ATOMIC_ACQ_REL);
        else
            newrc = --v->refcount;
        if (newrc <= 0) free_value(v);
        else if (__builtin_expect((v->type == VAL_LIST || v->type == VAL_DICT)
                                  && !v->gc_buffered, 0))
            gc_note_possible_root(v);
    }
}

#include "value_slot.h"

/* ---- Environment ---- */

Env* env_new(Env *parent);
void env_set(Env *env, const char *name, Value *val);
Value* env_get(Env *env, const char *name);
void env_set_local(Env *env, const char *name, Value *val);
uint32_t env_name_hash(const char *name);
void env_set_hashed(Env *env, const char *name, uint32_t h, Value *val);
Value* env_get_hashed(Env *env, const char *name, uint32_t h);
Value* env_get_local_hashed(Env *env, const char *name, uint32_t h);
void env_set_local_hashed(Env *env, const char *name, uint32_t h, Value *val);
/* Slot-flavored fast paths: take/produce EigsSlot directly so immediates
 * never round-trip through make_num + val_decref. Reference-count
 * semantics match the Value* variants: env *borrows* the input slot and
 * incref's internally, *_get returns a slot the caller must slot_decref. */
void env_set_hashed_slot(Env *env, const char *name, uint32_t h, EigsSlot s);
void env_set_local_hashed_slot(Env *env, const char *name, uint32_t h, EigsSlot s);
/* Same as env_set_local_hashed_slot, but `interned` must come from
 * env_intern_name() so it can be stored directly without re-interning.
 * VM uses this with chunk->const_interns[idx] in the hot SET_NAME paths. */
void env_set_local_pre_interned_slot(Env *env, const char *interned,
                                     uint32_t h, EigsSlot s);
/* Bind a parameter into a freshly-created call env. Skips env_hash_find;
 * caller guarantees the name does not collide with an earlier binding. */
void env_bind_fresh_param_slot(Env *env, const char *interned,
                               uint32_t h, EigsSlot s);
/* Raw insert into env hash (exposed for vm.c inline call-site fast paths). */
void env_hash_insert(EnvHash *ht, uint32_t h, int idx);
EigsSlot env_get_hashed_slot(Env *env, const char *name, uint32_t h, int *found);
/* Direct slot store with arena promotion; used by VM inline-cache fast paths
 * after the slot index has been resolved out-of-band. Caller must update
 * binding_version/assign_counts as appropriate. */
void env_store_slot(Env *env, int idx, EigsSlot s);
/* Walk env chain for `name`. Returns target env on hit (with *out_slot and
 * *out_depth populated), NULL on miss. Depth 0 = start env, 1 = parent, etc. */
Env *env_resolve_chain(Env *start, const char *name, uint32_t h,
                       int *out_slot, int *out_depth);
void dict_set_hashed(Value *dict, const char *key, uint32_t h, Value *val);
Value* dict_get_hashed(Value *dict, const char *key, uint32_t h);
/* Env lifetime is a real refcount: env_new returns with refcount 1 (the
 * creator's ref — adopted by the call frame or the C caller) and an owned
 * ref on its parent. env_decref destroys at 0: drops every binding, drops
 * the parent ref, recycles or frees the struct. */
void env_incref(Env *env);
void env_decref(Env *env);
void env_destroy_final(Env *env);
/* Mark an env captured by a closure and register it with the cycle
 * collector (no-op registration for g_global_env and once spawn() has
 * gone multithreaded). May trigger a collection when the registry has
 * grown past the adaptive threshold. */
void env_mark_captured(Env *env);
/* Reclaim env<->fn reference cycles among captured envs. Safe at any
 * point where refcounts are consistent; conservative — when accounting
 * doesn't prove a subgraph dead it leaks instead of freeing. No-op when
 * multithreaded. */
void gc_collect_cycles(void);
/* Exit-time teardown of the global scope: drops every global binding,
 * then collects both env<->fn cycles and pure value cycles that were
 * rooted at global scope. Follow with env_decref(global). */
void gc_collect_at_exit(Env *global);
void env_set_local_owned(Env *env, const char *name, Value *val);
void env_clear(Env *env);
/* Reserve env slots up to `total` (used at function call to pre-allocate
 * non-captured local slots; OP_SET_LOCAL writes directly to slot indices). */
void env_reserve_slots(Env *env, int total);

/* Enable module-level slot promotion (Part B optimization).
 * Off by default. Set to 1 only for the main script chunk; load_file and REPL
 * leave it off so cross-chunk env lookups continue to work. */
extern int g_compile_module_slots;

/* `exit of N` requests a clean process exit with code N. Process-global (exit
 * terminates the whole process). The builtin sets these + g_has_error to unwind
 * vm_run to main via the existing error path; CHECK_ERROR treats the request as
 * uncatchable (a `try` must not swallow `exit`), and main exits with the code
 * after its normal teardown — so exit is leak-clean, unlike a raw exit(). */
extern int g_exit_requested;
extern int g_exit_code;

/* ---- Parser / Evaluator ---- */

TokenList tokenize(const char *source);
void free_tokenlist(TokenList *tl);

/* Number of distinct TokType values; equals the size of the base-token
 * vocabulary used by build_corpus. Identifier slot IDs start at this value. */
int tok_base_string_id_count(void);

/* Placeholder text for each base TokType, used by the corpus detokenizer.
 * Returned strings are static literals. Structural tokens
 * (NEWLINE/INDENT/DEDENT/EOF) return "" — the detokenizer is expected to
 * special-case those IDs (see structural_ids in the vocab JSON). */
const char* tok_base_string(TokType t);
ASTNode* parse(TokenList *tl);
void free_ast(ASTNode *node);
Value* eval_node(ASTNode *node, Env *env);
Value* eval_block(ASTNode **stmts, int count, Env *env);
int eval_result_is_owned(ASTNode *node);

int is_truthy(Value *v);
/* Structural equality for == / != (recursive for lists/dicts/buffers;
 * identity for functions/builtins; no cross-type coercion). */
int values_equal(Value *a, Value *b);
char* value_to_string(Value *v);
void observer_ensure_fresh(Value *v);
void eigs_json_escape_string(strbuf *out, const char *s);

/* ---- Registration ---- */

void register_builtins(Env *env);
/* #459: the compiler's OP_DISPATCH guard compares the compile-time binding
 * of `dispatch` against the registered builtin to detect a rebound name. */
Value *builtin_dispatch(Value *arg);
void register_hash_builtins(Env *env);
void eigenscript_set_args(int argc, char **argv);

/* ---- Utilities used across modules ---- */

/* Raise a recoverable runtime error: sets the error flag (caught by an
 * enclosing try, otherwise fatal — the VM unwinds) and prints to stderr
 * when uncaught. Declared here so extension TUs (ext_store, etc.) can route
 * argument/operation failures through the same strict channel as the VM. */
const char* val_type_name(ValType t);
void runtime_error(int line, const char *fmt, ...)
    __attribute__((format(printf, 2, 3)));
char* read_file_util(const char *path, long *out_size);
int resolve_eigenscript_file(const char *path, char *resolved, size_t resolved_cap);
/* Same chain, but the "script-relative" and "../" steps anchor at
 * `base` instead of `g_script_dir`. Used by OP_IMPORT to resolve a
 * module's own imports relative to that module's directory. */
int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap);
Value* eigs_json_parse_value(const char *s, int *pos);
/* Encode any Value as JSON. Returns heap-owned string (caller frees).
 * Functions/builtins emit "null" (matches the json_encode builtin). */
char* eigs_json_encode(Value *v);

/* ---- Control flow (return statement) ---- */
/* return_val, returning, parse_errors, error_msg, error_value,
 * first_error_line, first_error_msg, has_error, breaking, continuing,
 * try_depth are EigsThread fields (see Per-thread execution context
 * above). The declarations below cover the not-yet-migrated globals. */
void eigs_clear_error_value(void);
void vm_print_stack_trace(FILE *out);  /* uncaught-error call stack (vm.c); no-ops without a VM */
void eigs_record_first_error(int line, const char *msg);
void eigs_record_first_error_at(int line, int col, const char *msg);

/* ---- Module cache (Phase 0a of the package design) ---- */
/* Hit: out_dict gets a new counted ref (caller decrefs). Miss: out_dict
 * is NULL and the caller must execute + put. Keyed on the *absolute*
 * resolved path. */
/* Embedder source provider (eigs_embed.h seam): returns module source
 * for `name` or NULL. Consulted by vm.c's IMPORT before the filesystem
 * (hosted) / as the only source (freestanding). */
const char *eigs_source_lookup(const char *name);

int  eigs_module_cache_get(const char *abs_path, Value **out_dict);
/* Adds (incref'ing dict and env, strdup'ing path). No-op if path already
 * cached — first writer wins, since two concurrent inserts of the same
 * module would be a bug anyway. */
void eigs_module_cache_put(const char *abs_path, Value *dict, Env *env);
/* Releases all cached refs. Called from gc_collect_at_exit before the
 * global env's container snapshot, so cached module dicts/envs are
 * dropped first and any pure-value cycle they hold goes through the
 * usual snapshot collection. */
void eigs_module_cache_clear(void);

/* Observer thresholds are EigsState fields — set via set_observer_thresholds;
 * read through g_obs_dh_zero / g_obs_dh_small / g_obs_h_low (macros above). */

/* #412: `how` — deadband-normalized settledness of the last observed step,
 * 1.0 (unmoved) .. 0.0 (moved by >= the settle deadband). Pure function of
 * the recorded dH, shared by the live INTERROGATE paths (vm.c) and the tape
 * history reader (trace.c) so `how is x at L` matches the live reading. */
double observer_settledness(double dH);

/* ---- Cross-file functions for MODEL tensor builtins ---- */
/* When MODEL is enabled, these are defined in model_infer.c.
 * When disabled, eigenscript.c provides static stubs. */
#if EIGENSCRIPT_EXT_MODEL
void ne_softmax_buf(double *data, int64_t rows, int64_t cols);
void ne_matmul_buf(double *a, int64_t a_rows, int64_t a_cols,
                   double *b, int64_t b_cols, double *out);
Value* json_obj_get(Value *obj, const char *key);
#endif

/* ---- Handle table (opaque pointer indirection) ----
 * Table + lock + types declared up at the EigsState struct. */
int    handle_register(void *ptr, HandleType type);
void*  handle_lookup(int id, HandleType type);
/* Deterministic teardown of channel + thread handles (builtins.c): joins
 * outstanding workers, then frees remaining channels. Call once execution is
 * done and the value world is still alive (before env/thread teardown). */
void   handle_table_drain(struct EigsState *st);
void   handle_release(int id);

/* ---- EigenStore embedded database ---- */
void register_store_builtins(Env *env);

/* ---- Formatter & Linter ---- */
int eigenscript_fmt(const char *path, int write_mode);
char* format_source_string(const char *source);  /* malloc'd; caller frees */

/* Structured lint diagnostic (for non-CLI consumers like the LSP). */
typedef struct {
    int  line;             /* 1-based source line */
    char code[8];          /* stable code, e.g. "W001" */
    char severity[12];     /* "warning" / "error" */
    char message[256];
} LintDiag;
/* Run all lint checks on an already-parsed AST; fill out[] (up to max),
 * return the count. `path` = the source file's filesystem path (NULL if
 * unknown); it anchors E003's literal-load_file resolution, which reads the
 * loaded files — otherwise no I/O. `source` = the raw source text (NULL if
 * unavailable); it carries the `# lint: loaded-by` fragment directive
 * (#460) — the LSP passes the live doc buffer so as-you-type edits to the
 * directive take effect. Used by the LSP to publish diagnostics. */
int lint_collect(ASTNode *ast, const char *path, const char *source,
                 LintDiag *out, int max);
/* 1 if the source carries a file-wide `# lint: allow-file <code>` directive
 * for `code` (or `all`). Callers of lint_collect apply it themselves (the
 * CLI and the LSP both do) — suppression filters lint_collect's OUTPUT;
 * the loaded-by directive feeds its INPUT via the `source` param above. */
int lint_file_allows(const char *source, const char *code);
int eigenscript_lint(const char *path, int json_mode, int fail_on_warning);

#endif /* EIGENSCRIPT_H */
