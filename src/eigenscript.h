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
#include <fcntl.h>
#include <time.h>
#include <poll.h>
#include <regex.h>

/* ---- Language limits ---- */

#define MAX_TOKENS      65536
#define MAX_INDENT      64
#define MAX_VARS        512   /* lint-only; Env uses dynamic arrays */
#define ENV_INIT_CAP    16
#define MAX_STMTS       4096
#define MAX_LIST        1024

/* ---- Tokenizer ---- */

typedef enum {
    TOK_NUM, TOK_STR, TOK_IDENT,
    TOK_IS, TOK_OF, TOK_DEFINE, TOK_AS,
    TOK_IF, TOK_ELSE, TOK_ELIF, TOK_LOOP, TOK_WHILE,
    TOK_RETURN, TOK_AND, TOK_OR, TOK_NOT,
    TOK_FOR, TOK_IN, TOK_NULL,
    TOK_WHAT, TOK_WHO, TOK_WHEN, TOK_WHERE, TOK_WHY, TOK_HOW,
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
    AST_MATCH, AST_LAMBDA, AST_UNOBSERVED, AST_INDEX_ASSIGN
} ASTType;

typedef struct ASTNode ASTNode;
typedef struct Env Env;

struct ASTNode {
    ASTType type;
    int line;
    int col;    /* 0-based column offset */
    uint32_t name_hash; /* cached hash for identifier/name-bearing nodes */
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
        struct { char *name; char **params; int param_count; ASTNode **body; int body_count; } func;
        struct { ASTNode *expr; } ret;
        struct { ASTNode **stmts; int count; } block;
        struct { ASTNode **elems; int count; } list;
        struct { ASTNode *target; ASTNode *index; } index;
        struct { ASTNode *expr; char *var; ASTNode *iter; ASTNode *filter; } listcomp;
        struct { char *var; ASTNode *iter; ASTNode **body; int body_count; } forloop;
        struct { ASTNode **stmts; int count; } program;
        struct { int kind; ASTNode *expr; } interrogate;
        struct { int kind; } predicate;
        struct { ASTNode **try_body; int try_count; char *err_name; ASTNode **catch_body; int catch_count; } trycatch;
        struct { ASTNode **keys; ASTNode **vals; int count; } dict;
        struct { ASTNode *target; char *key; } dot;
        struct { ASTNode *target; char *key; ASTNode *expr; } dot_assign;
        struct { ASTNode *target; ASTNode *index; ASTNode *expr; } index_assign;
        struct { char *module_name; } import;
        struct { ASTNode *expr; ASTNode **patterns; ASTNode ***bodies; int *body_counts; int case_count; } match;
        struct { char **params; int param_count; ASTNode *body; } lambda;
    } data;
};

/* ---- Value types ---- */

typedef enum {
    VAL_NUM, VAL_STR, VAL_LIST, VAL_FN, VAL_BUILTIN, VAL_NULL, VAL_JSON_RAW, VAL_DICT, VAL_BUFFER, VAL_TEXT_BUILDER
} ValType;

typedef struct Value Value;
typedef Value* (*BuiltinFn)(Value* arg);

/* Hash index for O(1) variable lookup.  Sits alongside the linear
 * names/values arrays so iteration order and env_free are unchanged. */
#define ENV_HASH_INIT_CAP 32  /* must be power of 2 */

typedef struct {
    uint32_t *hashes;   /* hash of name (0 = empty slot) */
    int      *indices;  /* index into Env::names/values, or -1 */
    int       mask;     /* capacity - 1 (for & masking) */
} EnvHash;

struct Env {
    char **names;
    Value **values;
    int count;
    int capacity;
    Env *parent;
    int heap_allocated;
    int captured;
    int env_refcount;   /* number of closures referencing this env */
    EnvHash hash;
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
        struct { double *data; int count; } buffer;
        struct { char *data; size_t len; size_t cap; int parts; } text_builder;
    } data;
    double entropy;
    double dH;
    double last_entropy;
    int obs_age;
    double prev_dH;
    int refcount;       /* reference counting GC: 0 = unmanaged, >0 = tracked */
    unsigned char arena; /* 1 if arena-allocated (don't free) */
    unsigned char dirty; /* 1 = observer entropy needs recomputation */
};

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

extern __thread Arena g_arena;

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
Value* make_text_builder(void);
Value* make_fn(const char *name, char **params, int param_count, ASTNode **body, int body_count, Env *closure);
Value* make_builtin(BuiltinFn fn);
Value* make_dict(int capacity);
void dict_set(Value *dict, const char *key, Value *val);
Value* dict_get(Value *dict, const char *key);
void list_append(Value *list, Value *item);
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

static inline void val_incref(Value *v) {
    if (v && !v->arena) __atomic_add_fetch(&v->refcount, 1, __ATOMIC_RELAXED);
}
static inline void val_decref(Value *v) {
    if (v && !v->arena) {
        if (__atomic_sub_fetch(&v->refcount, 1, __ATOMIC_ACQ_REL) <= 0) {
            free_value(v);
        }
    }
}

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
void dict_set_hashed(Value *dict, const char *key, uint32_t h, Value *val);
Value* dict_get_hashed(Value *dict, const char *key, uint32_t h);
void env_free(Env *env);
void env_clear(Env *env);

/* ---- Parser / Evaluator ---- */

TokenList tokenize(const char *source);
void free_tokenlist(TokenList *tl);
ASTNode* parse(TokenList *tl);
ASTNode* clone_ast(ASTNode *node);
ASTNode** clone_ast_array(ASTNode **nodes, int count);
void free_ast(ASTNode *node);
Value* eval_node(ASTNode *node, Env *env);
Value* eval_block(ASTNode **stmts, int count, Env *env);
int eval_result_is_owned(ASTNode *node);

int is_truthy(Value *v);
char* value_to_string(Value *v);
void observer_ensure_fresh(Value *v);
void eigs_json_escape_string(strbuf *out, const char *s);

/* ---- Registration ---- */

void register_builtins(Env *env);
void register_hash_builtins(Env *env);
void eigenscript_set_args(int argc, char **argv);
extern Env *g_global_env;
extern __thread Env *g_load_env;  /* scope for load_file; NULL = g_global_env */
extern __thread Env *g_builtin_call_env;  /* dynamic caller scope for env-aware builtins */

/* ---- Utilities used across modules ---- */

char* read_file_util(const char *path, long *out_size);
int resolve_eigenscript_file(const char *path, char *resolved, size_t resolved_cap);
Value* eigs_json_parse_value(const char *s, int *pos);

/* ---- Control flow (return statement) ---- */

extern __thread jmp_buf g_return_buf;
extern __thread Value *g_return_val;
extern __thread int g_returning;
extern __thread int g_parse_errors;
extern __thread char g_error_msg[4096];
extern __thread int g_has_error;
extern __thread int g_breaking;
extern __thread int g_continuing;
extern __thread Value *g_last_observer;
extern char g_script_dir[4096];
extern char g_exe_dir[4096];

/* ---- Observer thresholds (tunable via set_observer_thresholds) ---- */
extern __thread double g_obs_dh_zero;   /* |dH| < this → "zero change" (default 0.001) */
extern __thread double g_obs_dh_small;  /* |dH| < this → "small change" (default 0.01)  */
extern __thread double g_obs_h_low;     /* entropy < this → "low info"  (default 0.1)   */

/* ---- Cross-file functions for MODEL tensor builtins ---- */
/* When MODEL is enabled, these are defined in model_infer.c.
 * When disabled, eigenscript.c provides static stubs. */
#if EIGENSCRIPT_EXT_MODEL
void ne_softmax_buf(double *data, int64_t rows, int64_t cols);
void ne_matmul_buf(double *a, int64_t a_rows, int64_t a_cols,
                   double *b, int64_t b_cols, double *out);
Value* json_obj_get(Value *obj, const char *key);
#endif

/* ---- Handle table (opaque pointer indirection) ---- */
#define HANDLE_TABLE_SIZE 256

typedef enum {
    HANDLE_STORE,
    HANDLE_THREAD,
    HANDLE_CHANNEL
} HandleType;

int    handle_register(void *ptr, HandleType type);
void*  handle_lookup(int id, HandleType type);
void   handle_release(int id);

/* ---- EigenStore embedded database ---- */
void register_store_builtins(Env *env);

/* ---- Formatter & Linter ---- */
int eigenscript_fmt(const char *path, int write_mode);
int eigenscript_lint(const char *path);

#endif /* EIGENSCRIPT_H */
