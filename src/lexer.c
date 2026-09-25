/*
 * EigenScript tokenizer. Lexes source text into a token stream,
 * handling indentation, f-strings, comments, and keywords.
 */

#include "eigenscript.h"

/* Recursion depth guard for nested f-string tokenization. g_tokenize_depth
 * now lives on EigsThread (Phase 8); the identifier is a bridge macro. */
#define MAX_TOKENIZE_DEPTH 64

/* A lexer error always updates both the LSP's first diagnostic and the
 * parser's error tally. Keep those effects inseparable at every call site. */
static void lexer_error_at(int line, int col, const char *message) {
    eigs_record_first_error_at(line, col, 1, message);
    g_parse_errors++;
}

static void tok_add(TokenList *tl, TokType type, double num, const char *str, int line, int col) {
    if (tl->count >= tl->capacity) {
        tl->capacity *= 2;
        tl->tokens = xrealloc_array(tl->tokens, tl->capacity, sizeof(Token));
    }
    Token *t = &tl->tokens[tl->count++];
    t->type = type;
    t->num_val = num;
    t->str_val = str ? xstrdup(str) : NULL;
    t->line = line;
    t->col = col;
    /* Default span: exact for str-valued tokens (identifiers, keywords);
     * numbers and strings overwrite this with their true source length at
     * the emission site, since their lexeme differs from str_val. */
    t->len = str ? (int)strlen(str) : 1;
}

/* Nested f-string boundary scanning (#1253). An interpolation's extent is
 * found before its text is re-tokenized, so the scanner must know every
 * lexical state that can hide a brace: a string literal, a comment, and a
 * nested f-string, whose literal text is not an ordinary string (its
 * interpolations may contain quotes of their own). Treating a nested
 * `f"..."` as a plain string ended the skip at the first inner quote and
 * exposed a brace inside an inner string literal to the outer depth count.
 * Both helpers stop at NUL; the caller reports the unterminated form. */
static int fstr_ident_char(char ch) {
    return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
           (ch >= '0' && ch <= '9') || ch == '_';
}

static const char *fstr_interp_end(const char *p);

/* p at the `f` of f"...": returns the position just past the closing quote. */
static const char *fstr_skip_fstring(const char *p) {
    p += 2; /* skip f" */
    while (*p && *p != '"') {
        if (*p == '\\') {
            p++;
            if (*p) p++;
            continue;
        }
        if (*p == '{') {
            p = fstr_interp_end(p + 1);
            if (*p == '}') p++;
            continue;
        }
        p++;
    }
    if (*p == '"') p++;
    return p;
}

/* p just past an interpolation's `{`: returns the position of its matching
 * `}` (or the NUL terminator). */
static const char *fstr_interp_end(const char *p) {
    const char *start = p;
    int depth = 1;
    while (*p) {
        if (*p == 'f' && p[1] == '"' && (p == start || !fstr_ident_char(p[-1]))) {
            p = fstr_skip_fstring(p);
            continue;
        }
        if (*p == '"') {
            p++;
            while (*p && *p != '"') {
                if (*p == '\\' && p[1]) p++;
                p++;
            }
            if (*p == '"') p++;
            continue;
        }
        if (*p == '#') {
            while (*p && *p != '\n') p++;
            continue;
        }
        if (*p == '{') depth++;
        else if (*p == '}' && --depth == 0) break;
        p++;
    }
    return p;
}

static TokType keyword_type(const char *word) {
    switch (word[0]) {
    case 'a':
        if (strcmp(word, "as") == 0) return TOK_AS;
        if (strcmp(word, "and") == 0) return TOK_AND;
        if (strcmp(word, "at") == 0) return TOK_AT;
        break;
    case 'b':
        if (strcmp(word, "break") == 0) return TOK_BREAK;
        break;
    case 'c':
        if (strcmp(word, "case") == 0) return TOK_CASE;
        if (strcmp(word, "catch") == 0) return TOK_CATCH;
        if (strcmp(word, "continue") == 0) return TOK_CONTINUE;
        if (strcmp(word, "converged") == 0) return TOK_CONVERGED;
        break;
    case 'd':
        if (strcmp(word, "define") == 0) return TOK_DEFINE;
        if (strcmp(word, "diverging") == 0) return TOK_DIVERGING;
        break;
    case 'e':
        if (strcmp(word, "else") == 0) return TOK_ELSE;
        if (strcmp(word, "elif") == 0) return TOK_ELIF;
        if (strcmp(word, "equilibrium") == 0) return TOK_EQUILIBRIUM;
        break;
    case 'f':
        if (strcmp(word, "for") == 0) return TOK_FOR;
        break;
    case 'h':
        if (strcmp(word, "how") == 0) return TOK_HOW;
        break;
    case 'i':
        if (strcmp(word, "if") == 0) return TOK_IF;
        if (strcmp(word, "is") == 0) return TOK_IS;
        if (strcmp(word, "in") == 0) return TOK_IN;
        if (strcmp(word, "import") == 0) return TOK_IMPORT;
        if (strcmp(word, "improving") == 0) return TOK_IMPROVING;
        break;
    case 'l':
        if (strcmp(word, "local") == 0) return TOK_LOCAL;
        if (strcmp(word, "loop") == 0) return TOK_LOOP;
        break;
    case 'm':
        if (strcmp(word, "match") == 0) return TOK_MATCH;
        break;
    case 'n':
        if (strcmp(word, "not") == 0) return TOK_NOT;
        if (strcmp(word, "null") == 0) return TOK_NULL;
        break;
    case 'o':
        if (strcmp(word, "of") == 0) return TOK_OF;
        if (strcmp(word, "or") == 0) return TOK_OR;
        if (strcmp(word, "oscillating") == 0) return TOK_OSCILLATING;
        break;
    case 'p':
        if (strcmp(word, "prev") == 0) return TOK_PREV;
        break;
    case 'r':
        if (strcmp(word, "report") == 0) return TOK_REPORT;
        if (strcmp(word, "report_value") == 0) return TOK_REPORT_VALUE;
        if (strcmp(word, "return") == 0) return TOK_RETURN;
        break;
    case 's':
        if (strcmp(word, "stable") == 0) return TOK_STABLE;
        break;
    case 't':
        if (strcmp(word, "try") == 0) return TOK_TRY;
        break;
    case 'u':
        if (strcmp(word, "unobserved") == 0) return TOK_UNOBSERVED;
        break;
    case 'w':
        if (strcmp(word, "while") == 0) return TOK_WHILE;
        if (strcmp(word, "what") == 0) return TOK_WHAT;
        if (strcmp(word, "who") == 0) return TOK_WHO;
        if (strcmp(word, "when") == 0) return TOK_WHEN;
        if (strcmp(word, "where") == 0) return TOK_WHERE;
        if (strcmp(word, "why") == 0) return TOK_WHY;
        break;
    }
    return TOK_IDENT;
}

int tok_base_string_id_count(void) {
    return (int)TOK_EOF + 1;
}

/* Recognised multi-char operators. Each operator is spelled once, as
 * characters. The table and both byte filters are that list. */
#define LEX_MULTI_OP_MAP(X2, X3) \
    X3(TOK_SHL_EQ, '<', '<', '=') \
    X3(TOK_SHR_EQ, '>', '>', '=') \
    X2(TOK_EQ, '=', '=') \
    X2(TOK_NE, '!', '=') \
    X2(TOK_LE, '<', '=') \
    X2(TOK_GE, '>', '=') \
    X2(TOK_SHL, '<', '<') \
    X2(TOK_SHR, '>', '>') \
    X2(TOK_PLUS_EQ, '+', '=') \
    X2(TOK_MINUS_EQ, '-', '=') \
    X2(TOK_STAR_EQ, '*', '=') \
    X2(TOK_SLASH_EQ, '/', '=') \
    X2(TOK_PERCENT_EQ, '%', '=') \
    X2(TOK_AMP_EQ, '&', '=') \
    X2(TOK_BITOR_EQ, '|', '=') \
    X2(TOK_CARET_EQ, '^', '=') \
    X2(TOK_ARROW, '=', '>') \
    X2(TOK_PIPE, '|', '>')

static const struct {
    char sp[4];
    unsigned char len;
    TokType ty;
} LEX_MULTI_OPS[] = {
#define X3(ty, a, b, c) { {a, b, c, 0}, 3, ty },
#define X2(ty, a, b)    { {a, b, 0, 0}, 2, ty },
    LEX_MULTI_OP_MAP(X2, X3)
#undef X2
#undef X3
};

/* Several operators share a first or second byte, so a designator repeats.
 * The value is the same either way. */
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Woverride-init"
static const unsigned char lex_multi_first[256] = {
#define X3(ty, a, b, c) [(unsigned char)(a)] = 1,
#define X2(ty, a, b)    [(unsigned char)(a)] = 1,
    LEX_MULTI_OP_MAP(X2, X3)
#undef X2
#undef X3
};
static const unsigned char lex_multi_second[256] = {
#define X3(ty, a, b, c) [(unsigned char)(b)] = 1,
#define X2(ty, a, b)    [(unsigned char)(b)] = 1,
    LEX_MULTI_OP_MAP(X2, X3)
#undef X2
#undef X3
};
#pragma GCC diagnostic pop

int lexer_operator_len(const char *s, TokType *ty) {
    int best = 0;
    TokType best_ty = 0;
    if (!s || !s[0] || !s[1]) return 0;
    if (!lex_multi_first[(unsigned char)s[0]]) return 0;
    if (!lex_multi_second[(unsigned char)s[1]]) return 0;
    for (size_t k = 0; k < sizeof LEX_MULTI_OPS / sizeof LEX_MULTI_OPS[0]; k++) {
        const char *op = LEX_MULTI_OPS[k].sp;
        int n = LEX_MULTI_OPS[k].len;
        if (op[0] != s[0]) continue;
        int i = 1;
        while (i < n && s[i] == op[i]) i++;
        if (i == n && n > best) {
            best = n;
            best_ty = LEX_MULTI_OPS[k].ty;
        }
    }
    if (best > 1 && ty) *ty = best_ty;
    return best > 1 ? best : 0;
}

/* Switch deliberately has no `default:` — -Wswitch (in -Wall) then warns
 * at compile time if a TokType is added without a placeholder here, which
 * is the load-bearing safety net for keeping the corpus stream and the
 * detokenizer in sync. */
const char* tok_base_string(TokType t) {
    switch (t) {
        case TOK_NUM:        return "0 ";
        case TOK_STR:        return "\"s\" ";
        case TOK_IDENT:      return "x ";
        case TOK_IS:         return "is ";
        case TOK_OF:         return "of ";
        case TOK_DEFINE:     return "define ";
        case TOK_AS:         return "as ";
        case TOK_IF:         return "if ";
        case TOK_ELSE:       return "else ";
        case TOK_ELIF:       return "elif ";
        case TOK_LOOP:       return "loop ";
        case TOK_WHILE:      return "while ";
        case TOK_RETURN:     return "return ";
        case TOK_AND:        return "and ";
        case TOK_OR:         return "or ";
        case TOK_NOT:        return "not ";
        case TOK_FOR:        return "for ";
        case TOK_IN:         return "in ";
        case TOK_NULL:       return "null ";
        case TOK_WHAT:       return "what ";
        case TOK_WHO:        return "who ";
        case TOK_WHEN:       return "when ";
        case TOK_WHERE:      return "where ";
        case TOK_WHY:        return "why ";
        case TOK_HOW:        return "how ";
        case TOK_PREV:       return "prev ";
        case TOK_AT:         return "at ";
        case TOK_CONVERGED:  return "converged ";
        case TOK_STABLE:     return "stable ";
        case TOK_IMPROVING:  return "improving ";
        case TOK_OSCILLATING:return "oscillating ";
        case TOK_DIVERGING:  return "diverging ";
        case TOK_EQUILIBRIUM:return "equilibrium ";
        case TOK_TRY:        return "try ";
        case TOK_CATCH:      return "catch ";
        case TOK_BREAK:      return "break ";
        case TOK_CONTINUE:   return "continue ";
        case TOK_IMPORT:     return "import ";
        case TOK_MATCH:      return "match ";
        case TOK_CASE:       return "case ";
        case TOK_UNOBSERVED: return "unobserved ";
        case TOK_REPORT:     return "report ";
        case TOK_REPORT_VALUE:return "report_value ";
        case TOK_LOCAL:      return "local ";
        case TOK_PLUS:       return "+ ";
        case TOK_MINUS:      return "- ";
        case TOK_STAR:       return "* ";
        case TOK_SLASH:      return "/ ";
        case TOK_PERCENT:    return "% ";
        case TOK_LT:         return "< ";
        case TOK_GT:         return "> ";
        case TOK_LE:         return "<= ";
        case TOK_GE:         return ">= ";
        case TOK_EQ:         return "== ";
        case TOK_NE:         return "!= ";
        case TOK_ASSIGN:     return "= ";
        case TOK_LPAREN:     return "(";
        case TOK_RPAREN:     return ") ";
        case TOK_LBRACKET:   return "[";
        case TOK_RBRACKET:   return "] ";
        case TOK_COMMA:      return ", ";
        case TOK_COLON:      return ": ";
        case TOK_DOT:        return ".";
        case TOK_LBRACE:     return "{";
        case TOK_RBRACE:     return "} ";
        case TOK_PIPE:       return "|> ";
        case TOK_ARROW:      return "=> ";
        case TOK_AMP:        return "& ";
        case TOK_BITOR:      return "| ";
        case TOK_CARET:      return "^ ";
        case TOK_SHL:        return "<< ";
        case TOK_SHR:        return ">> ";
        case TOK_TILDE:      return "~ ";
        case TOK_PLUS_EQ:    return "+= ";
        case TOK_MINUS_EQ:   return "-= ";
        case TOK_STAR_EQ:    return "*= ";
        case TOK_SLASH_EQ:   return "/= ";
        case TOK_PERCENT_EQ: return "%= ";
        case TOK_AMP_EQ:     return "&= ";
        case TOK_BITOR_EQ:   return "|= ";
        case TOK_CARET_EQ:   return "^= ";
        case TOK_SHL_EQ:     return "<<= ";
        case TOK_SHR_EQ:     return ">>= ";
        case TOK_NEWLINE:    return "";
        case TOK_INDENT:     return "";
        case TOK_DEDENT:     return "";
        case TOK_EOF:        return "";
    }
    return "";
}

static TokenList tokenize_at_line(const char *source, int initial_line, int initial_col) {
    TokenList tl;
    tl.capacity = MAX_TOKENS;
    tl.tokens = xmalloc_array(tl.capacity, sizeof(Token));
    tl.count = 0;

    /* Start of a fresh tokenize+parse pass (tokenize always runs first):
     * clear the captured first error so a consumer like the LSP sees only
     * this document's diagnostic. Nested f-string tokenization bumps
     * g_tokenize_depth, so only reset at the outermost pass. */
    if (g_tokenize_depth == 0) {
        g_first_error_code = "E002";
        g_first_error_line = 0;
        g_first_error_col = 0;
        g_first_error_len = 0;
        g_first_error_col_known = 0;
        g_first_error_msg[0] = '\0';
    }

    if (g_tokenize_depth >= MAX_TOKENIZE_DEPTH) {
        fprintf(stderr, "Error: f-string nesting too deep (max %d levels)\n", MAX_TOKENIZE_DEPTH);
        char msg[64];
        snprintf(msg, sizeof(msg), "f-string nesting too deep (max %d levels)",
                 MAX_TOKENIZE_DEPTH);
        lexer_error_at(initial_line, initial_col, msg);
        tok_add(&tl, TOK_EOF, 0, NULL, initial_line, initial_col);
        return tl;
    }
    g_tokenize_depth++;

    int indent_stack[MAX_INDENT];
    int indent_top = 0;
    indent_stack[0] = 0;

    const char *p = source;
    int line = initial_line;
    int col = initial_col;
    int at_line_start = 1;
    int bracket_depth = 0;  /* inside [], {}, () — suppress newlines/indent */

    while (*p) {
        if (at_line_start && bracket_depth == 0) {
            int spaces = 0;
            while (*p == ' ') { spaces++; p++; col++; }
            if (*p == '\t') {
                while (*p == '\t') { spaces += 4; p++; col += 4; }
                while (*p == ' ') { spaces++; p++; col++; }
            }
            if (*p == '#') {
                while (*p && *p != '\n') { p++; col++; }
                if (*p == '\n') { p++; line++; col = 0; }
                continue;
            }
            /* #880: a CRLF blank line — swallow the CR so the '\n' below sees
             * an empty line rather than falling through to indent handling
             * with a stray carriage return as the first "real" character. */
            if (*p == '\r' && p[1] == '\n') p++;
            if (*p == '\n') {
                p++; line++; col = 0;
                continue;
            }
            if (*p == '\0') break;

            if (spaces > indent_stack[indent_top]) {
                if (indent_top >= MAX_INDENT - 1) {
                    fprintf(stderr, "Syntax error line %d: indent too deep (max %d levels)\n", line, MAX_INDENT);
                    char msg[64];
                    snprintf(msg, sizeof(msg), "indent too deep (max %d levels)",
                             MAX_INDENT);
                    lexer_error_at(line, col, msg);
                } else {
                    indent_top++;
                    indent_stack[indent_top] = spaces;
                    tok_add(&tl, TOK_INDENT, 0, NULL, line, col);
                }
            } else {
                while (indent_top > 0 && spaces < indent_stack[indent_top]) {
                    indent_top--;
                    tok_add(&tl, TOK_DEDENT, 0, NULL, line, col);
                }
                if (spaces != indent_stack[indent_top]) {
                    fprintf(stderr, "Syntax error line %d: indentation does not match any outer level\n", line);
                    lexer_error_at(line, col,
                                   "indentation does not match any outer level");
                }
            }
            at_line_start = 0;
        }

        /* #880: EigenScript could not read a CRLF source file at all —
         * `eigenscript win.eigs` died with "unexpected character" on every
         * line, which also made the language server useless on any document
         * a Windows editor saved. The CR of a CRLF pair is skipped here so
         * the '\n' does the line break; a CR inside a string LITERAL is
         * untouched (that path scans its own bytes), so a program that
         * genuinely embeds one is unaffected. A lone CR as a line terminator
         * (classic Mac, pre-OS X) is deliberately not a line break. */
        if (*p == ' ' || *p == '\t' || (*p == '\r' && p[1] == '\n')) {
            p++; col++;
            continue;
        }

        if (*p == '#') {
            while (*p && *p != '\n') { p++; col++; }
            continue;
        }

        if (*p == '\n') {
            if (bracket_depth == 0) {
                if (tl.count > 0 && tl.tokens[tl.count-1].type != TOK_NEWLINE
                    && tl.tokens[tl.count-1].type != TOK_INDENT
                    && tl.tokens[tl.count-1].type != TOK_DEDENT) {
                    tok_add(&tl, TOK_NEWLINE, 0, NULL, line, col);
                }
                at_line_start = 1;
            }
            p++; line++; col = 0;
            continue;
        }

        int tok_col = col;  /* save column at start of token */

        /* f-string: f"hello {expr}" expands to ("hello " + (str of (expr))) */
        if (*p == 'f' && *(p+1) == '"') {
            p += 2; col += 2; /* skip f" */
            strbuf buf;
            strbuf_init(&buf);
            int has_segments = 0;
            /* Wrap the entire concatenation in outer parens so the resulting
             * expression binds as one primary. Without this, `eval of f"..."`
             * parses as `(eval of <first-segment>) + <rest>` because `of`'s
             * RHS only consumes a unary-or-tighter expression. */
            tok_add(&tl, TOK_LPAREN, 0, NULL, line, tok_col);

            while (*p && *p != '"') {
                if (*p == '\\' && (*(p+1) == '{' || *(p+1) == '}')) {
                    strbuf_append_char(&buf, *(p+1));
                    p += 2; col += 2;
                    continue;
                }
                if (*p == '\\') {
                    p++; col++;
                    /* #304: a backslash at end-of-source leaves *p on the NUL
                     * terminator. Stop here — appending it and advancing past
                     * the NUL reads off the end of the buffer (heap overflow).
                     * The unterminated-f-string check below then fires. */
                    if (*p == '\0') break;
                    switch (*p) {
                        case 'n': strbuf_append_char(&buf, '\n'); break;
                        case 't': strbuf_append_char(&buf, '\t'); break;
                        case 'r': strbuf_append_char(&buf, '\r'); break;
                        case '\\': strbuf_append_char(&buf, '\\'); break;
                        case '"': strbuf_append_char(&buf, '"'); break;
                        default: strbuf_append_char(&buf, *p); break;
                    }
                    p++; col++;
                    continue;
                }
                if (*p == '{') {
                    /* Emit accumulated literal and + operator */
                    if (buf.len > 0 || !has_segments) {
                        if (has_segments) tok_add(&tl, TOK_PLUS, 0, NULL, line, tok_col);
                        tok_add(&tl, TOK_STR, 0, buf.data, line, tok_col);
                        has_segments = 1;
                    }
                    buf.len = 0;
                    buf.data[0] = '\0';
                    int expr_col = col + 1;
                    p++; col++; /* skip { */

                    /* Emit: + (str of (expr)) */
                    if (has_segments) tok_add(&tl, TOK_PLUS, 0, NULL, line, col);
                    else has_segments = 1;
                    tok_add(&tl, TOK_LPAREN, 0, NULL, line, col);
                    tok_add(&tl, TOK_IDENT, 0, "str", line, col);
                    tok_add(&tl, TOK_OF, 0, NULL, line, col);
                    tok_add(&tl, TOK_LPAREN, 0, NULL, line, col);

                    /* Tokenize the expression inside braces */
                    int depth = 1;
                    strbuf expr_buf;
                    strbuf_init(&expr_buf);
                    while (*p && depth > 0) {
                        /* A string literal inside the interpolation is copied
                         * wholesale — braces inside it are text, not nesting
                         * (#334: `f"{"a}b"}"` used to cut at the `}` inside
                         * the string). Nested f-strings still balance via
                         * depth counting, since their braces sit outside the
                         * quotes we skip here. */
                        /* A nested f-string is copied wholesale too: its
                         * literal text and its own interpolations are
                         * scanned by their own lexical rules (#1253). */
                        if (*p == 'f' && *(p+1) == '"' &&
                            !(expr_buf.len > 0 &&
                              fstr_ident_char(expr_buf.data[expr_buf.len - 1]))) {
                            const char *end = fstr_skip_fstring(p);
                            while (p < end) {
                                strbuf_append_char(&expr_buf, *p++);
                                col++;
                            }
                            continue;
                        }
                        if (*p == '"') {
                            strbuf_append_char(&expr_buf, *p++);
                            col++;
                            while (*p && *p != '"') {
                                if (*p == '\\' && *(p+1)) {
                                    strbuf_append_char(&expr_buf, *p++);
                                    col++;
                                }
                                strbuf_append_char(&expr_buf, *p++);
                                col++;
                            }
                            if (*p == '"') {
                                strbuf_append_char(&expr_buf, *p++);
                                col++;
                            }
                            continue;
                        }
                        if (*p == '{') depth++;
                        else if (*p == '}') { depth--; if (depth == 0) break; }
                        strbuf_append_char(&expr_buf, *p++);
                        col++;
                    }
                    if (*p == '}') { p++; col++; }
                    else {
                        fprintf(stderr, "Syntax error line %d: unterminated f-string expression\n", line);
                        lexer_error_at(line, tok_col,
                                       "unterminated f-string expression");
                    }

                    /* Tokenize the inner expression and splice tokens in */
                    TokenList inner = tokenize_at_line(expr_buf.data, line, expr_col);
                    strbuf_free(&expr_buf);
                    for (int ti = 0; ti < inner.count; ti++) {
                        if (inner.tokens[ti].type == TOK_EOF) break;
                        /* Layout tokens from the sub-lex are meaningless
                         * inside a spliced expression — a leading space in
                         * `f"{ x }"` used to lex as line-start INDENT and
                         * break the parse (#334). */
                        if (inner.tokens[ti].type == TOK_NEWLINE ||
                            inner.tokens[ti].type == TOK_INDENT ||
                            inner.tokens[ti].type == TOK_DEDENT) continue;
                        Token *it = &inner.tokens[ti];
                        tok_add(&tl, it->type, it->num_val, it->str_val, line, col);
                    }
                    free_tokenlist(&inner);

                    tok_add(&tl, TOK_RPAREN, 0, NULL, line, col);
                    tok_add(&tl, TOK_RPAREN, 0, NULL, line, col);
                    continue;
                }
                strbuf_append_char(&buf, *p++);
                col++;
            }
            /* Emit trailing literal */
            if (buf.len > 0) {
                if (has_segments) tok_add(&tl, TOK_PLUS, 0, NULL, line, tok_col);
                tok_add(&tl, TOK_STR, 0, buf.data, line, tok_col);
            } else if (!has_segments) {
                /* empty f-string: f"" */
                tok_add(&tl, TOK_STR, 0, "", line, tok_col);
            }
            /* Close the outer wrapper paren */
            tok_add(&tl, TOK_RPAREN, 0, NULL, line, tok_col);
            if (*p == '"') { p++; col++; }
            else {
                fprintf(stderr, "Syntax error line %d: unterminated f-string\n", line);
                lexer_error_at(line, tok_col, "unterminated f-string");
            }
            strbuf_free(&buf);
            continue;
        }

        if (*p == '"') {
            const char *str_start = p;  /* includes the opening quote */
            p++; col++;
            strbuf buf;
            strbuf_init(&buf);
            while (*p && *p != '"') {
                if (*p == '\\') {
                    p++; col++;
                    /* #304: a backslash at end-of-source leaves *p on the NUL
                     * terminator. Stop here — appending it and the trailing
                     * p++ steps past the NUL and reads off the end of the
                     * buffer (heap overflow). The unterminated-string check
                     * below then fires. */
                    if (*p == '\0') break;
                    switch (*p) {
                        case 'n': strbuf_append_char(&buf, '\n'); break;
                        case 't': strbuf_append_char(&buf, '\t'); break;
                        case 'r': strbuf_append_char(&buf, '\r'); break;
                        case '\\': strbuf_append_char(&buf, '\\'); break;
                        case '"': strbuf_append_char(&buf, '"'); break;
                        default: strbuf_append_char(&buf, *p); break;
                    }
                } else {
                    strbuf_append_char(&buf, *p);
                }
                p++; col++;
            }
            if (*p == '"') { p++; col++; }
            else {
                fprintf(stderr, "Syntax error line %d: unterminated string\n", line);
                lexer_error_at(line, tok_col, "unterminated string");
            }
            tok_add(&tl, TOK_STR, 0, buf.data, line, tok_col);
            tl.tokens[tl.count - 1].len = (int)(p - str_start);  /* true source span */
            strbuf_free(&buf);
            continue;
        }

        if (isdigit(*p) || (*p == '.' && isdigit(*(p+1)))) {
            const char *num_start = p;
            /* Hex integer literals are lexed HERE, not via strtod: the
             * freestanding mini_strtod has no hex path (documented
             * divergence — hex used to break on EigenOS), and C99 strtod
             * also accepts hex-FLOAT forms (0x1p4, 0xA.8) the language
             * does not mean. Digits accumulate in a double, so values
             * past 2^53 round exactly like long decimal literals do. */
            if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
                if (isxdigit((unsigned char)p[2])) {
                    double num = 0;
                    p += 2; col += 2;
                    while (isxdigit((unsigned char)*p)) {
                        int d = *p <= '9' ? *p - '0' : (*p | 32) - 'a' + 10;
                        num = num * 16 + d;
                        p++; col++;
                    }
                    tok_add(&tl, TOK_NUM, num, NULL, line, tok_col);
                    tl.tokens[tl.count - 1].len = (int)(p - num_start);
                    continue;
                }
                /* A 0x prefix with no hex digit (bare `0x`, or the
                 * hex-FLOAT fraction form `0x.8`): lex just the `0` so
                 * the rest re-lexes as an identifier/dot and the parse
                 * fails loudly. strtod must NEVER see a hex prefix —
                 * glibc would parse `0x.8` as 0.5 while mini_strtod
                 * (no hex) reads 0, a silent profile divergence. */
                tok_add(&tl, TOK_NUM, 0, NULL, line, tok_col);
                tl.tokens[tl.count - 1].len = 1;
                p++; col++;
                continue;
            }
            char *end;
            double num = strtod(p, &end);
            col += (int)(end - p);
            p = end;
            tok_add(&tl, TOK_NUM, num, NULL, line, tok_col);
            tl.tokens[tl.count - 1].len = (int)(end - num_start);
            continue;
        }

        if (isalpha(*p) || *p == '_') {
            /* #305: grow the identifier into a strbuf (like string literals)
             * instead of a fixed 256-byte stack array. The old cap silently
             * stopped at 255 chars WITHOUT consuming the rest, so the tail was
             * re-lexed as a second token — splitting one over-long identifier
             * into several. A strbuf lexes it as a single token of any length. */
            strbuf buf;
            strbuf_init(&buf);
            while (isalnum(*p) || *p == '_') {
                strbuf_append_char(&buf, *p++);
                col++;
            }
            TokType tt = keyword_type(buf.data);
            tok_add(&tl, tt, 0, buf.data, line, tok_col);
            strbuf_free(&buf);
            continue;
        }

        if (lex_multi_first[(unsigned char)*p] &&
            p[1] && lex_multi_second[(unsigned char)p[1]]) {
            TokType op_ty = 0;
            int op_n = lexer_operator_len(p, &op_ty);
            if (op_n > 1) {
                tok_add(&tl, op_ty, 0, NULL, line, tok_col);
                p += op_n;
                col += op_n;
                continue;
            }
        }

        switch (*p) {
            case '+': tok_add(&tl, TOK_PLUS, 0, NULL, line, tok_col); p++; col++; break;
            case '-': tok_add(&tl, TOK_MINUS, 0, NULL, line, tok_col); p++; col++; break;
            case '*': tok_add(&tl, TOK_STAR, 0, NULL, line, tok_col); p++; col++; break;
            case '/': tok_add(&tl, TOK_SLASH, 0, NULL, line, tok_col); p++; col++; break;
            case '%': tok_add(&tl, TOK_PERCENT, 0, NULL, line, tok_col); p++; col++; break;
            case '(': tok_add(&tl, TOK_LPAREN, 0, NULL, line, tok_col); p++; col++; bracket_depth++; break;
            case ')': tok_add(&tl, TOK_RPAREN, 0, NULL, line, tok_col); p++; col++; if (bracket_depth > 0) bracket_depth--; break;
            case '[': tok_add(&tl, TOK_LBRACKET, 0, NULL, line, tok_col); p++; col++; bracket_depth++; break;
            case ']': tok_add(&tl, TOK_RBRACKET, 0, NULL, line, tok_col); p++; col++; if (bracket_depth > 0) bracket_depth--; break;
            case '{': tok_add(&tl, TOK_LBRACE, 0, NULL, line, tok_col); p++; col++; bracket_depth++; break;
            case '}': tok_add(&tl, TOK_RBRACE, 0, NULL, line, tok_col); p++; col++; if (bracket_depth > 0) bracket_depth--; break;
            case ',': tok_add(&tl, TOK_COMMA, 0, NULL, line, tok_col); p++; col++; break;
            case ':': tok_add(&tl, TOK_COLON, 0, NULL, line, tok_col); p++; col++; break;
            case '.': tok_add(&tl, TOK_DOT, 0, NULL, line, tok_col); p++; col++; break;
            case '<': tok_add(&tl, TOK_LT, 0, NULL, line, tok_col); p++; col++; break;
            case '>': tok_add(&tl, TOK_GT, 0, NULL, line, tok_col); p++; col++; break;
            case '!':
                fprintf(stderr, "Syntax error line %d: expected '!=' after '!'\n", line);
                lexer_error_at(line, tok_col, "expected '!=' after '!'");
                p++; col++;
                break;
            case '=': tok_add(&tl, TOK_ASSIGN, 0, NULL, line, tok_col); p++; col++; break;
            case '|': tok_add(&tl, TOK_BITOR, 0, NULL, line, tok_col); p++; col++; break;
            case '&': tok_add(&tl, TOK_AMP, 0, NULL, line, tok_col); p++; col++; break;
            case '^': tok_add(&tl, TOK_CARET, 0, NULL, line, tok_col); p++; col++; break;
            case '~': tok_add(&tl, TOK_TILDE, 0, NULL, line, tok_col); p++; col++; break;
            default:
                {
                    /* Spell the offending byte, never echo it (#1048). A byte
                     * >= 0x80 is one piece of a multi-byte character, so
                     * quoting it raw put half a UTF-8 sequence into the error
                     * message — which `--lint --json` and the LSP then publish
                     * as a payload strict decoders reject. `\xNN` says which
                     * byte it was and is ASCII on every channel. */
                    unsigned char bad = (unsigned char)*p;
                    char shown[8];
                    if (bad >= 0x20 && bad < 0x7F) {
                        shown[0] = (char)bad; shown[1] = '\0';
                    } else {
                        snprintf(shown, sizeof(shown), "\\x%02x", bad);
                    }
                    char m[64];
                    snprintf(m, sizeof(m), "unexpected character '%s'", shown);
                    lexer_error_at(line, tok_col, m);
                    fprintf(stderr, "Syntax error line %d: unexpected character '%s'\n", line, shown);
                }
                p++; col++;
                break;
        }
    }

    while (indent_top > 0) {
        tok_add(&tl, TOK_DEDENT, 0, NULL, line, col);
        indent_top--;
    }

    if (tl.count > 0 && tl.tokens[tl.count-1].type != TOK_NEWLINE) {
        tok_add(&tl, TOK_NEWLINE, 0, NULL, line, col);
    }
    tok_add(&tl, TOK_EOF, 0, NULL, line, col);

    g_tokenize_depth--;
    return tl;
}

TokenList tokenize(const char *source) {
    return tokenize_at_line(source, 1, 0);
}
