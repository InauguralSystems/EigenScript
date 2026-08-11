/* Cross-TU declarations for the lint core/host split (#813). */

#ifndef EIGENSCRIPT_LINT_INTERNAL_H
#define EIGENSCRIPT_LINT_INTERNAL_H

#include "eigenscript.h"

#define MAX_LINT_WARNINGS 256

typedef struct {
    int line;
    int col;          /* 0-based column of the offending token (0 = unknown) */
    int len;          /* token length (0 = unknown -> whole-line LSP range) */
    char level[16];   /* "warning", "error", or "hint" */
    char code[8];     /* stable diagnostic code, e.g. "W001" */
    char message[256];
} LintWarning;

typedef struct {
    LintWarning warnings[MAX_LINT_WARNINGS];
    int warning_count;
    /* Variable tracking */
    char *assigns[MAX_VARS];
    int assign_lines[MAX_VARS];
    int assign_count;
    char *refs[MAX_VARS];
    int ref_count;
    /* Parameter tracking for current function */
    char *params[64];
    int param_count;
    /* Known builtins */
    const char **builtins;
    int builtin_count;
} LintContext;

/* Diagnostic helpers shared by lint.c and the host-only walkers. */
void lint_hint(LintContext *ctx, int line, const char *code,
               const char *fmt, ...);
void lint_error_at(LintContext *ctx, int line, int col, int len,
                   const char *code, const char *fmt, ...);
void json_escape(const char *s, char *out, size_t outsz);

/* Driver/check entry points crossing the TU boundary. */
int is_builtin_name(const char *name);
void builtin_name_env_free(void);
void check_undefined_names(ASTNode *ast, const char *path,
                           const char *source, LintContext *ctx);
void check_stdlib_shadow(ASTNode *ast, const char *path, LintContext *ctx);
void lint_run_checks(ASTNode *ast, const char *path, const char *source,
                     LintContext *ctx);
int lint_suppressed(const char *source, int warn_line, const char *code);

#endif /* EIGENSCRIPT_LINT_INTERNAL_H */
