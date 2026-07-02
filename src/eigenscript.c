/*
 * EigenScript Native Bootstrap Runtime
 * Core: tokenizer + parser + evaluator + builtins
 * Compiles with: gcc -O2 -o eigenscript eigenscript.c -lm -lpthread
 */

#include "eigenscript.h"
#include "vm.h"   /* EigsChunk layout: the cycle collector traverses
                   * fn -> chunk -> env_cache / functions[] edges */
#include <pthread.h>
#if EIGENSCRIPT_EXT_DB
#include "ext_db_internal.h"
#endif
#if EIGENSCRIPT_EXT_MODEL
#include "model_internal.h"
#endif

/* #298 follow-up: surface use-after-recycle on the per-thread Value/Env
 * freelists to Valgrind. A num/env whose refcount hits 0 is recycled onto a
 * freelist (not free()'d), so ASan — and un-annotated Valgrind — see it as
 * still-allocated: a stale incref/decref on a prematurely-recycled object is
 * invisible. We poison just the REFCOUNT field NOACCESS while the object sits on
 * the freelist (it's the field a dangling refcount op touches, it's separate
 * from the freelist link stored in v->data / env->parent, and it's reset on
 * reuse so re-defining it is clean). Gated behind EIGS_VALGRIND (`make
 * valgrind`); no-op, zero cost in normal/release/asan builds. */
#ifdef EIGS_VALGRIND
#include <valgrind/memcheck.h>
#define EIGS_VG_NOACCESS(p, n) VALGRIND_MAKE_MEM_NOACCESS((p), (n))
#define EIGS_VG_DEFINED(p, n)  VALGRIND_MAKE_MEM_DEFINED((p), (n))
#else
#define EIGS_VG_NOACCESS(p, n) ((void)0)
#define EIGS_VG_DEFINED(p, n)  ((void)0)
#endif

/* HTTP server globals and health thread are in ext_http.c.
 *
 * The control-flow/error-state TLS globals (g_return_val, g_returning,
 * g_breaking, g_continuing, g_parse_errors, g_error_msg,
 * g_first_error_line, g_first_error_msg, g_has_error, g_try_depth,
 * g_error_value) now live as fields on `eigs_current` (EigsThread, see
 * eigenscript.h). The g_* identifiers are macros that expand to
 * `eigs_current->field`. */

/* First syntax/parse error of the current tokenize+parse pass, captured
 * for consumers that can't see the parser's stderr (the LSP, which turns
 * it into a publishDiagnostics squiggle). Reset at the top of tokenize().
 * g_first_error_line is 1-based and 0 when no error has been recorded. */
void eigs_record_first_error(int line, const char *msg) {
    if (g_first_error_line) return;   /* keep only the first */
    g_first_error_line = line;
    snprintf(g_first_error_msg, sizeof(g_first_error_msg), "%s", msg ? msg : "syntax error");
}

/* Structured error payload: set by `throw` so catch can bind the thrown
 * value (dict/list/...) instead of a stringified copy. NULL for plain
 * runtime errors. Owned ref; consumed by vm_take_error_value, cleared
 * by eigs_clear_error_value on the uncaught path. */
void eigs_clear_error_value(void) {
    if (g_error_value) {
        val_decref(g_error_value);
        g_error_value = NULL;
    }
}

/* Defined in vm.c; prints the live call stack for uncaught errors.
 * Safe to call when no VM is active (it no-ops). */
void vm_print_stack_trace(FILE *out);

void runtime_error(int line, const char *fmt, ...) {
    char tmp[3900];
    va_list args;
    va_start(args, fmt);
    vsnprintf(tmp, sizeof(tmp), fmt, args);
    va_end(args);
    /* Tolerate a trailing newline in the format (some call sites carried one
     * over from fprintf): the "Error line N:" frame and the stderr write add
     * their own, and a trailing \n would also leak into a caught error's text. */
    size_t _tl = strlen(tmp);
    if (_tl > 0 && tmp[_tl - 1] == '\n') tmp[_tl - 1] = '\0';
    snprintf(g_error_msg, sizeof(g_error_msg), "Error line %d: %s", line, tmp);
    g_has_error = 1;
    eigs_clear_error_value();   /* a new error supersedes any thrown value */
    if (g_try_depth == 0) {
        fprintf(stderr, "%s\n", g_error_msg);
        vm_print_stack_trace(stderr);
    }
}

const char* tok_type_name(TokType t) {
    switch (t) {
        case TOK_NUM: return "number";
        case TOK_STR: return "string";
        case TOK_IDENT: return "identifier";
        case TOK_IS: return "'is'";
        case TOK_OF: return "'of'";
        case TOK_DEFINE: return "'define'";
        case TOK_AS: return "'as'";
        case TOK_IF: return "'if'";
        case TOK_ELSE: return "'else'";
        case TOK_ELIF: return "'elif'";
        case TOK_LOOP: return "'loop'";
        case TOK_WHILE: return "'while'";
        case TOK_RETURN: return "'return'";
        case TOK_AND: return "'and'";
        case TOK_OR: return "'or'";
        case TOK_NOT: return "'not'";
        case TOK_FOR: return "'for'";
        case TOK_IN: return "'in'";
        case TOK_NULL: return "'null'";
        case TOK_UNOBSERVED: return "'unobserved'";
        case TOK_LOCAL: return "'local'";
        case TOK_PLUS: return "'+'";
        case TOK_MINUS: return "'-'";
        case TOK_STAR: return "'*'";
        case TOK_SLASH: return "'/'";
        case TOK_PERCENT: return "'%'";
        case TOK_LT: return "'<'";
        case TOK_GT: return "'>'";
        case TOK_LE: return "'<='";
        case TOK_GE: return "'>='";
        case TOK_EQ: return "'=='";
        case TOK_NE: return "'!='";
        case TOK_ASSIGN: return "'='";
        case TOK_LPAREN: return "'('";
        case TOK_RPAREN: return "')'";
        case TOK_LBRACKET: return "'['";
        case TOK_RBRACKET: return "']'";
        case TOK_COMMA: return "','";
        case TOK_COLON: return "':'";
        case TOK_DOT: return "'.'";
        case TOK_LBRACE: return "'{'";
        case TOK_RBRACE: return "'}'";
        case TOK_NEWLINE: return "newline";
        case TOK_INDENT: return "indent";
        case TOK_DEDENT: return "dedent";
        case TOK_EOF: return "end of file";
        case TOK_TRY: return "'try'";
        case TOK_CATCH: return "'catch'";
        case TOK_BREAK: return "'break'";
        case TOK_CONTINUE: return "'continue'";
        case TOK_IMPORT: return "'import'";
        case TOK_MATCH: return "'match'";
        case TOK_CASE: return "'case'";
        case TOK_PIPE: return "'|>'";
        case TOK_ARROW: return "'=>'";
        case TOK_AMP: return "'&'";
        case TOK_BITOR: return "'|'";
        case TOK_CARET: return "'^'";
        case TOK_SHL: return "'<<'";
        case TOK_SHR: return "'>>'";
        case TOK_TILDE: return "'~'";
        case TOK_PLUS_EQ: return "'+='";
        case TOK_MINUS_EQ: return "'-='";
        case TOK_STAR_EQ: return "'*='";
        case TOK_SLASH_EQ: return "'/='";
        case TOK_PERCENT_EQ: return "'%='";
        case TOK_AMP_EQ: return "'&='";
        case TOK_BITOR_EQ: return "'|='";
        case TOK_CARET_EQ: return "'^='";
        case TOK_SHL_EQ: return "'<<='";
        case TOK_SHR_EQ: return "'>>='";
        default: return "?";
    }
}

const char* val_type_name(ValType t) {
    switch (t) {
        case VAL_NUM: return "num";
        case VAL_STR: return "str";
        case VAL_LIST: return "list";
        case VAL_FN: return "fn";
        case VAL_BUILTIN: return "builtin";
        case VAL_NULL: return "null";
        case VAL_JSON_RAW: return "json_raw";
        case VAL_DICT: return "dict";
        case VAL_BUFFER: return "buffer";
        case VAL_TEXT_BUILDER: return "text_builder";
        default: return "?";
    }
}
/* g_global_env is an EigsState field — see eigenscript.h bridge macros. */

/* Arena allocator and free_weight_val are in arena.c */

/* Forward declarations for hash helpers (used by dict and env). */
uint32_t env_hash_name(const char *name);
static void env_hash_init(EnvHash *ht, int cap);
void env_hash_insert(EnvHash *ht, uint32_t h, int idx);
static void env_hash_rebuild(EnvHash *ht, char **names, int count);
static int env_hash_find(const EnvHash *ht, const char *name, uint32_t h, char **names);

/* ================================================================
 * VALUE CONSTRUCTORS
 * ================================================================ */

/* Recursively free a heap-allocated Value tree.
 * Skips arena-allocated values (v->arena flag). */
/* NUM_FREELIST_CAP / ENV_FREELIST_CAP / ENV_FREELIST_MAX_BINDINGS /
 * ENV_NAME_INTERN_BUCKETS and the EnvNameIntern typedef now live in
 * eigenscript.h so EigsThread can carry the freelist heads + intern
 * table inline. The g_num_freelist / g_env_freelist / g_env_name_interns
 * identifiers are bridge macros — same access syntax, one extra TLS
 * deref through eigs_current. */

/* Refcount-aware teardown. Called by val_decref when refcount hits 0.
 * Children are val_decref'd (not recursively freed), so shared values
 * tracked by refcount elsewhere stay alive. Arena-owned memory is
 * skipped — it gets reclaimed by arena_reset. */
/* ---- Observer system (moved from eval.c) ---- */

/* #262 Phase-3 D: scalar entropy of a number, factored out so the slot
 * observer can update from a raw immediate double without materializing a
 * Value (the default path no longer promotes observed nums to tracked
 * pointers). Single source of truth for the VAL_NUM entropy formula. */
static double entropy_of_num(double num) {
    double x = fabs(num);
    if (x == 0.0 || x == 1.0) return 0.0;
    double p = 1.0 / (1.0 + x);
    if (p <= 0.0 || p >= 1.0) return 0.0;
    return -(p * log2(p) + (1.0-p) * log2(1.0-p));
}

static double compute_entropy_impl(Value *v, int depth) {
    if (!v || depth > 64) return 0.0;
    switch (v->type) {
        case VAL_NULL: return 0.0;
        case VAL_NUM: return entropy_of_num(v->data.num);
        case VAL_STR: {
            if (!v->data.str || !v->data.str[0]) return 0.0;
            int freq[256] = {0};
            int len = 0;
            for (const char *c = v->data.str; *c; c++) { freq[(unsigned char)*c]++; len++; }
            if (len == 0) return 0.0;
            double h = 0.0;
            for (int i = 0; i < 256; i++) {
                if (freq[i] > 0) { double p = (double)freq[i] / len; h -= p * log2(p); }
            }
            return h;
        }
        case VAL_LIST: {
            if (v->data.list.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.list.count; i++)
                sum += compute_entropy_impl(v->data.list.items[i], depth + 1);
            return sum / v->data.list.count + log2(v->data.list.count + 1);
        }
        case VAL_DICT: {
            if (v->data.dict.count == 0) return 0.0;
            double sum = 0.0;
            for (int i = 0; i < v->data.dict.count; i++)
                sum += compute_entropy_impl(v->data.dict.vals[i], depth + 1);
            return sum / v->data.dict.count + log2(v->data.dict.count + 1);
        }
        case VAL_FN: return 1.0;
        case VAL_BUILTIN: return 0.0;
        case VAL_JSON_RAW: return 0.0;
        case VAL_BUFFER: return log2(v->data.buffer.count + 1);
        case VAL_TEXT_BUILDER: return log2((double)v->data.text_builder.len + 1.0);
    }
    return 0.0;
}

double compute_entropy(Value *v) { return compute_entropy_impl(v, 0); }


/* ===== #262 slot-keyed observer (the only observer model) =====
 *
 * Observer trajectory state lives on a per-binding ObserverSlot (env + slot
 * index), not on the recyclable Value object. Updated EAGERLY at assignment
 * time (no dirty/lazy step): the variable's own value sequence is observed
 * regardless of which Value object backs it, so an iterate built through
 * aliasing temps tracks correctly. This is what fixed #262 — the value-path
 * observer model (state on the Value) was removed in Step E. */

static void observer_slot_window_push(ObserverSlot *s, double dh) {
    if (!s->dh_window) {
        s->dh_window = xcalloc(OBSERVER_WINDOW_N, sizeof(double));
        s->dh_window_head = 0;
        s->dh_window_count = 0;
    }
    s->dh_window[s->dh_window_head] = dh;
    s->dh_window_head = (uint8_t)((s->dh_window_head + 1) % OBSERVER_WINDOW_N);
    if (s->dh_window_count < OBSERVER_WINDOW_N) s->dh_window_count++;
}

static double observer_slot_window_get(const ObserverSlot *s, size_t offset_back) {
    if (!s->dh_window || offset_back >= s->dh_window_count) return 0.0;
    int idx = (int)s->dh_window_head - 1 - (int)offset_back;
    while (idx < 0) idx += OBSERVER_WINDOW_N;
    return s->dh_window[idx];
}

/* #294 value-signal channel: same ring buffer as the entropy window, but the
 * pushed quantity is the value's own relative step Δv/(1+|v|). */
static void observer_slot_v_push(ObserverSlot *s, double rel_delta) {
    if (!s->v_window) {
        s->v_window = xcalloc(OBSERVER_WINDOW_N, sizeof(double));
        s->v_window_head = 0;
        s->v_window_count = 0;
    }
    s->v_window[s->v_window_head] = rel_delta;
    s->v_window_head = (uint8_t)((s->v_window_head + 1) % OBSERVER_WINDOW_N);
    if (s->v_window_count < OBSERVER_WINDOW_N) s->v_window_count++;
}

static double observer_slot_v_get(const ObserverSlot *s, size_t offset_back) {
    if (!s->v_window || offset_back >= s->v_window_count) return 0.0;
    int idx = (int)s->v_window_head - 1 - (int)offset_back;
    while (idx < 0) idx += OBSERVER_WINDOW_N;
    return s->v_window[idx];
}

/* Fold one observed numeric value into the slot's value channel. The stored
 * step is RELATIVE (Δv/(1+|v|)) so the thresholds carry the same meaning across
 * value scales: a ±0.6 swing around 5 reads "moving" (~12% steps), the same
 * swing around 1e6 is effectively settled. First value seeds last_value only. */
static void observer_slot_record_value(ObserverSlot *s, double v) {
    if (s->v_used) {
        double rel = (v - s->last_value) / (1.0 + fabs(v));
        observer_slot_v_push(s, rel);
    }
    s->last_value = v;
    s->v_used = 1;
}

/* Core: fold a precomputed entropy into binding slot `idx` of env `e`. */
static void observer_slot_update_e(Env *e, int idx, double new_entropy) {
    if (!e || idx < 0) return;
    if (idx >= e->obs_cap) {
        int ncap = idx + 8;
        ObserverSlot *no = realloc(e->obs, (size_t)ncap * sizeof(ObserverSlot));
        if (!no) return;
        memset(no + e->obs_cap, 0, (size_t)(ncap - e->obs_cap) * sizeof(ObserverSlot));
        e->obs = no;
        e->obs_cap = ncap;
    }
    ObserverSlot *s = &e->obs[idx];
    s->prev_dH = s->dH;
    if (!s->used || s->obs_age == 0) {
        s->dH = 0;                 /* first observation of this binding */
    } else {
        s->dH = new_entropy - s->last_entropy;
        observer_slot_window_push(s, s->dH);
    }
    s->entropy = new_entropy;
    s->last_entropy = new_entropy;
    s->obs_age++;
    s->used = 1;
}

void observer_slot_update(Env *e, int idx, Value *newval) {
    observer_slot_update_e(e, idx, compute_entropy(newval));
    /* #294 also fold the raw value into the value-signal channel (numbers only:
     * the relative-delta step is only defined for a scalar trajectory). */
    if (newval && newval->type == VAL_NUM && e && idx >= 0 && idx < e->obs_cap)
        observer_slot_record_value(&e->obs[idx], newval->data.num);
}

/* #262 Phase-3 D: update a binding's observer slot from a raw immediate
 * number, so the default path can observe without promoting the num to a
 * tracked Value. Same trajectory math as observer_slot_update. */
void observer_slot_update_num(Env *e, int idx, double num) {
    observer_slot_update_e(e, idx, entropy_of_num(num));
    if (e && idx >= 0 && idx < e->obs_cap)      /* #294 value-signal channel */
        observer_slot_record_value(&e->obs[idx], num);
}

void observer_slot_reset(Env *e) {
    if (!e || !e->obs) return;
    vm_obs_slot_dropped(e);   /* invalidate the VM's last-observed-slot tracker */
    for (int i = 0; i < e->obs_cap; i++) {
        free(e->obs[i].dh_window);
        free(e->obs[i].v_window);   /* #294 value-signal window */
    }
    free(e->obs);
    e->obs = NULL;
    e->obs_cap = 0;
}

int observer_slot_converged(const ObserverSlot *s) {
    if (!s || s->dh_window_count < OBSERVER_WINDOW_N) return 0;
    for (size_t i = 0; i < OBSERVER_WINDOW_N; i++)
        if (fabs(observer_slot_window_get(s, i)) >= g_obs_dh_zero) return 0;
    return (s->entropy < g_obs_h_low) ? 1 : 0;
}

int observer_slot_equilibrium(const ObserverSlot *s) {
    if (!s || s->dh_window_count < OBSERVER_WINDOW_N) return 0;
    double sum = 0.0;
    for (size_t i = 0; i < OBSERVER_WINDOW_N; i++) sum += observer_slot_window_get(s, i);
    double mean = sum / (double)OBSERVER_WINDOW_N;
    if (fabs(mean) >= g_obs_dh_zero) return 0;
    double var = 0.0;
    for (size_t i = 0; i < OBSERVER_WINDOW_N; i++) {
        double d = observer_slot_window_get(s, i) - mean;
        var += d * d;
    }
    var /= (double)OBSERVER_WINDOW_N;
    return (var < g_obs_dh_zero * g_obs_dh_zero) ? 1 : 0;
}

/* Slot mirrors of the remaining four windowed predicates — identical logic to
 * the observer_*(Value*) versions above, reading the slot's window/entropy. */
int observer_slot_improving(const ObserverSlot *s) {
    size_t cnt = s ? s->dh_window_count : 0;
    if (cnt < 3) return 0;
    double sum = 0.0; int down = 0;
    for (size_t i = 0; i < cnt; i++) {
        double w = observer_slot_window_get(s, i);
        sum += w;
        if (w < -g_obs_dh_small) down++;
    }
    return (sum < 0.0 && (size_t)(down * 5) >= cnt * 3) ? 1 : 0;
}

int observer_slot_diverging(const ObserverSlot *s) {
    size_t cnt = s ? s->dh_window_count : 0;
    if (cnt < 3) return 0;
    double sum = 0.0; int up = 0;
    for (size_t i = 0; i < cnt; i++) {
        double w = observer_slot_window_get(s, i);
        sum += w;
        if (w > g_obs_dh_small) up++;
    }
    return (sum > 0.0 && (size_t)(up * 5) >= cnt * 3) ? 1 : 0;
}

int observer_slot_oscillating(const ObserverSlot *s) {
    size_t cnt = s ? s->dh_window_count : 0;
    if (cnt < 3) return 0;
    const int FLIPS = (OBSERVER_WINDOW_N + 2) / 3;
    int flips = 0;
    for (size_t i = 0; i + 1 < cnt; i++) {
        double a = observer_slot_window_get(s, i);
        double b = observer_slot_window_get(s, i + 1);
        if (a * b < 0.0 && fabs(a) > g_obs_dh_zero && fabs(b) > g_obs_dh_zero) flips++;
    }
    return (flips >= FLIPS) ? 1 : 0;
}

int observer_slot_stable(const ObserverSlot *s) {
    size_t cnt = s ? s->dh_window_count : 0;
    if (cnt < OBSERVER_WINDOW_N) return 0;
    if (s->entropy < g_obs_h_low) return 0;
    for (size_t i = 0; i < cnt; i++)
        if (fabs(observer_slot_window_get(s, i)) >= g_obs_dh_small) return 0;
    for (size_t i = 0; i + 1 < cnt; i++) {
        double a = observer_slot_window_get(s, i);
        double b = observer_slot_window_get(s, i + 1);
        if (a * b < 0.0 && fabs(a) > g_obs_dh_zero && fabs(b) > g_obs_dh_zero) return 0;
    }
    return 1;
}

/* Slot mirror of builtin_report — same priority order and partial-window
 * fallback, reading the slot trajectory instead of a Value's. */
const char *observer_slot_report(const ObserverSlot *s) {
    if (!s) return NULL;
    if (observer_slot_oscillating(s)) return "oscillating";
    if (observer_slot_diverging(s))   return "diverging";
    if (observer_slot_improving(s))   return "improving";
    if (observer_slot_converged(s))   return "converged";
    if (observer_slot_equilibrium(s)) return "equilibrium";
    if (observer_slot_stable(s))      return "stable";
    /* Partial-window best-effort label (mirrors builtin_report's tail). */
    if (fabs(s->dH) < g_obs_dh_zero) return "equilibrium";
    if (fabs(s->dH) < g_obs_dh_small && s->entropy >= g_obs_h_low) return "stable";
    return "stable";
}

/* #294 value-signal report. Classifies the binding's VALUE trajectory using the
 * SAME windowed logic and thresholds as the entropy report above — only the
 * observed signal differs (relative value-deltas, not entropy-deltas). This is
 * the point of the experiment: the windowed approach is sound; the entropy
 * SIGNAL is a lossy proxy that goes blind to value-oscillation in flat-entropy
 * regions. Oscillation is detected by sign-flips (scale-free); settling by the
 * relative-step magnitude (so thresholds mean the same across value scales). */
const char *observer_slot_report_value(const ObserverSlot *s) {
    if (!s || !s->v_used) return "equilibrium";   /* no numeric trajectory */
    size_t cnt = s->v_window_count;
    if (cnt == 0) return "equilibrium";           /* one value seen, no step yet */
    if (cnt >= 3) {
        const int FLIPS = (OBSERVER_WINDOW_N + 2) / 3;  /* same as entropy channel */
        int flips = 0;
        for (size_t i = 0; i + 1 < cnt; i++) {
            double a = observer_slot_v_get(s, i);
            double b = observer_slot_v_get(s, i + 1);
            if (a * b < 0.0 && fabs(a) > g_obs_dh_zero && fabs(b) > g_obs_dh_zero) flips++;
        }
        if (flips >= FLIPS) return "oscillating";
    }
    int all_zero = 1, all_small = 1;
    for (size_t i = 0; i < cnt; i++) {
        double w = fabs(observer_slot_v_get(s, i));
        if (w >= g_obs_dh_zero)  all_zero = 0;
        if (w >= g_obs_dh_small) all_small = 0;
    }
    if (cnt >= OBSERVER_WINDOW_N && all_zero) return "converged";
    if (all_small) return "stable";
    return "moving";
}

/* g_last_observer, g_builtin_call_env, g_unobserved_depth are EigsThread
 * fields; g_obs_dh_zero/small/h_low are EigsState fields. See the macros
 * in eigenscript.h that bridge the source identifiers to those fields. */

/* Phase 8: release per-thread freelist memory + intern table at detach.
 * The freelists store recyclable Value/Env structs that would otherwise
 * leak on thread teardown; the intern table owns its `name` strings.
 * Called from eigs_thread_detach BEFORE eigs_current is cleared, so
 * the bridge macros still resolve. */
void eigs_thread_drain_caches(EigsThread *th) {
    if (!th) return;

    /* num_freelist: each entry's first sizeof(Value*) bytes of data are
     * overlaid with the next-pointer. Save next, free node, advance. */
    Value *vn = th->num_freelist;
    while (vn) {
        Value *next;
        memcpy(&next, &vn->data, sizeof(Value *));
        free(vn);
        vn = next;
    }
    th->num_freelist = NULL;
    th->num_freelist_count = 0;

    /* env_freelist: parked envs use ->parent as the next pointer and
     * retain their names/values/assign_counts/hash arrays for reuse. */
    Env *en = th->env_freelist;
    while (en) {
        Env *next = en->parent;
        observer_slot_reset(en);   /* #262 Phase-1 (normally already reset on park) */
        free(en->names);
        free(en->values);
        free(en->assign_counts);
        free(en->hash.hashes);
        free(en->hash.indices);
        free(en->hash.generations);
        free(en);
        en = next;
    }
    th->env_freelist = NULL;
    th->env_freelist_count = 0;

    /* env_name_interns: bucket heads + linked-list nodes own ->name. */
    for (int i = 0; i < ENV_NAME_INTERN_BUCKETS; i++) {
        EnvNameIntern *it = th->env_name_interns[i];
        while (it) {
            EnvNameIntern *next = it->next;
            free(it->name);
            free(it);
            it = next;
        }
        th->env_name_interns[i] = NULL;
    }
}

void free_value(Value *v) {
    if (!v || v->arena) return;
    if (v->type == VAL_NUM) {
        /* Route freed NUMs to freelist for reuse by make_num */
        if (g_num_freelist_count < NUM_FREELIST_CAP) {
            memcpy(&v->data, &g_num_freelist, sizeof(Value *));
            g_num_freelist = v;
            g_num_freelist_count++;
            EIGS_VG_NOACCESS(&v->refcount, sizeof(v->refcount));  /* #297/#298 */
            return;
        }
        free(v);
        return;
    }
    switch (v->type) {
        case VAL_STR:
        case VAL_JSON_RAW:
            if (v->data.str) free(v->data.str);
            break;
        case VAL_LIST:
            for (int i = 0; i < v->data.list.count; i++)
                val_decref(v->data.list.items[i]);
            if (v->data.list.items)
                free(v->data.list.items);
            break;
        case VAL_DICT:
            for (int i = 0; i < v->data.dict.count; i++) {
                /* keys are interned (env_intern_name) — do not free */
                val_decref(v->data.dict.vals[i]);
            }
            free(v->data.dict.keys);
            free(v->data.dict.vals);
            free(v->data.dict.hash.hashes);
            free(v->data.dict.hash.indices);
            free(v->data.dict.hash.generations);
            break;
        case VAL_FN:
            free(v->data.fn.name);
            /* params[i] are interned (lifetime owned by intern map); only free the array. */
            free(v->data.fn.params);
            free(v->data.fn.param_hashes);
            if (v->data.fn.body_count != -1) {
                /* AST-based function — free body nodes */
                for (int i = 0; i < v->data.fn.body_count; i++)
                    free_ast(v->data.fn.body[i]);
                free(v->data.fn.body);
            }
            /* body_count == -1 means bytecode fn: body is a chunk ptr;
             * this fn holds a ref on it (taken in OP_CLOSURE). */
            if (v->data.fn.body_count == -1)
                chunk_decref((struct EigsChunk *)v->data.fn.body);
            {
                Env *clo = v->data.fn.closure;
                v->data.fn.closure = NULL;  /* break cycle before decrement */
                env_decref(clo);
            }
            break;
        case VAL_BUFFER:
            free(v->data.buffer.data);
            break;
        case VAL_TEXT_BUILDER:
            free(v->data.text_builder.data);
            break;
        default:
            break;
    }
    free(v);
}

Value* make_num(double n) {
    n = num_guard(n);
    int from_arena = g_arena.active;
    Value *v;
    if (!from_arena && g_num_freelist) {
        v = g_num_freelist;
        memcpy(&g_num_freelist, &v->data, sizeof(Value *));
        g_num_freelist_count--;
        EIGS_VG_DEFINED(&v->refcount, sizeof(v->refcount));  /* un-poison before reuse */
        memset(v, 0, sizeof(Value));
    } else {
        v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    }
    v->type = VAL_NUM;
    v->data.num = n;
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

void recycle_intermediate(Value *v) {
    if (!v || v->type != VAL_NUM || v->arena || v->refcount > 1) return;
    if (g_num_freelist_count >= NUM_FREELIST_CAP) {
        free(v);
        return;
    }
    memcpy(&v->data, &g_num_freelist, sizeof(Value *));
    g_num_freelist = v;
    g_num_freelist_count++;
    EIGS_VG_NOACCESS(&v->refcount, sizeof(v->refcount));  /* #297/#298 */
}

/* Heap-only make_num — for values that must outlive arena reset */
Value* make_num_permanent(double n) {
    n = num_guard(n);
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_NUM;
    v->data.num = n;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

/* Forward decl of the VAL_NULL singleton — defined below near make_null. */
static Value g_null_singleton;

/* ---- NaN-boxing boundary shims ----
 *
 * slot_from_value: takes ownership of the input ref.
 *   - NULL or VAL_NULL singleton -> immediate null (input is borrowed)
 *   - VAL_NUM -> immediate double; input released (#262 Step E: nums never
 *     carry observer state, so there is no tracked-pointer case)
 *   - any other type -> TAG_HEAP; ref transferred
 *
 * Arena-allocated VAL_NUM cannot be tracked (it would die at arena
 * reset). For Phase A's safety, an arena VAL_NUM with observer state
 * is promoted to heap via make_tracked_num.
 */
EigsSlot slot_from_value(Value *v) {
    if (!v || v->type == VAL_NULL) {
        if (v && !v->arena && v != &g_null_singleton) val_decref(v);
        return slot_null();
    }
    if (v->type == VAL_NUM) {
        /* #262 Step E: a number never carries observer state (it lives on the
         * Env slot), so every VAL_NUM ships as an immediate double. TAG_TRACKED
         * is dead. */
        double n = v->data.num;
        val_decref(v);
        return slot_from_num(n);
    }
    return slot_from_heap(v);
}

/* slot_to_value: produces a Value* the caller owns a ref to.
 *   - immediate number/bool -> make_num
 *   - immediate null -> g_null_singleton
 *   - heap/tracked pointer -> incref and return
 */
Value* slot_to_value(EigsSlot s) {
    if (slot_is_num(s)) return make_num(s.d);
    if (slot_is_null(s)) return &g_null_singleton;
    if (slot_is_bool(s)) return make_num(slot_as_bool(s) ? 1.0 : 0.0);
    if (slot_is_heap(s)) {
        Value *v = slot_as_ptr(s);
        val_incref(v);
        return v;
    }
    /* unknown tag: fall back to null */
    return &g_null_singleton;
}

Value* promote_if_arena(Value *v) {
    if (!v || !v->arena) return v;
    if (v->type == VAL_NUM) {
        /* #262 Step E: no observer fields to carry across the promotion. */
        return make_num_permanent(v->data.num);
    }
    if (v->type == VAL_STR || v->type == VAL_JSON_RAW) {
        Value *h = xcalloc(1, sizeof(Value));
        h->type = v->type;
        h->data.str = xstrdup(v->data.str);
        h->refcount = 1;
        return h;
    }
    if (v->type == VAL_NULL) {
        /* VAL_NULL has a single immortal singleton (g_null_singleton, arena=1).
         * Don't allocate a heap copy — incref/decref are already no-ops on it,
         * and a heap VAL_NULL leaks via slot_bridge_wrap's pointer-drop. */
        return v;
    }
    /* Lists, dicts, functions: leave as-is (complex deep copy).
     * Callers should avoid storing arena-allocated complex types. */
    return v;
}

Value* make_str(const char *s) {
    int from_arena = g_arena.active;
    Value *v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = xstrdup(s);
    if (from_arena) arena_track_string(v->data.str);
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

Value* make_str_owned(char *s) {
    int from_arena = g_arena.active;
    Value *v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_STR;
    v->data.str = s;
    if (from_arena) arena_track_string(s);
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

static Value g_null_singleton = { .type = VAL_NULL, .refcount = 1000000, .arena = 1 };
/* forward decl resolved here */

Value* make_null(void) {
    return &g_null_singleton;
}

Value* make_list(int capacity) {
    int from_arena = g_arena.active;
    Value *v = from_arena ? arena_alloc(sizeof(Value)) : xcalloc(1, sizeof(Value));
    v->type = VAL_LIST;
    v->data.list.capacity = capacity < 8 ? 8 : capacity;
    if (from_arena)
        v->data.list.items = arena_alloc(v->data.list.capacity * sizeof(Value*));
    else
        v->data.list.items = xcalloc(v->data.list.capacity, sizeof(Value*));
    v->data.list.count = 0;
    v->refcount = 1;
    v->arena = from_arena;
    return v;
}

/* Heap-forced list — for VM-internal wrappers that must outlive an arena
 * window. An arena list freezes val_decref into a no-op, so any heap items
 * it incref'd via list_append are leaked when the arena is reclaimed.
 * Used by the builtin-arg packing path: the wrapper holds incref'd args,
 * and val_decref(arg) must actually walk and release them on return. */
Value* make_list_heap(int capacity) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_LIST;
    v->data.list.capacity = capacity < 8 ? 8 : capacity;
    v->data.list.items = xcalloc(v->data.list.capacity, sizeof(Value*));
    v->data.list.count = 0;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* make_text_builder(void) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_TEXT_BUILDER;
    v->data.text_builder.cap = 256;
    v->data.text_builder.data = xmalloc(v->data.text_builder.cap);
    v->data.text_builder.data[0] = '\0';
    v->data.text_builder.len = 0;
    v->data.text_builder.parts = 0;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* make_fn(const char *name, char **params, int param_count, Env *closure) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_FN;
    v->data.fn.name = xstrdup(name);
    v->data.fn.params = xmalloc_array(param_count, sizeof(char*));
    v->data.fn.param_hashes = xmalloc_array(param_count, sizeof(uint32_t));
    v->data.fn.param_count = param_count;
    for (int i = 0; i < param_count; i++) {
        v->data.fn.params[i] = env_intern_name(params[i]);
        v->data.fn.param_hashes[i] = env_hash_name(params[i]);
    }
    /* AST bodies died with the tree-walking evaluator. OP_CLOSURE
     * overwrites body with the compiled chunk ptr and body_count with
     * the -1 bytecode sentinel right after this returns. */
    v->data.fn.body = NULL;
    v->data.fn.body_count = 0;
    v->data.fn.closure = closure;
    env_incref(closure);   /* the fn's owned ref on its captured env */
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* make_builtin(BuiltinFn fn) {
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUILTIN;
    v->data.builtin = fn;
    v->refcount = 1;
    v->arena = 0;
    return v;
}

Value* make_dict(int capacity) {
    if (capacity < 8) capacity = 8;
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_DICT;
    v->data.dict.keys = xcalloc(capacity, sizeof(char*));
    v->data.dict.vals = xcalloc(capacity, sizeof(Value*));
    v->data.dict.count = 0;
    v->data.dict.capacity = capacity;
    env_hash_init(&v->data.dict.hash, ENV_HASH_INIT_CAP);
    v->refcount = 1;
    v->arena = 0;
    return v;
}

void dict_set_hashed(Value *dict, const char *key, uint32_t h, Value *val) {
    if (!dict || dict->type != VAL_DICT) return;
    if (h == 0) h = env_hash_name(key);
    int idx = env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
    if (idx >= 0) {
        Value *promoted = promote_if_arena(val);
        if (promoted != val) {
            val_decref(dict->data.dict.vals[idx]);
            dict->data.dict.vals[idx] = promoted;
        } else {
            val_incref(val);
            val_decref(dict->data.dict.vals[idx]);
            dict->data.dict.vals[idx] = val;
        }
        return;
    }
    /* Grow if needed */
    if (dict->data.dict.count >= dict->data.dict.capacity) {
        int new_cap = dict->data.dict.capacity * 2;
        dict->data.dict.keys = xrealloc_array(dict->data.dict.keys, new_cap, sizeof(char*));
        dict->data.dict.vals = xrealloc_array(dict->data.dict.vals, new_cap, sizeof(Value*));
        dict->data.dict.capacity = new_cap;
    }
    dict->data.dict.keys[dict->data.dict.count] = env_intern_name(key);
    Value *promoted = promote_if_arena(val);
    dict->data.dict.vals[dict->data.dict.count] = promoted;
    if (promoted == val) val_incref(val);
    dict->data.dict.count++;
    if (dict->data.dict.count * 10 > (dict->data.dict.hash.mask + 1) * 7)
        env_hash_rebuild(&dict->data.dict.hash, dict->data.dict.keys, dict->data.dict.count);
    else
        env_hash_insert(&dict->data.dict.hash, h, dict->data.dict.count - 1);
}

void dict_set(Value *dict, const char *key, Value *val) {
    dict_set_hashed(dict, key, env_hash_name(key), val);
}

/* Adopting setter: dict_set increfs internally, so passing a freshly
 * made value directly strands its birth ref (one leaked Value per
 * call). This consumes the birth ref — use it whenever the caller
 * does not keep its own pointer to the value. */
void dict_set_owned(Value *dict, const char *key, Value *val) {
    dict_set(dict, key, val);
    val_decref(val);
}

/* #293: cross-thread channel transfer. A value sent on a channel can outlive
 * the SENDER thread, but its dict keys are interned in that thread's
 * env_name_interns table (eigs_thread_drain_caches frees it at detach) — the
 * receiver then reads dangling key pointers ("cannot index num" / garbage
 * keys). String VALUES are strdup-owned per Value and survive on refcount;
 * only the interned KEYS need rehoming. We deep-copy the value on send and
 * re-intern its dict keys into a process-global, lock-protected table that
 * lives for the process — reachable from a static root (so LeakSanitizer sees
 * it as still-reachable, not a leak) and deduped (so it stays bounded). Copying
 * also removes the old shared-by-reference concurrent-mutation footgun for the
 * data types it covers. Non-container types (fn/builtin/buffer/text_builder/
 * json) are still shared by refcount; sending a closure from a thread that then
 * exits remains unsupported (its interned params would dangle). */
static EnvNameIntern *g_chan_key_interns[ENV_NAME_INTERN_BUCKETS];
static pthread_mutex_t g_chan_key_mutex = PTHREAD_MUTEX_INITIALIZER;

static const char *chan_intern_key(const char *name) {
    uint32_t h = env_hash_name(name);
    int bucket = h & (ENV_NAME_INTERN_BUCKETS - 1);
    pthread_mutex_lock(&g_chan_key_mutex);
    for (EnvNameIntern *it = g_chan_key_interns[bucket]; it; it = it->next) {
        if (it->hash == h && strcmp(it->name, name) == 0) {
            pthread_mutex_unlock(&g_chan_key_mutex);
            return it->name;
        }
    }
    EnvNameIntern *it = xcalloc(1, sizeof(EnvNameIntern));
    it->name = xstrdup(name);
    it->hash = h;
    it->next = g_chan_key_interns[bucket];
    g_chan_key_interns[bucket] = it;
    pthread_mutex_unlock(&g_chan_key_mutex);
    return it->name;
}

#define CHAN_CLONE_MAX_DEPTH 64
static Value *chan_clone_rec(Value *v, int depth) {
    if (!v) return make_null();
    /* Cycle / pathological-depth guard: fall back to sharing (the pre-#293
     * behavior) rather than overflow the stack. */
    if (depth > CHAN_CLONE_MAX_DEPTH) { val_incref(v); return v; }
    switch (v->type) {
        case VAL_NUM:  return make_num(v->data.num);
        case VAL_NULL: return make_null();
        case VAL_STR:  return make_str(v->data.str);
        case VAL_LIST: {
            int n = v->data.list.count;
            Value *out = make_list_heap(n > 0 ? n : 1);
            for (int i = 0; i < n; i++) {
                Value *ce = chan_clone_rec(v->data.list.items[i], depth + 1);
                list_append(out, ce);   /* increfs */
                val_decref(ce);         /* drop birth ref */
            }
            return out;
        }
        case VAL_DICT: {
            int n = v->data.dict.count;
            Value *out = make_dict(n > 0 ? n : 8);
            for (int i = 0; i < n; i++) {
                Value *cv = chan_clone_rec(v->data.dict.vals[i], depth + 1);
                dict_set_owned(out, v->data.dict.keys[i], cv);  /* consumes cv */
            }
            /* Rehome keys from the (thread-local, soon-freed) intern table to
             * the process-global one. env_hash_find compares by hash+strcmp, so
             * the differing key-pointer pool is fine. */
            for (int i = 0; i < out->data.dict.count; i++)
                out->data.dict.keys[i] = (char *)chan_intern_key(out->data.dict.keys[i]);
            return out;
        }
        default:
            val_incref(v);   /* share fn/builtin/buffer/text_builder/json by refcount */
            return v;
    }
}

/* Deep-copy a value for cross-thread channel transfer (see chan_clone_rec).
 * Forces heap allocation (g_arena is per-thread, so toggling its active flag is
 * safe here) so the copy survives the sender's arena_reset as well as detach. */
Value *val_clone_for_send(Value *v) {
    int saved_active = g_arena.active;
    g_arena.active = 0;
    Value *out = chan_clone_rec(v, 0);
    g_arena.active = saved_active;
    return out;
}

Value* dict_get_hashed(Value *dict, const char *key, uint32_t h) {
    if (!dict || dict->type != VAL_DICT) return NULL;
    if (h == 0) h = env_hash_name(key);
    int idx = env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
    return (idx >= 0) ? dict->data.dict.vals[idx] : NULL;
}

Value* dict_get(Value *dict, const char *key) {
    return dict_get_hashed(dict, key, env_hash_name(key));
}

int env_hash_find_dict(Value *dict, const char *key, uint32_t h) {
    if (!dict || dict->type != VAL_DICT) return -1;
    return env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
}

int dict_has(Value *dict, const char *key) {
    return dict_get(dict, key) != NULL;
}

void dict_remove(Value *dict, const char *key) {
    if (!dict || dict->type != VAL_DICT) return;
    uint32_t h = env_hash_name(key);
    int idx = env_hash_find(&dict->data.dict.hash, key, h, dict->data.dict.keys);
    if (idx < 0) return;
    /* keys are interned — do not free */
    val_decref(dict->data.dict.vals[idx]);
    /* Shift remaining */
    for (int j = idx; j < dict->data.dict.count - 1; j++) {
        dict->data.dict.keys[j] = dict->data.dict.keys[j+1];
        dict->data.dict.vals[j] = dict->data.dict.vals[j+1];
    }
    dict->data.dict.count--;
    env_hash_rebuild(&dict->data.dict.hash, dict->data.dict.keys, dict->data.dict.count);
}

void list_append(Value *list, Value *item) {
    if (!list || list->type != VAL_LIST) return;
    if (list->data.list.count >= list->data.list.capacity) {
        int new_cap = list->data.list.capacity * 2;
        if (list->arena) {
            /* Cannot realloc arena memory — allocate new array and copy */
            Value **new_items = arena_alloc(safe_size_mul(new_cap, sizeof(Value*)));
            memcpy(new_items, list->data.list.items, list->data.list.count * sizeof(Value*));
            list->data.list.items = new_items;
        } else {
            list->data.list.items = xrealloc_array(list->data.list.items, new_cap, sizeof(Value*));
        }
        list->data.list.capacity = new_cap;
    }
    list->data.list.items[list->data.list.count++] = item;
    val_incref(item);
}

/* Adopting append: list_append increfs internally, so appending a
 * freshly made value directly strands its birth ref (one leaked Value
 * per element). This consumes the birth ref — use it whenever the
 * caller does not keep its own pointer to the item. */
void list_append_owned(Value *list, Value *item) {
    list_append(list, item);
    val_decref(item);
}

int is_truthy(Value *v) {
    if (!v) return 0;
    switch (v->type) {
        case VAL_NULL: return 0;
        case VAL_NUM: return v->data.num != 0.0;
        case VAL_STR: return v->data.str && v->data.str[0] != '\0';
        case VAL_LIST: return v->data.list.count > 0;
        case VAL_FN: return 1;
        case VAL_BUILTIN: return 1;
        case VAL_JSON_RAW: return v->data.str && v->data.str[0] != '\0';
        case VAL_DICT: return v->data.dict.count > 0;
        case VAL_BUFFER: return v->data.buffer.count > 0;
        case VAL_TEXT_BUILDER: return v->data.text_builder.len > 0;
    }
    return 0;
}

/* Structural equality for `==` / `!=`.
 * Scalars compare by value (numbers, strings, null); collections compare
 * recursively by structure (lists element-wise, dicts by key/value
 * order-independently, buffers/text-builders by contents). Functions,
 * builtins, and raw-JSON compare by identity. Mixed types are never equal
 * (no coercion — consistent with the comparison operators). The depth
 * guard prevents runaway recursion on self-referential containers; beyond
 * it we fall back to identity. */
static int values_equal_impl(Value *a, Value *b, int depth) {
    if (a == b) return 1;
    if (!a || !b) return 0;
    if (a->type != b->type) return 0;
    if (depth > 64) return a == b;
    switch (a->type) {
        case VAL_NUM:  return a->data.num == b->data.num;
        case VAL_STR:  return strcmp(a->data.str, b->data.str) == 0;
        case VAL_NULL: return 1;
        case VAL_LIST: {
            if (a->data.list.count != b->data.list.count) return 0;
            for (int i = 0; i < a->data.list.count; i++)
                if (!values_equal_impl(a->data.list.items[i],
                                       b->data.list.items[i], depth + 1))
                    return 0;
            return 1;
        }
        case VAL_DICT: {
            if (a->data.dict.count != b->data.dict.count) return 0;
            for (int i = 0; i < a->data.dict.count; i++) {
                Value *bv = dict_get(b, a->data.dict.keys[i]);
                if (!bv) return 0;
                if (!values_equal_impl(a->data.dict.vals[i], bv, depth + 1))
                    return 0;
            }
            return 1;
        }
        case VAL_BUFFER: {
            if (a->data.buffer.count != b->data.buffer.count) return 0;
            for (int i = 0; i < a->data.buffer.count; i++)
                if (a->data.buffer.data[i] != b->data.buffer.data[i]) return 0;
            return 1;
        }
        case VAL_TEXT_BUILDER:
            return a->data.text_builder.len == b->data.text_builder.len &&
                   memcmp(a->data.text_builder.data, b->data.text_builder.data,
                          a->data.text_builder.len) == 0;
        default: /* VAL_FN, VAL_BUILTIN, VAL_JSON_RAW — identity */
            return a == b;
    }
}

int values_equal(Value *a, Value *b) { return values_equal_impl(a, b, 0); }

char* value_to_string(Value *v) {
    if (!v) return xstrdup("null");
    if (g_vts_depth > 64) return xstrdup("[...]");
    char buf[256];
    switch (v->type) {
        case VAL_NULL: return xstrdup("null");
        case VAL_NUM: {
            double n = v->data.num;
            /* Exact integers up to 2^53 (the largest integer all doubles
             * represent exactly) print without a decimal point or exponent. */
            if (n == (long long)n && fabs(n) < 9007199254740992.0) {
                snprintf(buf, sizeof(buf), "%lld", (long long)n);
            } else {
                /* Shortest representation that round-trips: try 15..17
                 * significant digits and stop at the first that parses back
                 * to the same double. %.6g (the old default) silently
                 * truncated every float to 6 figures — lossy for the
                 * numerical/STEM workloads this language targets. */
                for (int prec = 15; prec <= 17; prec++) {
                    snprintf(buf, sizeof(buf), "%.*g", prec, n);
                    if (strtod(buf, NULL) == n) break;
                }
            }
            return xstrdup(buf);
        }
        case VAL_STR: return xstrdup(v->data.str);
        case VAL_LIST: {
            strbuf out;
            strbuf_init(&out);
            strbuf_append_char(&out, '[');
            g_vts_depth++;
            for (int i = 0; i < v->data.list.count; i++) {
                if (i > 0) strbuf_append_n(&out, ", ", 2);
                char *s = value_to_string(v->data.list.items[i]);
                if (v->data.list.items[i] && v->data.list.items[i]->type == VAL_STR)
                    eigs_json_escape_string(&out, s);
                else
                    strbuf_append(&out, s);
                free(s);
            }
            g_vts_depth--;
            strbuf_append_char(&out, ']');
            return strbuf_finish(&out);
        }
        case VAL_FN: snprintf(buf, sizeof(buf), "<fn %s>", v->data.fn.name); return xstrdup(buf);
        case VAL_DICT: {
            strbuf out;
            strbuf_init(&out);
            strbuf_append_char(&out, '{');
            g_vts_depth++;
            for (int i = 0; i < v->data.dict.count; i++) {
                if (i > 0) strbuf_append_n(&out, ", ", 2);
                eigs_json_escape_string(&out, v->data.dict.keys[i]);
                strbuf_append_n(&out, ": ", 2);
                char *vs = value_to_string(v->data.dict.vals[i]);
                if (v->data.dict.vals[i] && v->data.dict.vals[i]->type == VAL_STR)
                    eigs_json_escape_string(&out, vs);
                else
                    strbuf_append(&out, vs);
                free(vs);
            }
            g_vts_depth--;
            strbuf_append_char(&out, '}');
            return strbuf_finish(&out);
        }
        case VAL_BUILTIN: return xstrdup("<builtin>");
        case VAL_JSON_RAW: return xstrdup(v->data.str);
        case VAL_BUFFER:
            snprintf(buf, sizeof(buf), "<buffer:%d>", v->data.buffer.count);
            return xstrdup(buf);
        case VAL_TEXT_BUILDER:
            return xstrdup(v->data.text_builder.data ? v->data.text_builder.data : "");
    }
    return xstrdup("?");
}

/* ================================================================
 * ENVIRONMENT
 * ================================================================ */

/* FNV-1a hash — fast, good distribution for short identifier strings.
 * Returns non-zero (zero is reserved as "empty slot" sentinel). */
uint32_t env_hash_name(const char *name) {
    uint32_t h = 2166136261u;
    for (const char *p = name; *p; p++)
        h = (h ^ (uint8_t)*p) * 16777619u;
    return h | 1;  /* ensure non-zero */
}

uint32_t env_name_hash(const char *name) {
    return env_hash_name(name);
}

static void env_hash_init(EnvHash *ht, int cap) {
    ht->mask = cap - 1;
    ht->hashes      = xmalloc_array(cap, sizeof(uint32_t));
    ht->indices     = xmalloc_array(cap, sizeof(int));
    ht->generations = xcalloc(cap, sizeof(uint32_t));  /* zero => empty (current gen starts at 1) */
    ht->generation  = 1;
    for (int i = 0; i < cap; i++) ht->indices[i] = -1;
}

void env_hash_insert(EnvHash *ht, uint32_t h, int idx) {
    int slot = h & ht->mask;
    uint32_t gen = ht->generation;
    while (ht->generations[slot] == gen) {
        slot = (slot + 1) & ht->mask;
    }
    ht->hashes[slot] = h;
    ht->indices[slot] = idx;
    ht->generations[slot] = gen;
}

static void env_hash_rebuild(EnvHash *ht, char **names, int count) {
    int new_cap = (ht->mask + 1) * 2;
    if (new_cap < ENV_HASH_INIT_CAP) new_cap = ENV_HASH_INIT_CAP;
    free(ht->hashes);
    free(ht->indices);
    free(ht->generations);
    env_hash_init(ht, new_cap);
    for (int i = 0; i < count; i++) {
        /* Skip slot-only entries (names[i] == NULL). Function envs interleave
         * compiler-assigned local slots (addressed by index, never in the
         * hash) with later SET_NAME_LOCAL appends (named, in the hash). The
         * rebuild must reinsert only the named entries — feeding env_hash_name
         * a NULL pointer crashes in strlen. */
        if (names[i]) env_hash_insert(ht, env_hash_name(names[i]), i);
    }
}

/* Lookup name in hash table. Returns index into names/values or -1.
 * Slot is "occupied" iff its generation matches the table's current gen.
 *
 * Fast path: when both the lookup name and stored name come from the
 * intern pool (env_intern_name), they're pointer-equal on match — no
 * strcmp needed. Falls back to strcmp for callers (e.g. dict.keys)
 * whose keys aren't routed through the intern pool. */
static int env_hash_find(const EnvHash *ht, const char *name, uint32_t h, char **names) {
    if (!ht->generations) return -1;
    int slot = h & ht->mask;
    uint32_t gen = ht->generation;
    while (ht->generations[slot] == gen) {
        if (ht->hashes[slot] == h) {
            const char *stored = names[ht->indices[slot]];
            if (stored == name || strcmp(stored, name) == 0)
                return ht->indices[slot];
        }
        slot = (slot + 1) & ht->mask;
    }
    return -1;
}

char *env_intern_name(const char *name) {
    uint32_t h = env_hash_name(name);
    int bucket = h & (ENV_NAME_INTERN_BUCKETS - 1);
    for (EnvNameIntern *it = g_env_name_interns[bucket]; it; it = it->next) {
        if (it->hash == h && strcmp(it->name, name) == 0)
            return it->name;
    }
    EnvNameIntern *it = xcalloc(1, sizeof(EnvNameIntern));
    it->name = xstrdup(name);
    it->hash = h;
    it->next = g_env_name_interns[bucket];
    g_env_name_interns[bucket] = it;
    return it->name;
}

Env* env_new(Env *parent) {
    Env *e = NULL;
    if (g_env_freelist) {
        e = g_env_freelist;
        g_env_freelist = e->parent;
        g_env_freelist_count--;
        EIGS_VG_DEFINED(&e->env_refcount, sizeof(e->env_refcount));  /* un-poison before reuse */
        e->count = 0;
        /* Generation already bumped in env_decref's freelist branch.
         * Hash slots from the prior occupant are dormant by virtue of
         * generations[i] != current generation. */
    } else {
        e = xcalloc(1, sizeof(Env));
        e->capacity = ENV_INIT_CAP;
        e->names  = xcalloc(ENV_INIT_CAP, sizeof(char *));
        e->values = xcalloc(ENV_INIT_CAP, sizeof(EigsSlot));
        e->assign_counts = xcalloc(ENV_INIT_CAP, sizeof(int));
        env_hash_init(&e->hash, ENV_HASH_INIT_CAP);
    }
    e->parent = parent;
    if (parent) env_incref(parent);   /* the parent link is an owned ref */
    e->heap_allocated = 1;
    e->captured = 0;
    e->env_refcount = 1;              /* creator's ref (frame or C caller) */
    return e;
}

void env_incref(Env *env) {
    if (!env) return;
    if (__builtin_expect(g_vm_multithreaded, 0))
        __atomic_add_fetch(&env->env_refcount, 1, __ATOMIC_RELAXED);
    else
        env->env_refcount++;
}

void env_set_hashed(Env *env, const char *name, uint32_t h, Value *val) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            Value *promoted = promote_if_arena(val);
            if (promoted == val) val_incref(promoted);
            EigsSlot new_s = slot_from_value(promoted);
            slot_decref(e->values[idx]);
            e->values[idx] = new_s;
            if (e->assign_counts && g_unobserved_depth == 0)
                e->assign_counts[idx]++;
            return;
        }
        e = e->parent;
    }
    env_set_local_hashed(env, name, h, val);
}

void env_set(Env *env, const char *name, Value *val) {
    env_set_hashed(env, name, env_hash_name(name), val);
}

void env_set_local_hashed(Env *env, const char *name, uint32_t h, Value *val) {
    if (h == 0) h = env_hash_name(name);
    int idx = env_hash_find(&env->hash, name, h, env->names);
    if (idx >= 0) {
        Value *promoted = promote_if_arena(val);
        if (promoted == val) val_incref(promoted);
        EigsSlot new_s = slot_from_value(promoted);
        slot_decref(env->values[idx]);
        env->values[idx] = new_s;
        if (env->assign_counts && g_unobserved_depth == 0)
            env->assign_counts[idx]++;
        return;
    }
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        if (!env->heap_allocated) {
            char **nn  = arena_alloc(nsz);
            EigsSlot *nv = arena_alloc(vsz);
            memcpy(nn, env->names, env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(EigsSlot));
            env->names  = nn;
            env->values = nv;
        } else {
            env->names  = realloc(env->names, nsz);
            env->values = realloc(env->values, vsz);
            env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
            if (!env->names || !env->values) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        }
        env->capacity = new_cap;
    }
    env->names[env->count] = env_intern_name(name);
    Value *promoted = promote_if_arena(val);
    if (promoted == val) val_incref(promoted);
    env->values[env->count] = slot_from_value(promoted);
    if (env->assign_counts)
        env->assign_counts[env->count] = (g_unobserved_depth == 0) ? 1 : 0;
    env->count++;
    env->binding_version++;

    /* Insert into hash; rebuild if load factor > 70% */
    if (env->count * 10 > (env->hash.mask + 1) * 7)
        env_hash_rebuild(&env->hash, env->names, env->count);
    else
        env_hash_insert(&env->hash, h, env->count - 1);
}

/* ---- Slot-flavored env helpers (Phase B-5 hot path) ----
 * env borrows the input slot and slot_incref's internally to take a ref.
 * Promotion: an arena-tracked pointer slot is materialized to heap via
 * slot_to_value + promote_if_arena to preserve the existing arena-safety
 * contract that env never holds arena Values across arena reset. */
void env_store_slot(Env *env, int idx, EigsSlot s) {
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v && v->arena) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                /* promoted is fresh (refcount=1); env takes it. */
                EigsSlot new_s = slot_from_value(promoted);
                slot_decref(env->values[idx]);
                env->values[idx] = new_s;
                return;
            }
        }
    }
    slot_incref(s);
    slot_decref(env->values[idx]);
    env->values[idx] = s;
}

void env_set_hashed_slot(Env *env, const char *name, uint32_t h, EigsSlot s) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            env_store_slot(e, idx, s);
            if (e->assign_counts && g_unobserved_depth == 0)
                e->assign_counts[idx]++;
            return;
        }
        e = e->parent;
    }
    env_set_local_hashed_slot(env, name, h, s);
}

/* Core local-set implementation: caller has already interned `name`. */
void env_set_local_pre_interned_slot(Env *env, const char *interned,
                                     uint32_t h, EigsSlot s) {
    int idx = env_hash_find(&env->hash, interned, h, env->names);
    if (idx >= 0) {
        env_store_slot(env, idx, s);
        if (env->assign_counts && g_unobserved_depth == 0)
            env->assign_counts[idx]++;
        return;
    }
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        if (!env->heap_allocated) {
            char **nn = arena_alloc(nsz);
            EigsSlot *nv = arena_alloc(vsz);
            memcpy(nn, env->names, env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(EigsSlot));
            env->names = nn;
            env->values = nv;
        } else {
            env->names = realloc(env->names, nsz);
            env->values = realloc(env->values, vsz);
            env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
            if (!env->names || !env->values) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        }
        env->capacity = new_cap;
    }
    env->names[env->count] = (char*)interned;
    EigsSlot stored = s;
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v && v->arena) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                stored = slot_from_value(promoted);
                goto store;
            }
        }
    }
    slot_incref(s);
store:
    env->values[env->count] = stored;
    if (env->assign_counts)
        env->assign_counts[env->count] = (g_unobserved_depth == 0) ? 1 : 0;
    env->count++;
    env->binding_version++;
    if (env->count * 10 > (env->hash.mask + 1) * 7)
        env_hash_rebuild(&env->hash, env->names, env->count);
    else
        env_hash_insert(&env->hash, h, env->count - 1);
}

void env_set_local_hashed_slot(Env *env, const char *name, uint32_t h, EigsSlot s) {
    if (h == 0) h = env_hash_name(name);
    env_set_local_pre_interned_slot(env, env_intern_name(name), h, s);
}

/* Bind a parameter into a freshly-created call env. Caller guarantees:
 *   - env was just returned by env_new (heap_allocated=1, count=N with N<param)
 *   - `interned` came from env_intern_name (or VAL_FN.params, now interned)
 *   - the param name does not collide with any earlier param in this env
 *     (compiler rejects duplicate params)
 * Skips env_hash_find. */
void env_bind_fresh_param_slot(Env *env, const char *interned,
                               uint32_t h, EigsSlot s) {
    if (env->count >= env->capacity) {
        int new_cap = env->capacity * 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        env->names = realloc(env->names, nsz);
        env->values = realloc(env->values, vsz);
        env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
        if (!env->names || !env->values) {
            fprintf(stderr, "Out of memory growing env\n");
            exit(1);
        }
        env->capacity = new_cap;
    }
    env->names[env->count] = (char*)interned;
    EigsSlot stored = s;
    if (slot_is_ptr(s)) {
        Value *v = slot_as_ptr(s);
        if (v && v->arena) {
            Value *promoted = promote_if_arena(v);
            if (promoted && promoted != v) {
                stored = slot_from_value(promoted);
                goto store;
            }
        }
    }
    slot_incref(s);
store:
    env->values[env->count] = stored;
    if (env->assign_counts) env->assign_counts[env->count] = 1;
    env->count++;
    env->binding_version++;
    if (env->count * 10 > (env->hash.mask + 1) * 7)
        env_hash_rebuild(&env->hash, env->names, env->count);
    else
        env_hash_insert(&env->hash, h, env->count - 1);
}

/* Walk the env chain for `name`. On hit, returns target env, slot index in
 * that env, and depth (0 = starting env, 1 = parent, ...). On miss, returns
 * NULL. Used by VM IC populate path so we don't re-walk to discover depth. */
Env *env_resolve_chain(Env *start, const char *name, uint32_t h,
                       int *out_slot, int *out_depth) {
    if (h == 0) h = env_hash_name(name);
    Env *e = start;
    int depth = 0;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            if (out_slot)  *out_slot  = idx;
            if (out_depth) *out_depth = depth;
            return e;
        }
        e = e->parent;
        depth++;
    }
    return NULL;
}

EigsSlot env_get_hashed_slot(Env *env, const char *name, uint32_t h, int *found) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            if (found) *found = 1;
            return e->values[idx];
        }
        e = e->parent;
    }
    if (found) *found = 0;
    return slot_null();
}

int env_get_assign_count(Env *env, const char *name, uint32_t h) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) return e->assign_counts ? e->assign_counts[idx] : 0;
        e = e->parent;
    }
    return 0;
}

void env_set_local(Env *env, const char *name, Value *val) {
    env_set_local_hashed(env, name, env_hash_name(name), val);
}

/* Adopting setter for registration code. env_set_local increfs the
 * value internally, so passing a freshly made value directly strands
 * its birth ref — every builtin used to sit at refcount 2 with a
 * single owner, unfreeable by any teardown. This consumes the birth
 * ref so the env holds the only reference. */
void env_set_local_owned(Env *env, const char *name, Value *val) {
    env_set_local(env, name, val);
    val_decref(val);
}

/* Unlink an env from the captured-env registry (defined with the cycle
 * collector below). Safe to call on unregistered envs. */
static void gc_unregister_env(Env *env);

void env_decref(Env *env) {
    if (!env || !env->heap_allocated) return;
    int newrc;
    if (__builtin_expect(g_vm_multithreaded, 0))
        newrc = __atomic_sub_fetch(&env->env_refcount, 1, __ATOMIC_ACQ_REL);
    else
        newrc = --env->env_refcount;
    if (newrc > 0) return;
    /* Destructor: drop bindings, drop the parent link's owned ref,
     * recycle or free the struct. */
    gc_unregister_env(env);
    for (int i = 0; i < env->count; i++) {
        slot_decref(env->values[i]);
    }
    Env *parent = env->parent;
    /* #262 Phase-1: drop slot-keyed observer state on both park and free so a
     * recycled env never carries another binding's trajectory. */
    observer_slot_reset(env);
    if (env->capacity <= ENV_FREELIST_MAX_BINDINGS &&
        g_env_freelist_count < ENV_FREELIST_CAP) {
        env->count = 0;
        env->captured = 0;
        env->env_refcount = 0;
        env->binding_version++; /* invalidate VM inline caches */
        /* O(1) invalidation: bump generation. On wrap, fall back to a
         * full reset (every ~4 billion env reuses on this thread). */
        if (++env->hash.generation == 0) {
            memset(env->hash.generations, 0,
                   (env->hash.mask + 1) * sizeof(uint32_t));
            env->hash.generation = 1;
        }
#ifdef EIGS_POISON
        /* The parked arrays are dormant-dirty by design (gated by count=0 +
         * the generation bump). Poison them so any read that slips past a
         * gate sees 0xAA, not a stale-but-plausible pointer/index. The
         * generations array IS the gate and must not be touched. */
        EIGS_POISON_MEM(env->names, env->capacity * sizeof(char *));
        EIGS_POISON_MEM(env->values, env->capacity * sizeof(EigsSlot));
        if (env->assign_counts)
            EIGS_POISON_MEM(env->assign_counts, env->capacity * sizeof(int));
        EIGS_POISON_MEM(env->hash.hashes, (env->hash.mask + 1) * sizeof(uint32_t));
        EIGS_POISON_MEM(env->hash.indices, (env->hash.mask + 1) * sizeof(int));
#endif
        env->parent = g_env_freelist;
        g_env_freelist = env;
        g_env_freelist_count++;
        EIGS_VG_NOACCESS(&env->env_refcount, sizeof(env->env_refcount));  /* #297/#298 */
    } else {
        free(env->names);
        free(env->values);
        free(env->assign_counts);
        free(env->hash.hashes);
        free(env->hash.indices);
        free(env->hash.generations);
        free(env);
    }
    env_decref(parent);   /* after the struct is gone: chains release iteratively */
}

/* Shutdown-only teardown for the global env.
 *
 * Honest refcounts mean closures still hold the env (env_refcount > 0)
 * at process exit, leaking the whole global scope whenever a script
 * defined a function — the fn value lives *in* the env that it captures,
 * a cycle the plain counts can't break. Force the issue: detach the slot
 * array first so reentrant env_decref calls (a dying closure decrementing
 * env_refcount mid-loop) see an empty env, pin env_refcount high so those
 * calls cannot free the struct under us, then decref every binding and
 * free the arrays unconditionally. Only call this when nothing will touch
 * the env again — i.e. immediately before exit, after trace_shutdown has
 * dropped its own value refs. (main.c's normal teardown now uses
 * env_clear + gc_collect_cycles + env_decref instead; this remains for
 * paths that must hard-destroy an env regardless of live references.) */
void env_destroy_final(Env *env) {
    if (!env || !env->heap_allocated) return;
    gc_unregister_env(env);
    EigsSlot *vals = env->values;
    int count = env->count;
    env->values = NULL;
    env->count = 0;
    env->captured = 1;
    env->env_refcount = 1 << 30;
    for (int i = 0; i < count; i++)
        slot_decref(vals[i]);
    observer_slot_reset(env);   /* #262 Phase-1 */
    free(vals);
    free(env->names);
    free(env->assign_counts);
    free(env->hash.hashes);
    free(env->hash.indices);
    free(env->hash.generations);
    free(env);
}

/* ================================================================
 * CLOSURE-CYCLE COLLECTOR  (docs/CLOSURE_CYCLE_GC.md)
 *
 * The env<->fn cycle (an env binding a closure that captures it) keeps
 * both refcounts above zero forever. With env lifetime now an honest
 * refcount — creator/frame, closures, child envs via parent, parked
 * env_cache all counted — cyclic garbage is detectable locally:
 *
 *   1. U := every object reachable from the registered captured envs
 *      through OWNED edges only (env slots, env->parent, fn->closure,
 *      list items, dict values). g_global_env is a stop node: it holds
 *      the creator ref for the whole process lifetime, so it is always
 *      externally rooted and traversing into it would just drag the
 *      entire heap into every collection.
 *   2. internal[n] := number of edges into n from inside U.
 *   3. roots := nodes with refcount > internal — some reference exists
 *      that we did not traverse (VM stack slot, a frame's env ref, a C
 *      caller's ref, the trace tape, a parked env's parent link, ...).
 *      Every such holder owns a counted ref, so it shows up here without
 *      any root-set enumeration.
 *   4. Mark from the roots within U; unmarked nodes are unreachable
 *      cyclic garbage. Pin them, clear their outgoing edges (normal
 *      decrefs), then unpin — each node frees through its ordinary
 *      destructor path.
 *
 * Conservative by construction: if internal counts ever exceed a
 * refcount (an uncounted edge was traversed — accounting bug), the
 * whole collection aborts and the memory leaks instead. Collection is
 * disabled once spawn() goes multithreaded: cross-thread roots are
 * still counted refs (so nothing would be freed wrongly), but registry
 * list maintenance is not thread-safe, so registration stops and the
 * registry is drained up front.
 * ================================================================ */

/* gc_threshold, gc_enabled, in_gc are per-thread (EigsThread); the candidate
 * registry (gc_envs, gc_captured_live) is per-state (EigsState). The g_* names
 * are bridge macros from eigenscript.h. GC_THRESHOLD_MIN is defined there so
 * state.c can seed gc_threshold on attach. */

/* Registry-list lock: contended only while the state is multithreaded; a
 * single-threaded state never touches the mutex. Collection holds NO lock (it
 * runs only when single-threaded), so register/unregister under the lock can
 * never deadlock against it. */
static inline void gc_registry_lock(void) {
    if (g_vm_multithreaded) pthread_mutex_lock(&eigs_current->state->gc_lock);
}
static inline void gc_registry_unlock(void) {
    if (g_vm_multithreaded) pthread_mutex_unlock(&eigs_current->state->gc_lock);
}

static void gc_unregister_env(Env *env) {
    if (!env->in_gc_list) return;   /* fast path: not a candidate, no lock */
    gc_registry_lock();
    if (!env->in_gc_list) { gc_registry_unlock(); return; }
    env->in_gc_list = 0;
    if (env->gc_prev) env->gc_prev->gc_next = env->gc_next;
    else g_gc_envs = env->gc_next;
    if (env->gc_next) env->gc_next->gc_prev = env->gc_prev;
    env->gc_next = NULL;
    env->gc_prev = NULL;
    g_gc_captured_live--;
    gc_registry_unlock();
}

void env_mark_captured(Env *env) {
    if (!env) return;
    env->captured = 1;
    if (!g_gc_enabled || g_in_gc || env->in_gc_list || env == g_global_env)
        return;
    gc_registry_lock();
    env->in_gc_list = 1;
    env->gc_prev = NULL;
    env->gc_next = g_gc_envs;
    if (g_gc_envs) g_gc_envs->gc_prev = env;
    g_gc_envs = env;
    int live = ++g_gc_captured_live;
    gc_registry_unlock();
    /* Capture events are the only way the candidate universe grows, so this is
     * the (off-hot-path) collection trigger — but never collect while
     * multithreaded (gc_collect_impl bails anyway; skip the work). */
    if (!g_vm_multithreaded && __builtin_expect(live >= g_gc_threshold, 0))
        gc_collect_cycles();
}

/* ---- Collection universe: pointer -> node-index hash + node arrays ----
 * Node kinds: values (containers/fns), envs, and bytecode chunks. Chunks
 * are on the cycle when a fn's chunk parks a recycled call env whose
 * owned parent ref points back into the fn's captured env
 * (fn -> chunk -> env_cache -> parent -> env -> fn). */
#define GC_KIND_VAL   0
#define GC_KIND_ENV   1
#define GC_KIND_CHUNK 2
typedef struct {
    void    **objs;
    uint8_t  *kind;
    int32_t  *internal;
    int32_t  *pinned;    /* refs held by the collector's own seed pins
                          * (exit-time snapshot of global bindings) */
    uint8_t  *mark;
    int       count, cap;
    int      *table;     /* open addressing, holds node index or -1 */
    int       mask;      /* table size - 1 (power of two) */
} GcU;

static uint32_t gc_ptr_hash(void *p) {
    uintptr_t x = (uintptr_t)p;
    x ^= x >> 16; x *= 0x45d9f3bU; x ^= x >> 13;
    return (uint32_t)x;
}

static int gcu_find(GcU *u, void *obj) {
    uint32_t i = gc_ptr_hash(obj) & u->mask;
    while (u->table[i] != -1) {
        if (u->objs[u->table[i]] == obj) return u->table[i];
        i = (i + 1) & u->mask;
    }
    return -1;
}

static void gcu_rehash(GcU *u, int new_size) {
    free(u->table);
    u->table = xmalloc_array(new_size, sizeof(int));
    for (int i = 0; i < new_size; i++) u->table[i] = -1;
    u->mask = new_size - 1;
    for (int n = 0; n < u->count; n++) {
        uint32_t i = gc_ptr_hash(u->objs[n]) & u->mask;
        while (u->table[i] != -1) i = (i + 1) & u->mask;
        u->table[i] = n;
    }
}

/* Add obj to U if absent. Returns 1 when newly added. */
static int gcu_add(GcU *u, void *obj, int kind) {
    if (gcu_find(u, obj) >= 0) return 0;
    if (u->count >= u->cap) {
        u->cap = u->cap ? u->cap * 2 : 256;
        u->objs     = xrealloc_array(u->objs, u->cap, sizeof(void *));
        u->kind     = xrealloc_array(u->kind, u->cap, sizeof(uint8_t));
        u->internal = xrealloc_array(u->internal, u->cap, sizeof(int32_t));
        u->pinned   = xrealloc_array(u->pinned, u->cap, sizeof(int32_t));
        u->mark     = xrealloc_array(u->mark, u->cap, sizeof(uint8_t));
    }
    int n = u->count++;
    u->objs[n] = obj;
    u->kind[n] = (uint8_t)kind;
    u->internal[n] = 0;
    u->pinned[n] = 0;
    u->mark[n] = 0;
    if (u->count * 4 > (u->mask + 1) * 3)
        gcu_rehash(u, (u->mask + 1) * 2);
    uint32_t i = gc_ptr_hash(obj) & u->mask;
    while (u->table[i] != -1) i = (i + 1) & u->mask;
    u->table[i] = n;
    return 1;
}

/* Only these value types can hold references (and so participate in an
 * env-involving cycle). Everything else is a leaf: dropped by ordinary
 * decrefs when its garbage owner is cleared. */
static int gc_value_is_node(Value *v) {
    return v && !v->arena &&
           (v->type == VAL_LIST || v->type == VAL_DICT || v->type == VAL_FN);
}

/* An env child edge worth traversing: real, heap, and not the global
 * stop node. */
static int gc_env_is_node(Env *e) {
    return e && e->heap_allocated && e != g_global_env;
}

/* Invoke BODY for every OWNED edge out of node n. Each edge reported
 * here corresponds to exactly one counted reference; reporting anything
 * uncounted here would corrupt the root derivation (the abort check
 * below catches that as internal > refcount). Chunk edges: a VAL_FN owns
 * one ref on its compiled chunk (taken in OP_CLOSURE); a chunk owns one
 * creator ref per nested functions[] entry and one ref on its parked
 * env_cache. Chunk constants are literal leaves (never containers/fns)
 * and are not traversed. */
#define GC_FOR_EACH_CHILD(u, n, CHILD_OBJ, CHILD_KIND, BODY)                  \
    do {                                                                      \
        if ((u)->kind[n] == GC_KIND_ENV) {                                    \
            Env *_e = (Env *)(u)->objs[n];                                    \
            if (gc_env_is_node(_e->parent)) {                                 \
                void *CHILD_OBJ = _e->parent;                                 \
                int CHILD_KIND = GC_KIND_ENV; BODY                            \
            }                                                                 \
            for (int _i = 0; _i < _e->count; _i++) {                          \
                EigsSlot _s = _e->values[_i];                                 \
                if (slot_is_ptr(_s)) {                                        \
                    Value *_v = slot_as_ptr(_s);                              \
                    if (gc_value_is_node(_v)) {                               \
                        void *CHILD_OBJ = _v;                                 \
                        int CHILD_KIND = GC_KIND_VAL; BODY                    \
                    }                                                         \
                }                                                             \
            }                                                                 \
        } else if ((u)->kind[n] == GC_KIND_CHUNK) {                           \
            EigsChunk *_c = (EigsChunk *)(u)->objs[n];                        \
            for (int _i = 0; _i < _c->fn_count; _i++) {                       \
                if (_c->functions[_i]) {                                      \
                    void *CHILD_OBJ = _c->functions[_i];                      \
                    int CHILD_KIND = GC_KIND_CHUNK; BODY                      \
                }                                                             \
            }                                                                 \
            if (gc_env_is_node(_c->env_cache)) {                              \
                void *CHILD_OBJ = _c->env_cache;                              \
                int CHILD_KIND = GC_KIND_ENV; BODY                            \
            }                                                                 \
        } else {                                                              \
            Value *_v = (Value *)(u)->objs[n];                                \
            switch (_v->type) {                                               \
            case VAL_FN:                                                      \
                if (gc_env_is_node(_v->data.fn.closure)) {                    \
                    void *CHILD_OBJ = _v->data.fn.closure;                    \
                    int CHILD_KIND = GC_KIND_ENV; BODY                        \
                }                                                             \
                if (_v->data.fn.body_count == -1 && _v->data.fn.body) {       \
                    void *CHILD_OBJ = (EigsChunk *)_v->data.fn.body;          \
                    int CHILD_KIND = GC_KIND_CHUNK; BODY                      \
                }                                                             \
                break;                                                        \
            case VAL_LIST:                                                    \
                for (int _i = 0; _i < _v->data.list.count; _i++) {            \
                    Value *_c2 = _v->data.list.items[_i];                     \
                    if (gc_value_is_node(_c2)) {                              \
                        void *CHILD_OBJ = _c2;                                \
                        int CHILD_KIND = GC_KIND_VAL; BODY                    \
                    }                                                         \
                }                                                             \
                break;                                                        \
            case VAL_DICT:                                                    \
                for (int _i = 0; _i < _v->data.dict.count; _i++) {            \
                    Value *_c2 = _v->data.dict.vals[_i];                      \
                    if (gc_value_is_node(_c2)) {                              \
                        void *CHILD_OBJ = _c2;                                \
                        int CHILD_KIND = GC_KIND_VAL; BODY                    \
                    }                                                         \
                }                                                             \
                break;                                                        \
            default: break;                                                   \
            }                                                                 \
        }                                                                     \
    } while (0)

/* Clear every outgoing edge of a garbage node (exactly the edges
 * GC_FOR_EACH_CHILD reports, plus leaf refs) so the cycle is broken;
 * the node itself stays allocated (pinned) until the unpin pass. */
static void gc_clear_node(void *obj, int kind) {
    if (kind == GC_KIND_ENV) {
        Env *e = obj;
        for (int i = 0; i < e->count; i++) {
            EigsSlot s = e->values[i];
            e->values[i] = slot_null();
            slot_decref(s);
        }
        e->count = 0;
        e->binding_version++;
        if (++e->hash.generation == 0) {
            memset(e->hash.generations, 0,
                   (e->hash.mask + 1) * sizeof(uint32_t));
            e->hash.generation = 1;
        }
        Env *p = e->parent;
        e->parent = NULL;
        env_decref(p);
    } else if (kind == GC_KIND_CHUNK) {
        EigsChunk *c = obj;
        for (int i = 0; i < c->fn_count; i++) {
            EigsChunk *fc = c->functions[i];
            c->functions[i] = NULL;     /* chunk_decref(NULL) no-ops later */
            chunk_decref(fc);
        }
        Env *cached = c->env_cache;
        c->env_cache = NULL;
        env_decref(cached);
    } else {
        Value *v = obj;
        switch (v->type) {
        case VAL_FN: {
            Env *clo = v->data.fn.closure;
            v->data.fn.closure = NULL;
            env_decref(clo);
            break;
        }
        case VAL_LIST:
            for (int i = 0; i < v->data.list.count; i++)
                val_decref(v->data.list.items[i]);
            v->data.list.count = 0;
            break;
        case VAL_DICT:
            for (int i = 0; i < v->data.dict.count; i++)
                val_decref(v->data.dict.vals[i]);
            v->data.dict.count = 0;
            break;
        default: break;
        }
    }
}

/* Core collection. seeds (may be NULL) are extra value-node roots the
 * caller holds exactly one pinning ref on apiece (exit-time snapshot of
 * the global scope); their pins are accounted so a seed kept alive only
 * by its pin + in-universe edges still counts as garbage. */
static void gc_collect_impl(Value **seeds, int seed_count) {
    if (g_in_gc || g_vm_multithreaded) return;
    if (!g_gc_envs && seed_count == 0) {
        g_gc_threshold = GC_THRESHOLD_MIN;
        return;
    }
    g_in_gc = 1;

    GcU u = {0};
    u.table = xmalloc_array(512, sizeof(int));
    for (int i = 0; i < 512; i++) u.table[i] = -1;
    u.mask = 511;

    /* 1. Build U: registered envs + everything reachable via owned edges.
     * u.count grows during the scan — the node array is the worklist. */
    for (Env *e = g_gc_envs; e; e = e->gc_next)
        gcu_add(&u, e, GC_KIND_ENV);
    for (int s = 0; s < seed_count; s++) {
        gcu_add(&u, seeds[s], GC_KIND_VAL);
        u.pinned[gcu_find(&u, seeds[s])]++;
    }
    for (int n = 0; n < u.count; n++) {
        GC_FOR_EACH_CHILD(&u, n, child, child_kind, {
            gcu_add(&u, child, child_kind);
        });
    }

    /* 2. Internal reference counts (edges from inside U). */
    for (int n = 0; n < u.count; n++) {
        GC_FOR_EACH_CHILD(&u, n, child, child_kind, {
            (void)child_kind;
            int ci = gcu_find(&u, child);
            if (ci >= 0) u.internal[ci]++;
        });
    }

    /* 3. Roots: refcount > internal + collector pins. Sanity: accounted
     * refs exceeding the refcount means an uncounted edge got traversed —
     * abort the whole collection (leak, never free). */
    int *stack = xmalloc_array(u.count ? u.count : 1, sizeof(int));
    int sp = 0, bad = 0;
    for (int n = 0; n < u.count; n++) {
        int rc = u.kind[n] == GC_KIND_ENV   ? ((Env *)u.objs[n])->env_refcount
               : u.kind[n] == GC_KIND_CHUNK ? ((EigsChunk *)u.objs[n])->refcount
                                            : ((Value *)u.objs[n])->refcount;
        int accounted = u.internal[n] + u.pinned[n];
        if (accounted > rc) { bad = 1; break; }
        if (rc > accounted) {
            u.mark[n] = 1;
            stack[sp++] = n;
        }
    }
    if (bad) {
        if (getenv("EIGS_GC_DEBUG"))
            fprintf(stderr, "[gc] accounting mismatch — collection aborted\n");
        free(stack);
        free(u.table); free(u.objs); free(u.kind);
        free(u.internal); free(u.pinned); free(u.mark);
        g_gc_threshold = g_gc_captured_live * 2;
        if (g_gc_threshold < GC_THRESHOLD_MIN) g_gc_threshold = GC_THRESHOLD_MIN;
        g_in_gc = 0;
        return;
    }

    /* 4. Mark everything reachable from the roots within U. */
    while (sp > 0) {
        int n = stack[--sp];
        GC_FOR_EACH_CHILD(&u, n, child, child_kind, {
            (void)child_kind;
            int ci = gcu_find(&u, child);
            if (ci >= 0 && !u.mark[ci]) {
                u.mark[ci] = 1;
                stack[sp++] = ci;
            }
        });
    }
    free(stack);

    /* 5-7. Unmarked nodes are cyclic garbage: pin, clear edges, unpin.
     * Single-threaded by construction, so plain ++ pins are fine. */
    int garbage = 0;
    for (int n = 0; n < u.count; n++) {
        if (u.mark[n]) continue;
        garbage++;
        if      (u.kind[n] == GC_KIND_ENV)   ((Env *)u.objs[n])->env_refcount++;
        else if (u.kind[n] == GC_KIND_CHUNK) ((EigsChunk *)u.objs[n])->refcount++;
        else                                 ((Value *)u.objs[n])->refcount++;
    }
    if (garbage) {
        for (int n = 0; n < u.count; n++)
            if (!u.mark[n]) gc_clear_node(u.objs[n], u.kind[n]);
        for (int n = 0; n < u.count; n++) {
            if (u.mark[n]) continue;
            if      (u.kind[n] == GC_KIND_ENV)   env_decref((Env *)u.objs[n]);
            else if (u.kind[n] == GC_KIND_CHUNK) chunk_decref((EigsChunk *)u.objs[n]);
            else                                 val_decref((Value *)u.objs[n]);
        }
    }
    if (getenv("EIGS_GC_DEBUG"))
        fprintf(stderr, "[gc] universe %d, freed %d, live captured %d\n",
                u.count, garbage, g_gc_captured_live);

    free(u.table); free(u.objs); free(u.kind);
    free(u.internal); free(u.pinned); free(u.mark);
    g_gc_threshold = g_gc_captured_live * 2;
    if (g_gc_threshold < GC_THRESHOLD_MIN) g_gc_threshold = GC_THRESHOLD_MIN;
    g_in_gc = 0;
}

/* #307: Bacon-Rajan "possible root" registration. Called from val_decref /
 * slot_decref when a LIST/DICT lost a ref but stayed alive — it may now be the
 * root of a garbage value cycle that nothing else would reclaim (the env
 * registry only covers closure cycles; the exit snapshot only covers
 * global-rooted ones). Park it on the per-state value-candidate buffer with one
 * pin so it survives until the next collection, which decides via the same
 * edge-accounting whether it (and its cycle) is actually garbage.
 *
 * Gated exactly like env_mark_captured: off when GC is disabled, mid-collection
 * (the collector's own decrefs must not re-register), or multithreaded (the
 * buffer is single-threaded-only — MT value cycles are rare and swept at exit
 * via the global snapshot; this keeps the hot decref lock-free). */
void gc_note_possible_root(Value *v) {
    if (!g_gc_enabled || g_in_gc || g_vm_multithreaded || v->gc_buffered)
        return;
    v->gc_buffered = 1;
    v->refcount++;   /* buffer pin — single-threaded here, so plain ++ */
    if (g_gc_val_count >= g_gc_val_cap) {
        g_gc_val_cap = g_gc_val_cap ? g_gc_val_cap * 2 : 64;
        g_gc_val_buf = xrealloc_array(g_gc_val_buf, g_gc_val_cap, sizeof(Value *));
    }
    g_gc_val_buf[g_gc_val_count++] = v;
    if (__builtin_expect(g_gc_val_count >= GC_VAL_THRESHOLD, 0))
        gc_collect_cycles();
}

void gc_collect_cycles(void) {
    if (g_in_gc || g_vm_multithreaded) return;
    /* Feed the value-candidate buffer in as pinned seeds (each holds exactly
     * one buffer pin, accounted like the exit snapshot's), alongside the
     * captured-env registry. */
    gc_collect_impl(g_gc_val_buf, g_gc_val_count);
    /* Drain the buffer: clear the buffered flags, then drop each pin. The
     * collection has already broken any garbage cycle's internal edges, so the
     * final pin drop frees the garbage; live candidates keep their other refs.
     * Re-arm g_in_gc across the drain so the child decrefs while freeing don't
     * re-register (which would realloc the array we're walking). */
    if (g_gc_val_count) {
        int n = g_gc_val_count;
        g_in_gc = 1;
        for (int i = 0; i < n; i++) g_gc_val_buf[i]->gc_buffered = 0;
        g_gc_val_count = 0;
        for (int i = 0; i < n; i++) val_decref(g_gc_val_buf[i]);
        g_in_gc = 0;
    }
}

/* ---- Module cache (Phase 0a) ----------------------------------------
 * Linear scan; modules-per-program is small (single digits to dozens).
 * Cache owns: strdup'd path, one ref on the dict, one ref on mod_env.
 * Multi-thread: not guarded — `import` from inside a spawned thread
 * isn't a documented use case, and the population pattern is "main
 * thread imports at startup". If that changes, wrap in a mutex. */
int eigs_module_cache_get(const char *abs_path, Value **out_dict) {
    if (out_dict) *out_dict = NULL;
    if (!abs_path || !eigs_current) return 0;
    EigsState *st = eigs_current->state;
    for (size_t i = 0; i < st->module_cache_count; i++) {
        if (strcmp(st->module_cache[i].path, abs_path) == 0) {
            if (out_dict) {
                *out_dict = st->module_cache[i].dict;
                val_incref(*out_dict);
            }
            return 1;
        }
    }
    return 0;
}

void eigs_module_cache_put(const char *abs_path, Value *dict, Env *env) {
    if (!abs_path || !dict || !eigs_current) return;
    EigsState *st = eigs_current->state;
    for (size_t i = 0; i < st->module_cache_count; i++) {
        if (strcmp(st->module_cache[i].path, abs_path) == 0) return;
    }
    if (st->module_cache_count == st->module_cache_cap) {
        size_t newcap = st->module_cache_cap ? st->module_cache_cap * 2 : 8;
        st->module_cache = xrealloc_array(st->module_cache, newcap,
                                          sizeof(EigsModuleCacheEntry));
        st->module_cache_cap = newcap;
    }
    EigsModuleCacheEntry *e = &st->module_cache[st->module_cache_count++];
    e->path = strdup(abs_path);
    e->dict = dict;
    val_incref(dict);
    e->env = env;
    if (env) env_incref(env);
}

void eigs_module_cache_clear(void) {
    if (!eigs_current) return;
    EigsState *st = eigs_current->state;
    for (size_t i = 0; i < st->module_cache_count; i++) {
        free(st->module_cache[i].path);
        val_decref(st->module_cache[i].dict);
        if (st->module_cache[i].env) env_decref(st->module_cache[i].env);
    }
    st->module_cache_count = 0;
    /* Keep the array allocated — eigs_state_destroy frees it. The cache
     * is cleared at gc_collect_at_exit; the state outlives that call. */
}

/* Exit-time collection. Pure value->value cycles bound at global scope
 * (e.g. a list appended to itself) are unreachable from the captured-env
 * registry, so snapshot the global scope's container values first (one
 * pinning ref each), drop the global bindings, collect with the pins
 * accounted, then release the pins — a snapshot value kept alive only by
 * its own cycle dies here; anything else just loses our temporary ref. */
void gc_collect_at_exit(Env *global) {
    /* Drop module-cache refs first: a module's dict + env can hold
     * closures that close over global bindings, so releasing the cache
     * before snapshotting globals exposes those for collection. */
    eigs_module_cache_clear();
    /* #307: disable the possible-root hook for the rest of teardown, THEN flush
     * the value-candidate buffer (and release its pins). Disabling first is
     * essential: the env_clear(global) below drops every global slot, and a
     * dropped LIST/DICT would otherwise re-register into the buffer *after* this
     * drain — with nothing left to release those new pins, leaking the whole
     * global container set. gc_collect_cycles/gc_collect_impl don't consult
     * gc_enabled (only env_mark_captured and the hook do), so the drain and the
     * snapshot collection below still run. Live globally-rooted candidates
     * survive this drain (reclaimed by the snapshot pass); purely-local cycles
     * still buffered at exit are reclaimed here. */
    g_gc_enabled = 0;
    gc_collect_cycles();
    Value **seeds = NULL;
    int seed_count = 0, seed_cap = 0;
    if (global && !g_vm_multithreaded) {
        for (int i = 0; i < global->count; i++) {
            EigsSlot s = global->values[i];
            if (!slot_is_ptr(s)) continue;
            Value *v = slot_as_ptr(s);
            if (!gc_value_is_node(v)) continue;
            if (seed_count >= seed_cap) {
                seed_cap = seed_cap ? seed_cap * 2 : 64;
                seeds = xrealloc_array(seeds, seed_cap, sizeof(Value *));
            }
            val_incref(v);
            seeds[seed_count++] = v;
        }
    }
    if (global) env_clear(global);
    gc_collect_impl(seeds, seed_count);
    for (int i = 0; i < seed_count; i++)
        val_decref(seeds[i]);
    free(seeds);
}

void env_reserve_slots(Env *env, int total) {
    if (!env || total <= env->count) return;
    /* Grow capacity if needed. Mirrors env_set_local_hashed's grow path
     * for heap_allocated envs. Call-time envs are always heap-allocated
     * (env_new sets heap_allocated=1). Reserve ENV_LOOP_BIND_HEADROOM extra
     * CAPACITY (count still ends at `total`) so the runtime loop bindings
     * don't realloc values[] out from under a live JIT %r12 cache (#291). */
    int want_cap = total + ENV_LOOP_BIND_HEADROOM;
    if (want_cap > env->capacity) {
        int new_cap = env->capacity ? env->capacity : ENV_INIT_CAP;
        while (new_cap < want_cap) new_cap *= 2;
        size_t nsz = new_cap * sizeof(char *);
        size_t vsz = new_cap * sizeof(EigsSlot);
        if (env->heap_allocated) {
            env->names  = realloc(env->names,  nsz);
            env->values = realloc(env->values, vsz);
            env->assign_counts = realloc(env->assign_counts, new_cap * sizeof(int));
            if (!env->names || !env->values || !env->assign_counts) {
                fprintf(stderr, "Out of memory growing env\n");
                exit(1);
            }
        } else {
            char **nn  = arena_alloc(nsz);
            EigsSlot *nv = arena_alloc(vsz);
            memcpy(nn, env->names,  env->count * sizeof(char *));
            memcpy(nv, env->values, env->count * sizeof(EigsSlot));
            env->names  = nn;
            env->values = nv;
        }
        env->capacity = new_cap;
    }
    /* Zero new slots: names NULL, values immediate-null, assign_counts 0.
     * Non-captured local slots aren't hash-inserted — they're addressed
     * purely by slot index via OP_GET_LOCAL/OP_SET_LOCAL. */
    for (int i = env->count; i < total; i++) {
        env->names[i]  = NULL;
        env->values[i] = slot_null();
        if (env->assign_counts) env->assign_counts[i] = 0;
    }
    env->count = total;
}

void env_clear(Env *env) {
    if (!env) return;
    for (int i = 0; i < env->count; i++) {
        slot_decref(env->values[i]);
    }
    env->count = 0;
    env->binding_version++;
    if (++env->hash.generation == 0) {
        memset(env->hash.generations, 0,
               (env->hash.mask + 1) * sizeof(uint32_t));
        env->hash.generation = 1;
    }
}

Value* env_get_hashed(Env *env, const char *name, uint32_t h) {
    if (h == 0) h = env_hash_name(name);
    Env *e = env;
    while (e) {
        int idx = env_hash_find(&e->hash, name, h, e->names);
        if (idx >= 0) {
            EigsSlot s = e->values[idx];
            if (slot_is_ptr(s)) return slot_as_ptr(s);
            /* immediate — materialize a borrowed Value* in the env slot
             * itself so the returned pointer's lifetime matches the slot.
             * This mirrors the legacy semantics where env owned the ref. */
            Value *v = slot_to_value(s);
            slot_decref(e->values[idx]);  /* drop immediate (no-op) */
            e->values[idx] = slot_from_heap(v);  /* env now owns v */
            return v;
        }
        e = e->parent;
    }
    return NULL;
}

Value* env_get_local_hashed(Env *env, const char *name, uint32_t h) {
    if (!env) return NULL;
    if (h == 0) h = env_hash_name(name);
    int idx = env_hash_find(&env->hash, name, h, env->names);
    if (idx >= 0) {
        EigsSlot s = env->values[idx];
        if (slot_is_ptr(s)) return slot_as_ptr(s);
        Value *v = slot_to_value(s);
        slot_decref(env->values[idx]);
        env->values[idx] = slot_from_heap(v);
        return v;
    }
    return NULL;
}

Value* env_get(Env *env, const char *name) {
    return env_get_hashed(env, name, env_hash_name(name));
}

/* ================================================================
 * HANDLE TABLE — opaque pointer indirection for Store/Thread/Channel
 * Table + lock live on EigsState (see eigenscript.h).
 * ================================================================ */

int handle_register(void *ptr, HandleType type) {
    if (!eigs_current) return -1;
    EigsState *st = eigs_current->state;
    pthread_mutex_lock(&st->handle_mutex);
    for (int i = 0; i < HANDLE_TABLE_SIZE; i++) {
        int idx = (st->handle_next + i) % HANDLE_TABLE_SIZE;
        if (idx == 0) continue;
        if (st->handle_table[idx].ptr == NULL) {
            st->handle_table[idx].ptr = ptr;
            st->handle_table[idx].type = type;
            st->handle_next = (idx + 1) % HANDLE_TABLE_SIZE;
            pthread_mutex_unlock(&st->handle_mutex);
            return idx;
        }
    }
    pthread_mutex_unlock(&st->handle_mutex);
    fprintf(stderr, "Error: handle table full\n");
    return -1;
}

void* handle_lookup(int id, HandleType type) {
    if (!eigs_current) return NULL;
    if (id <= 0 || id >= HANDLE_TABLE_SIZE) return NULL;
    EigsState *st = eigs_current->state;
    pthread_mutex_lock(&st->handle_mutex);
    void *ptr = NULL;
    if (st->handle_table[id].ptr != NULL && st->handle_table[id].type == type)
        ptr = st->handle_table[id].ptr;
    pthread_mutex_unlock(&st->handle_mutex);
    return ptr;
}

void handle_release(int id) {
    if (!eigs_current) return;
    if (id <= 0 || id >= HANDLE_TABLE_SIZE) return;
    EigsState *st = eigs_current->state;
    pthread_mutex_lock(&st->handle_mutex);
    st->handle_table[id].ptr = NULL;
    pthread_mutex_unlock(&st->handle_mutex);
}
