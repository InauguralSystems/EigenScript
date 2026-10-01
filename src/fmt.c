/*
 * EigenScript formatter — line-based source formatter.
 * Applies consistent indentation, operator spacing, and whitespace rules.
 *
 * Strategy: use the ORIGINAL indentation to determine nesting level,
 * normalize to 4-space indentation, and apply spacing fixups.
 */

#include "eigenscript.h"
#include "fsutil.h"

/* ---- helpers ---- */

/* Measure leading whitespace exactly as the lexer does (each tab adds 4). */
static int measure_indent(const char *line) {
    int col = 0;
    while (*line == ' ' || *line == '\t') {
        if (*line == '\t') col += 4;
        else col++;
        line++;
    }
    return col;
}

/* Track delimiters which suppress layout in the lexer.  A line which starts
 * inside delimiters is a continuation line even when it closes the last one;
 * its leading whitespace must therefore never change the indentation stack. */
static void update_bracket_depth(const char *line, int *depth, int *in_string) {
    /* F-strings have their own recursive lexer (quotes and comments inside an
     * interpolation do not follow ordinary-string rules).  At layout depth
     * zero they cannot be a continuation from a preceding delimiter, so do
     * not let a deliberately exotic f-string manufacture one here. */
    if (*depth == 0 && !*in_string && strstr(line, "f\"") != NULL) return;

    for (int i = 0; line[i]; i++) {
        char c = line[i];
        if (*in_string) {
            if (c == '\\' && line[i + 1]) i++;
            else if (c == '"') *in_string = 0;
            continue;
        }
        if (c == '#') break;
        if (c == '"') {
            *in_string = 1;
        } else if (c == '(' || c == '[' || c == '{') {
            (*depth)++;
        } else if ((c == ')' || c == ']' || c == '}') && *depth > 0) {
            (*depth)--;
        }
    }
}

/* True if s[i] (a '+' or '-') is the sign of a numeric literal's exponent, as
 * in 1.5e+10, where treating it as an operator would corrupt the literal.
 *
 * Requires a digit run (with at most one '.') before the 'e', not itself
 * preceded by an identifier character, and a digit after the sign — so `1.5e+1`
 * is an exponent while `a1e+1` (an identifier plus an operator) is not. */
static int is_exponent_sign(const char *s, int len, int i) {
    if (s[i] != '+' && s[i] != '-') return 0;
    if (i < 2 || i + 1 >= len) return 0;
    if (s[i - 1] != 'e' && s[i - 1] != 'E') return 0;
    if (!isdigit((unsigned char)s[i + 1])) return 0;

    int j = i - 2;
    int seen_digit = 0, seen_dot = 0;
    while (j >= 0) {
        if (isdigit((unsigned char)s[j])) { seen_digit = 1; j--; }
        else if (s[j] == '.' && !seen_dot) { seen_dot = 1; j--; }
        else break;
    }
    if (!seen_digit) return 0;
    if (j >= 0 && (isalnum((unsigned char)s[j]) || s[j] == '_')) return 0;
    return 1;
}

/* Fix operator spacing on a single line.
 * Processes character by character, tracking string literals. */
static void fix_spacing(const char *line, strbuf *out) {
    int len = (int)strlen(line);
    if (len == 0) return;

    /* Work on a mutable copy */
    char *buf = xmalloc(len + 1);
    memcpy(buf, line, len + 1);

    /* First pass: collapse multiple spaces to single space (outside strings)
     * and ensure space after # in comments. */
    strbuf tmp;
    strbuf_init(&tmp);
    int in_str = 0;
    char str_char = 0;
    int in_comment = 0;

    for (int i = 0; i < len; i++) {
        if (in_comment) {
            strbuf_append_char(&tmp, buf[i]);
            continue;
        }
        if (in_str) {
            strbuf_append_char(&tmp, buf[i]);
            if (buf[i] == '\\' && i + 1 < len) {
                strbuf_append_char(&tmp, buf[++i]);
                continue;
            }
            if (buf[i] == str_char) in_str = 0;
            continue;
        }
        if (buf[i] == '#') {
            in_comment = 1;
            strbuf_append_char(&tmp, '#');
            if (i + 1 < len && buf[i + 1] != ' ' && buf[i + 1] != '\0') {
                strbuf_append_char(&tmp, ' ');
            }
            continue;
        }
        if (buf[i] == '"') {
            in_str = 1;
            str_char = '"';
            strbuf_append_char(&tmp, buf[i]);
            continue;
        }
        /* Collapse multiple spaces */
        if (buf[i] == ' ' && tmp.len > 0 && tmp.data[tmp.len - 1] == ' ') {
            continue;
        }
        strbuf_append_char(&tmp, buf[i]);
    }
    free(buf);

    /* Second pass: fix comma and bracket spacing */
    strbuf tmp2;
    strbuf_init(&tmp2);
    in_str = 0;
    str_char = 0;
    in_comment = 0;
    const char *s = tmp.data;
    len = (int)tmp.len;

    for (int i = 0; i < len; i++) {
        if (in_comment) {
            strbuf_append_char(&tmp2, s[i]);
            continue;
        }
        if (in_str) {
            strbuf_append_char(&tmp2, s[i]);
            if (s[i] == '\\' && i + 1 < len) {
                strbuf_append_char(&tmp2, s[++i]);
                continue;
            }
            if (s[i] == str_char) in_str = 0;
            continue;
        }
        if (s[i] == '#') { in_comment = 1; strbuf_append_char(&tmp2, s[i]); continue; }
        if (s[i] == '"') {
            in_str = 1; str_char = '"';
            strbuf_append_char(&tmp2, s[i]);
            continue;
        }

        /* No space before comma */
        if (s[i] == ',') {
            while (tmp2.len > 0 && tmp2.data[tmp2.len - 1] == ' ') {
                tmp2.len--;
                tmp2.data[tmp2.len] = '\0';
            }
            strbuf_append_char(&tmp2, ',');
            if (i + 1 < len && s[i + 1] != ' ' && s[i + 1] != '\0') {
                strbuf_append_char(&tmp2, ' ');
            }
            continue;
        }

        /* No space inside brackets/parens at open */
        if ((s[i] == '(' || s[i] == '[' || s[i] == '{') && i + 1 < len && s[i + 1] == ' ') {
            strbuf_append_char(&tmp2, s[i]);
            i++; /* skip the space */
            while (i + 1 < len && s[i + 1] == ' ') i++;
            continue;
        }

        /* No space inside brackets/parens at close */
        if (s[i] == ')' || s[i] == ']' || s[i] == '}') {
            while (tmp2.len > 0 && tmp2.data[tmp2.len - 1] == ' ') {
                tmp2.len--;
                tmp2.data[tmp2.len] = '\0';
            }
            strbuf_append_char(&tmp2, s[i]);
            continue;
        }

        strbuf_append_char(&tmp2, s[i]);
    }

    /* Third pass: fix symbolic operator spacing (==, !=, <=, >=, <, >, +, *, /, %) */
    strbuf tmp3;
    strbuf_init(&tmp3);
    in_str = 0;
    str_char = 0;
    in_comment = 0;
    s = tmp2.data;
    len = (int)tmp2.len;

    for (int i = 0; i < len; i++) {
        if (in_comment) {
            strbuf_append_char(&tmp3, s[i]);
            continue;
        }
        if (in_str) {
            strbuf_append_char(&tmp3, s[i]);
            if (s[i] == '\\' && i + 1 < len) {
                strbuf_append_char(&tmp3, s[++i]);
                continue;
            }
            if (s[i] == str_char) in_str = 0;
            continue;
        }
        if (s[i] == '#') { in_comment = 1; strbuf_append_char(&tmp3, s[i]); continue; }
        if (s[i] == '"') {
            in_str = 1; str_char = '"';
            strbuf_append_char(&tmp3, s[i]);
            continue;
        }

        /* Multi-char operators, copied whole from the source. The length is
         * the lexer's; a spelling only the single-char branches know gets a
         * space inside it (#729). */
        {
            int oplen = lexer_operator_len(s + i, NULL);
            if (oplen > 1) {
                if (tmp3.len > 0 && tmp3.data[tmp3.len - 1] != ' ')
                    strbuf_append_char(&tmp3, ' ');
                strbuf_append_n(&tmp3, s + i, oplen);
                i += oplen - 1;
                if (i + 1 < len && s[i + 1] != ' ')
                    strbuf_append_char(&tmp3, ' ');
                continue;
            }
        }
        /* Single-char < > */
        if (s[i] == '<' || s[i] == '>') {
            if (tmp3.len > 0 && tmp3.data[tmp3.len - 1] != ' ')
                strbuf_append_char(&tmp3, ' ');
            strbuf_append_char(&tmp3, s[i]);
            if (i + 1 < len && s[i + 1] != ' ' && s[i + 1] != '=')
                strbuf_append_char(&tmp3, ' ');
            continue;
        }
        /* Arithmetic: +, *, /, % */
        if (s[i] == '+' || s[i] == '*' || s[i] == '/' || s[i] == '%') {
            /* ...but the '+' of 1.5e+10 is part of the literal, not an operator */
            if (is_exponent_sign(s, len, i)) {
                strbuf_append_char(&tmp3, s[i]);
                continue;
            }
            if (tmp3.len > 0 && tmp3.data[tmp3.len - 1] != ' ')
                strbuf_append_char(&tmp3, ' ');
            strbuf_append_char(&tmp3, s[i]);
            if (i + 1 < len && s[i + 1] != ' ')
                strbuf_append_char(&tmp3, ' ');
            continue;
        }

        strbuf_append_char(&tmp3, s[i]);
    }

    strbuf_append_n(out, tmp3.data, tmp3.len);

    strbuf_free(&tmp);
    strbuf_free(&tmp2);
    strbuf_free(&tmp3);
}

/* Strip trailing whitespace from a strbuf */
static void strip_trailing_ws(strbuf *b) {
    while (b->len > 0 && (b->data[b->len - 1] == ' ' || b->data[b->len - 1] == '\t')) {
        b->len--;
        b->data[b->len] = '\0';
    }
}

/* ---- Main formatter ---- */

/* Format EigenScript source text. Returns a malloc'd formatted string
 * (caller frees). Pure string→string with no I/O, so it is shared by the
 * CLI (--fmt) and the LSP formatting provider. */
char* format_source_string(const char *source) {
    strbuf output;
    strbuf_init(&output);

    /*
     * Phase 1: collect all lines with their original indentation widths.
     * Phase 2 follows the same push/pop shape as the lexer's indentation
     * stack.  EigenScript requires a line in a child block to be indented
     * more than its parent, but does not require every block to use the same
     * width.  Dividing widths by one global unit therefore loses structure.
     */

    /* First pass: count lines */
    int line_count = 0;
    {
        const char *p = source;
        while (*p) {
            if (*p == '\n') line_count++;
            p++;
        }
        line_count++; /* last line may not end with \n */
    }

    /* Collect lines */
    char **lines = xcalloc_array(line_count + 1, sizeof(char *));
    int *indents = xcalloc_array(line_count + 1, sizeof(int));
    int actual_lines = 0;
    {
        const char *p = source;
        while (*p) {
            const char *start = p;
            while (*p && *p != '\n') p++;
            int llen = (int)(p - start);
            if (*p == '\n') p++;

            char *line = xmalloc(llen + 1);
            memcpy(line, start, llen);
            line[llen] = '\0';

            /* Strip \r */
            if (llen > 0 && line[llen - 1] == '\r') {
                line[llen - 1] = '\0';
                llen--;
            }

            indents[actual_lines] = measure_indent(line);

            /* Store the stripped (no leading whitespace) version */
            const char *stripped = line;
            while (*stripped == ' ' || *stripped == '\t') stripped++;

            /* Strip trailing whitespace */
            int slen = (int)strlen(stripped);
            char *trimmed = xmalloc(slen + 1);
            memcpy(trimmed, stripped, slen + 1);
            while (slen > 0 && (trimmed[slen - 1] == ' ' || trimmed[slen - 1] == '\t')) {
                slen--;
            }
            trimmed[slen] = '\0';

            lines[actual_lines] = trimmed;
            free(line);
            actual_lines++;
        }
    }

    /* Convert indentation widths to structural depths.  Blank and comment-only
     * lines do not affect the lexer indentation stack, so neither may they
     * create a formatter depth. */
    int *levels = xcalloc_array(line_count + 1, sizeof(int));
    int *indent_stack = xcalloc_array(line_count + 1, sizeof(int));
    int indent_top = 0;
    int bracket_depth = 0;
    int in_string = 0;
    indent_stack[0] = 0;
    for (int i = 0; i < actual_lines; i++) {
        int continuation = bracket_depth > 0;
        update_bracket_depth(lines[i], &bracket_depth, &in_string);
        if (continuation) {
            levels[i] = indent_top;
            continue;
        }
        if (lines[i][0] == '\0' || lines[i][0] == '#') {
            levels[i] = indent_top;
            continue;
        }
        if (indents[i] > indent_stack[indent_top]) {
            indent_stack[++indent_top] = indents[i];
        } else {
            while (indent_top > 0 && indents[i] < indent_stack[indent_top]) {
                indent_top--;
            }
            /* A non-matching dedent is already invalid source.  Keep it at
             * the nearest surviving depth rather than inventing a new block. */
        }
        levels[i] = indent_top;
    }

    /* Now emit formatted output */
    int prev_blank = 0;
    int prev_was_toplevel_define = 0;

    for (int i = 0; i < actual_lines; i++) {
        const char *trimmed = lines[i];
        int slen = (int)strlen(trimmed);

        /* Blank line handling */
        if (slen == 0) {
            if (!prev_blank) {
                strbuf_append_char(&output, '\n');
            }
            prev_blank = 1;
            continue;
        }
        prev_blank = 0;

        int level = levels[i];

        /* Insert blank line between top-level define blocks */
        if (level == 0 && strncmp(trimmed, "define ", 7) == 0 && prev_was_toplevel_define) {
            /* Ensure blank line separator */
            if (output.len > 0 && output.data[output.len - 1] != '\n') {
                strbuf_append_char(&output, '\n');
            }
            /* Check if there's already a blank line */
            if (output.len >= 2 && output.data[output.len - 1] == '\n' &&
                output.data[output.len - 2] != '\n') {
                strbuf_append_char(&output, '\n');
            }
        }

        /* Emit indentation: level * 4 spaces */
        for (int j = 0; j < level * 4; j++) {
            strbuf_append_char(&output, ' ');
        }

        /* Apply spacing fixes */
        strbuf fixed_line;
        strbuf_init(&fixed_line);
        fix_spacing(trimmed, &fixed_line);
        strip_trailing_ws(&fixed_line);

        strbuf_append_n(&output, fixed_line.data, fixed_line.len);
        strbuf_append_char(&output, '\n');
        strbuf_free(&fixed_line);

        /* Track top-level define for blank line insertion */
        if (level == 0 && strncmp(trimmed, "define ", 7) == 0) {
            prev_was_toplevel_define = 1;
        } else if (level == 0 && trimmed[0] != '#') {
            prev_was_toplevel_define = 0;
        }
    }

    /* Ensure file ends with exactly one newline */
    while (output.len > 1 && output.data[output.len - 1] == '\n' &&
           output.data[output.len - 2] == '\n') {
        output.len--;
        output.data[output.len] = '\0';
    }
    if (output.len == 0 || output.data[output.len - 1] != '\n') {
        strbuf_append_char(&output, '\n');
    }

    for (int i = 0; i < actual_lines; i++) free(lines[i]);
    free(lines);
    free(indents);
    free(levels);
    free(indent_stack);
    return strbuf_finish(&output);  /* transfer ownership to caller */
}

int eigenscript_fmt(const char *path, int write_mode) {
#if EIGENSCRIPT_FREESTANDING
    (void)path; (void)write_mode;
    return 1;   /* --fmt is a host-CLI tool; no filesystem here */
#else
    long src_size = 0;
    char *source = read_file_util(path, &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", path);
        return 1;
    }

    char *formatted = format_source_string(source);
    free(source);
    if (!formatted) return 1;
    size_t flen = strlen(formatted);

    if (write_mode) {
        FILE *fp = xfopen_write(path, "w");
        if (!fp) {
            fprintf(stderr, "Error: cannot write to '%s'\n", path);
            free(formatted);
            return 1;
        }
        fwrite(formatted, 1, flen, fp);
        fclose(fp);
    } else {
        fwrite(formatted, 1, flen, stdout);
    }

    free(formatted);
    return 0;
#endif /* !EIGENSCRIPT_FREESTANDING */
}
