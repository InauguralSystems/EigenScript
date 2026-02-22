#ifndef EIGENSCRIPT_H
#define EIGENSCRIPT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <stdint.h>
#include <setjmp.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <signal.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pthread.h>
#include <time.h>
#include <libpq-fe.h>

#define MAX_TOKENS      65536
#define MAX_INDENT      64
#define MAX_VARS        512
#define MAX_ROUTES      256
#define MAX_STMTS       4096
#define MAX_LIST        1024
#define MAX_STR         65536
#define MAX_BODY        1048576
#define MAX_HEADER      8192

typedef enum {
    TOK_NUM, TOK_STR, TOK_IDENT,
    TOK_IS, TOK_OF, TOK_DEFINE, TOK_AS,
    TOK_IF, TOK_ELSE, TOK_LOOP, TOK_WHILE,
    TOK_RETURN, TOK_AND, TOK_OR, TOK_NOT,
    TOK_FOR, TOK_IN, TOK_NULL,
    TOK_WHAT, TOK_WHO, TOK_WHEN, TOK_WHERE, TOK_WHY, TOK_HOW,
    TOK_CONVERGED, TOK_STABLE, TOK_IMPROVING, TOK_OSCILLATING, TOK_DIVERGING, TOK_EQUILIBRIUM,
    TOK_PLUS, TOK_MINUS, TOK_STAR, TOK_SLASH, TOK_PERCENT,
    TOK_LT, TOK_GT, TOK_LE, TOK_GE, TOK_EQ, TOK_NE, TOK_ASSIGN,
    TOK_LPAREN, TOK_RPAREN, TOK_LBRACKET, TOK_RBRACKET,
    TOK_COMMA, TOK_COLON, TOK_DOT,
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

typedef enum {
    AST_NUM, AST_STR, AST_IDENT, AST_NULL,
    AST_BINOP, AST_UNARY, AST_ASSIGN, AST_RELATION,
    AST_IF, AST_LOOP, AST_FUNC, AST_RETURN,
    AST_BLOCK, AST_LIST, AST_INDEX, AST_LISTCOMP,
    AST_PROGRAM,
    AST_INTERROGATE, AST_PREDICATE
} ASTType;

typedef struct ASTNode ASTNode;

struct ASTNode {
    ASTType type;
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
        struct { char *name; char *param; ASTNode **body; int body_count; } func;
        struct { ASTNode *expr; } ret;
        struct { ASTNode **stmts; int count; } block;
        struct { ASTNode **elems; int count; } list;
        struct { ASTNode *target; ASTNode *index; } index;
        struct { ASTNode *expr; char *var; ASTNode *iter; ASTNode *filter; } listcomp;
        struct { ASTNode **stmts; int count; } program;
        struct { int kind; ASTNode *expr; } interrogate;
        struct { int kind; } predicate;
    } data;
};

typedef enum {
    VAL_NUM, VAL_STR, VAL_LIST, VAL_FN, VAL_BUILTIN, VAL_NULL
} ValType;

typedef struct Value Value;
typedef Value* (*BuiltinFn)(Value* arg);

typedef struct Env Env;

struct Env {
    char *names[MAX_VARS];
    Value *values[MAX_VARS];
    int count;
    Env *parent;
};

struct Value {
    ValType type;
    union {
        double num;
        char *str;
        struct { Value **items; int count; int capacity; } list;
        struct { char *name; char *param; ASTNode **body; int body_count; Env *closure; } fn;
        BuiltinFn builtin;
    } data;
    double entropy;
    double dH;
    double last_entropy;
    int obs_age;
    double prev_dH;
};

typedef struct {
    char *method;
    char *path;
    char *kind;
    char *payload;
} Route;

typedef struct {
    Route routes[MAX_ROUTES];
    int route_count;
    char *static_prefix;
    char *static_dir;
    Env *global_env;
    char *request_body;
    char *session_id;
    char *request_headers;
    int early_bind_fd;
} Server;

Value* make_num(double n);
Value* make_str(const char *s);
Value* make_null(void);
Value* make_list(int capacity);
Value* make_fn(const char *name, const char *param, ASTNode **body, int body_count, Env *closure);
Value* make_builtin(BuiltinFn fn);
void list_append(Value *list, Value *item);

Env* env_new(Env *parent);
void env_set(Env *env, const char *name, Value *val);
Value* env_get(Env *env, const char *name);
void env_set_local(Env *env, const char *name, Value *val);

TokenList tokenize(const char *source);
ASTNode* parse(TokenList *tl);
Value* eval_node(ASTNode *node, Env *env);
Value* eval_block(ASTNode **stmts, int count, Env *env);

int is_truthy(Value *v);
char* value_to_string(Value *v);

void register_builtins(Env *env);
void http_serve_blocking(int port);

#define MAX_LAYERS 8
#define MAX_SEQ_LEN 128
#define VOCAB_SIZE 256
#define MAX_D_MODEL 128
#define MAX_D_FF 512

typedef struct {
    int vocab_size;
    int d_model;
    int n_heads;
    int n_layers;
    int d_ff;
    int max_seq_len;
} ModelConfig;

typedef struct {
    double *w_q;
    double *w_k;
    double *w_v;
    double *w_o;
    double *w_ff1;
    double *w_ff2;
    double *ln1_gamma;
    double *ln1_beta;
    double *ln2_gamma;
    double *ln2_beta;
} TransformerLayer;

typedef struct {
    ModelConfig config;
    double *token_embeddings;
    double *output_proj;
    TransformerLayer layers[MAX_LAYERS];
    int loaded;
} TransformerModel;

typedef struct {
    double *layer_inputs;
    double *norm1_outputs;
    double *norm2_outputs;
    double *attn_probs;
    double *ffn_pre_act;
    double *post_attn_x;
    double *final_x;
    double *ln1_x_norm;
    double *ln1_std;
    double *ln2_x_norm;
    double *ln2_std;
    int seq_len;
} TrainingCache;

extern TransformerModel g_model;
extern PGconn *g_db_conn;
extern Server g_server;
extern jmp_buf g_return_buf;
extern Value *g_return_val;
extern int g_returning;
extern int g_model_age;
extern int g_training_samples;

#endif
