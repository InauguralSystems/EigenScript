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

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <stdint.h>
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
#define MAX_VARS        512
#define MAX_STMTS       4096
#define MAX_LIST        1024
#define MAX_STR         65536
#define MAX_BODY        1048576
#define MAX_HEADER      8192

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
    TOK_PLUS, TOK_MINUS, TOK_STAR, TOK_SLASH, TOK_PERCENT,
    TOK_LT, TOK_GT, TOK_LE, TOK_GE, TOK_EQ, TOK_NE, TOK_ASSIGN,
    TOK_LPAREN, TOK_RPAREN, TOK_LBRACKET, TOK_RBRACKET,
    TOK_COMMA, TOK_COLON, TOK_DOT,
    TOK_LBRACE, TOK_RBRACE,
    TOK_PIPE, TOK_ARROW,
    TOK_NEWLINE, TOK_INDENT, TOK_DEDENT,
    TOK_EOF
} TokType;

typedef struct {
    TokType type;
    double num_val;
    char *str_val;
    int line;
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
    AST_MATCH, AST_LAMBDA
} ASTType;

typedef struct ASTNode ASTNode;

struct ASTNode {
    ASTType type;
    int line;
    union {
        double num;
        char *str;
        struct { char *name; } ident;
        struct { char op[4]; ASTNode *left; ASTNode *right; } binop;
        struct { char op[4]; ASTNode *operand; } unary;
        struct { char *name; ASTNode *expr; } assign;
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
        struct { char *module_name; } import;
        struct { ASTNode *expr; ASTNode **patterns; ASTNode ***bodies; int *body_counts; int case_count; } match;
        struct { char **params; int param_count; ASTNode *body; } lambda;
    } data;
};

/* ---- Value types ---- */

typedef enum {
    VAL_NUM, VAL_STR, VAL_LIST, VAL_FN, VAL_BUILTIN, VAL_NULL, VAL_JSON_RAW, VAL_DICT
} ValType;

typedef struct Value Value;
typedef Value* (*BuiltinFn)(Value* arg);

typedef struct Env Env;

struct Env {
    char *names[MAX_VARS];
    Value *values[MAX_VARS];
    int count;
    Env *parent;
    int heap_allocated;
    int captured;
};

struct Value {
    ValType type;
    union {
        double num;
        char *str;
        struct { Value **items; int count; int capacity; } list;
        struct { char *name; char **params; int param_count; ASTNode **body; int body_count; Env *closure; } fn;
        BuiltinFn builtin;
        struct { char **keys; Value **vals; int count; int capacity; } dict;
    } data;
    double entropy;
    double dH;
    double last_entropy;
    int obs_age;
    double prev_dH;
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
} Arena;

extern Arena g_arena;

/* ---- OOM-safe allocation wrappers ----
 * Abort with a diagnostic on allocation failure. Used by value constructors
 * and the arena allocator, where a NULL return would immediately crash. */
void* xmalloc(size_t size);
void* xcalloc(size_t nmemb, size_t size);
void* xrealloc(void *p, size_t size);
char* xstrdup(const char *s);

void arena_init(void);
void* arena_alloc(size_t size);
void arena_track_string(char *s);
void arena_mark_pos(void);
void arena_reset_to_mark(void);
void free_weight_val(Value *v);

/* ---- Value constructors ---- */

Value* make_num(double n);
Value* make_str(const char *s);
Value* make_null(void);
Value* make_list(int capacity);
Value* make_fn(const char *name, char **params, int param_count, ASTNode **body, int body_count, Env *closure);
Value* make_builtin(BuiltinFn fn);
Value* make_dict(int capacity);
void dict_set(Value *dict, const char *key, Value *val);
Value* dict_get(Value *dict, const char *key);
void list_append(Value *list, Value *item);

/* ---- Environment ---- */

Env* env_new(Env *parent);
void env_set(Env *env, const char *name, Value *val);
Value* env_get(Env *env, const char *name);
void env_set_local(Env *env, const char *name, Value *val);
void env_free(Env *env);

/* ---- Parser / Evaluator ---- */

TokenList tokenize(const char *source);
void free_tokenlist(TokenList *tl);
void free_value(Value *v);
ASTNode* parse(TokenList *tl);
Value* eval_node(ASTNode *node, Env *env);
Value* eval_block(ASTNode **stmts, int count, Env *env);

int is_truthy(Value *v);
char* value_to_string(Value *v);

/* ---- Registration ---- */

void register_builtins(Env *env);
void eigenscript_set_args(int argc, char **argv);
extern Env *g_global_env;

/* ---- Utilities used across modules ---- */

char* read_file_util(const char *path, long *out_size);
Value* eigs_json_parse_value(const char *s, int *pos);

/* ---- Control flow (return statement) ---- */

extern jmp_buf g_return_buf;
extern Value *g_return_val;
extern int g_returning;
extern int g_parse_errors;
extern char g_error_msg[4096];
extern int g_has_error;
extern int g_breaking;
extern int g_continuing;
extern char g_script_dir[4096];

/* ---- Cross-file functions for MODEL tensor builtins ---- */
/* When MODEL is enabled, these are defined in model_infer.c.
 * When disabled, eigenscript.c provides static stubs. */
#if EIGENSCRIPT_EXT_MODEL
void ne_softmax_buf(double *data, int64_t rows, int64_t cols);
void ne_matmul_buf(double *a, int64_t a_rows, int64_t a_cols,
                   double *b, int64_t b_cols, double *out);
Value* json_obj_get(Value *obj, const char *key);
#endif

#endif /* EIGENSCRIPT_H */
