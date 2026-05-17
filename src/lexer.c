/*
 * EigenScript tokenizer. Lexes source text into a token stream,
 * handling indentation, f-strings, comments, and keywords.
 */

#include "eigenscript.h"

/* Parse-error counter owned by eigenscript.c. */
extern __thread int g_parse_errors;

/* Recursion depth guard for nested f-string tokenization. */
static __thread int g_tokenize_depth = 0;
#define MAX_TOKENIZE_DEPTH 64

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
}

static TokType keyword_type(const char *word) {
    switch (word[0]) {
    case 'a':
        if (strcmp(word, "as") == 0) return TOK_AS;
        if (strcmp(word, "and") == 0) return TOK_AND;
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
    case 'r':
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

TokenList tokenize(const char *source) {
    TokenList tl;
    tl.capacity = MAX_TOKENS;
    tl.tokens = xmalloc_array(tl.capacity, sizeof(Token));
    tl.count = 0;

    if (g_tokenize_depth >= MAX_TOKENIZE_DEPTH) {
        fprintf(stderr, "Error: f-string nesting too deep (max %d levels)\n", MAX_TOKENIZE_DEPTH);
        g_parse_errors++;
        tok_add(&tl, TOK_EOF, 0, NULL, 1, 0);
        return tl;
    }
    g_tokenize_depth++;

    int indent_stack[MAX_INDENT];
    int indent_top = 0;
    indent_stack[0] = 0;

    const char *p = source;
    int line = 1;
    int col = 0;
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
            if (*p == '\n') {
                p++; line++; col = 0;
                continue;
            }
            if (*p == '\0') break;

            if (spaces > indent_stack[indent_top]) {
                if (indent_top >= MAX_INDENT - 1) {
                    fprintf(stderr, "Syntax error line %d: indent too deep (max %d levels)\n", line, MAX_INDENT);
                    g_parse_errors++;
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
            }
            at_line_start = 0;
        }

        if (*p == ' ' || *p == '\t') {
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

            while (*p && *p != '"') {
                if (*p == '\\' && (*(p+1) == '{' || *(p+1) == '}')) {
                    strbuf_append_char(&buf, *(p+1));
                    p += 2; col += 2;
                    continue;
                }
                if (*p == '\\') {
                    p++; col++;
                    switch (*p) {
                        case 'n': strbuf_append_char(&buf, '\n'); break;
                        case 't': strbuf_append_char(&buf, '\t'); break;
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
                        if (*p == '{') depth++;
                        else if (*p == '}') { depth--; if (depth == 0) break; }
                        strbuf_append_char(&expr_buf, *p++);
                        col++;
                    }
                    if (*p == '}') { p++; col++; }
                    else {
                        fprintf(stderr, "Syntax error line %d: unterminated f-string expression\n", line);
                        g_parse_errors++;
                    }

                    /* Tokenize the inner expression and splice tokens in */
                    TokenList inner = tokenize(expr_buf.data);
                    strbuf_free(&expr_buf);
                    for (int ti = 0; ti < inner.count; ti++) {
                        if (inner.tokens[ti].type == TOK_EOF) break;
                        if (inner.tokens[ti].type == TOK_NEWLINE) continue;
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
            if (*p == '"') { p++; col++; }
            else {
                fprintf(stderr, "Syntax error line %d: unterminated f-string\n", line);
                g_parse_errors++;
            }
            strbuf_free(&buf);
            continue;
        }

        if (*p == '"') {
            p++; col++;
            strbuf buf;
            strbuf_init(&buf);
            while (*p && *p != '"') {
                if (*p == '\\') {
                    p++; col++;
                    switch (*p) {
                        case 'n': strbuf_append_char(&buf, '\n'); break;
                        case 't': strbuf_append_char(&buf, '\t'); break;
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
                g_parse_errors++;
            }
            tok_add(&tl, TOK_STR, 0, buf.data, line, tok_col);
            strbuf_free(&buf);
            continue;
        }

        if (isdigit(*p) || (*p == '.' && isdigit(*(p+1)))) {
            char *end;
            double num = strtod(p, &end);
            col += (int)(end - p);
            p = end;
            tok_add(&tl, TOK_NUM, num, NULL, line, tok_col);
            continue;
        }

        if (isalpha(*p) || *p == '_') {
            char word[256];
            int wi = 0;
            while ((isalnum(*p) || *p == '_') && wi < 255) {
                word[wi++] = *p++;
                col++;
            }
            word[wi] = '\0';
            TokType tt = keyword_type(word);
            tok_add(&tl, tt, 0, word, line, tok_col);
            continue;
        }

        switch (*p) {
            case '+':
                if (*(p+1) == '=') { tok_add(&tl, TOK_PLUS_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_PLUS, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '-':
                if (*(p+1) == '=') { tok_add(&tl, TOK_MINUS_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_MINUS, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '*':
                if (*(p+1) == '=') { tok_add(&tl, TOK_STAR_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_STAR, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '/':
                if (*(p+1) == '=') { tok_add(&tl, TOK_SLASH_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_SLASH, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '%':
                if (*(p+1) == '=') { tok_add(&tl, TOK_PERCENT_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_PERCENT, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '(': tok_add(&tl, TOK_LPAREN, 0, NULL, line, tok_col); p++; col++; bracket_depth++; break;
            case ')': tok_add(&tl, TOK_RPAREN, 0, NULL, line, tok_col); p++; col++; if (bracket_depth > 0) bracket_depth--; break;
            case '[': tok_add(&tl, TOK_LBRACKET, 0, NULL, line, tok_col); p++; col++; bracket_depth++; break;
            case ']': tok_add(&tl, TOK_RBRACKET, 0, NULL, line, tok_col); p++; col++; if (bracket_depth > 0) bracket_depth--; break;
            case '{': tok_add(&tl, TOK_LBRACE, 0, NULL, line, tok_col); p++; col++; bracket_depth++; break;
            case '}': tok_add(&tl, TOK_RBRACE, 0, NULL, line, tok_col); p++; col++; if (bracket_depth > 0) bracket_depth--; break;
            case ',': tok_add(&tl, TOK_COMMA, 0, NULL, line, tok_col); p++; col++; break;
            case ':': tok_add(&tl, TOK_COLON, 0, NULL, line, tok_col); p++; col++; break;
            case '.': tok_add(&tl, TOK_DOT, 0, NULL, line, tok_col); p++; col++; break;
            case '<':
                if (*(p+1) == '<' && *(p+2) == '=') { tok_add(&tl, TOK_SHL_EQ, 0, NULL, line, tok_col); p += 3; col += 3; }
                else if (*(p+1) == '<') { tok_add(&tl, TOK_SHL, 0, NULL, line, tok_col); p += 2; col += 2; }
                else if (*(p+1) == '=') { tok_add(&tl, TOK_LE, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_LT, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '>':
                if (*(p+1) == '>' && *(p+2) == '=') { tok_add(&tl, TOK_SHR_EQ, 0, NULL, line, tok_col); p += 3; col += 3; }
                else if (*(p+1) == '>') { tok_add(&tl, TOK_SHR, 0, NULL, line, tok_col); p += 2; col += 2; }
                else if (*(p+1) == '=') { tok_add(&tl, TOK_GE, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_GT, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '!':
                if (*(p+1) == '=') { tok_add(&tl, TOK_NE, 0, NULL, line, tok_col); p += 2; col += 2; }
                else {
                    fprintf(stderr, "Syntax error line %d: expected '!=' after '!'\n", line);
                    g_parse_errors++; p++; col++;
                }
                break;
            case '=':
                if (*(p+1) == '=') { tok_add(&tl, TOK_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else if (*(p+1) == '>') { tok_add(&tl, TOK_ARROW, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_ASSIGN, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '|':
                if (*(p+1) == '>') { tok_add(&tl, TOK_PIPE, 0, NULL, line, tok_col); p += 2; col += 2; }
                else if (*(p+1) == '=') { tok_add(&tl, TOK_BITOR_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_BITOR, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '&':
                if (*(p+1) == '=') { tok_add(&tl, TOK_AMP_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_AMP, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '^':
                if (*(p+1) == '=') { tok_add(&tl, TOK_CARET_EQ, 0, NULL, line, tok_col); p += 2; col += 2; }
                else { tok_add(&tl, TOK_CARET, 0, NULL, line, tok_col); p++; col++; }
                break;
            case '~': tok_add(&tl, TOK_TILDE, 0, NULL, line, tok_col); p++; col++; break;
            default:
                fprintf(stderr, "Syntax error line %d: unexpected character '%c'\n", line, *p);
                g_parse_errors++;
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
