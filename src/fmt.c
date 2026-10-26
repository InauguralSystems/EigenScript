/*
 * EigenScript formatter — line-based source formatter.
 * Applies consistent indentation, operator spacing, and whitespace rules.
 *
 * Strategy: consume the lexer's literal spans and layout depths, normalize
 * each real block level to four spaces, and apply spacing only outside
 * literal bytes.
 */

#include "eigenscript.h"
#include "fsutil.h"
#include "state.h"

/* ---- helpers ---- */

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

/* Fix operator spacing on a literal-free source fragment.  Literal ranges are
 * supplied by the lexer and never enter this function. */
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
    int in_comment = 0;

    for (int i = 0; i < len; i++) {
        if (in_comment) {
            strbuf_append_char(&tmp, buf[i]);
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
    in_comment = 0;
    const char *s = tmp.data;
    len = (int)tmp.len;

    for (int i = 0; i < len; i++) {
        if (in_comment) {
            strbuf_append_char(&tmp2, s[i]);
            continue;
        }
        if (s[i] == '#') { in_comment = 1; strbuf_append_char(&tmp2, s[i]); continue; }

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
    in_comment = 0;
    s = tmp2.data;
    len = (int)tmp2.len;

    for (int i = 0; i < len; i++) {
        if (in_comment) {
            strbuf_append_char(&tmp3, s[i]);
            continue;
        }
        if (s[i] == '#') { in_comment = 1; strbuf_append_char(&tmp3, s[i]); continue; }

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
    EigsState *temporary_state = NULL;
    if (!eigs_current) {
        temporary_state = eigs_state_new();
        eigs_thread_attach(temporary_state);
    }
    int errors_before = g_parse_errors;
    TokenList tl = tokenize(source);
    if (g_parse_errors != errors_before) {
        free_tokenlist(&tl);
        if (temporary_state) { eigs_thread_detach(); eigs_state_destroy(temporary_state); }
        return NULL;              /* lexer already printed its precise error */
    }

    int line_count = 1;
    for (const char *p = source; *p; p++) if (*p == '\n') line_count++;
    int *depth = xcalloc_array(line_count, sizeof(*depth));
    unsigned char *continuation = xcalloc_array(line_count, 1);

    /* The lexer records the block stack depth when it accepts each physical
     * code line. A -1 row is a blank/literal line or a bracket continuation;
     * continuations deliberately retain their original leading whitespace. */
    for (int line = 0; line < line_count; line++) {
        int lexer_depth = line < tl.line_depth_count ? tl.line_depths[line] : -1;
        if (lexer_depth >= 0) depth[line] = lexer_depth;
        else continuation[line] = 1;
    }

    strbuf output;
    strbuf_init(&output);
    size_t off = 0;
    int line_no = 0, span_i = 0, prev_blank = 0;
    size_t source_len = strlen(source);
    while (off < source_len) {
        size_t end = off;
        while (end < source_len && source[end] != '\n') end++;
        size_t content_end = end;
        while (span_i < tl.literal_count && tl.literal_spans[span_i].end <= off) span_i++;
        int starts_literal = span_i < tl.literal_count &&
            tl.literal_spans[span_i].start <= off && off < tl.literal_spans[span_i].end;
        /* Normalize CRLF only in source syntax.  A CR immediately before a
         * physical LF can also be literal data, and every byte in a
         * lexer-owned literal span is sacrosanct. */
        if (content_end > off && source[content_end - 1] == '\r') {
            size_t cr = content_end - 1;
            int cr_is_literal = 0;
            for (int i = span_i; i < tl.literal_count && tl.literal_spans[i].start <= cr; i++) {
                if (cr < tl.literal_spans[i].end) { cr_is_literal = 1; break; }
            }
            if (!cr_is_literal) content_end--;
        }

        size_t first = off;
        if (!starts_literal) while (first < content_end && (source[first] == ' ' || source[first] == '\t')) first++;
        int blank = first == content_end;
        if (blank && !starts_literal) {
            if (!prev_blank) strbuf_append_char(&output, '\n');
            prev_blank = 1;
            off = end < source_len ? end + 1 : end;
            line_no++;
            continue;
        }
        prev_blank = 0;

        int level = depth[line_no];


        /* Bracket continuations deliberately retain their original leading
         * whitespace.  Other code lines are normalized to four per lexer
         * block.  A physical line beginning inside a literal is all data. */
        if (!starts_literal) {
            if (continuation[line_no]) strbuf_append_n(&output, source + off, first - off);
            else for (int j = 0; j < level * 4; j++) strbuf_append_char(&output, ' ');
        }

        size_t pos = starts_literal ? off : first;
        int si = span_i;
        while (pos < content_end) {
            while (si < tl.literal_count && tl.literal_spans[si].end <= pos) si++;
            if (si < tl.literal_count && tl.literal_spans[si].start <= pos && pos < tl.literal_spans[si].end) {
                size_t stop = tl.literal_spans[si].end < content_end ? tl.literal_spans[si].end : content_end;
                strbuf_append_n(&output, source + pos, stop - pos);
                pos = stop;
            } else {
                size_t stop = content_end;
                if (si < tl.literal_count && tl.literal_spans[si].start < stop) stop = tl.literal_spans[si].start;
                char *part = xmalloc(stop - pos + 1);
                memcpy(part, source + pos, stop - pos); part[stop - pos] = '\0';
                strbuf fixed; strbuf_init(&fixed); fix_spacing(part, &fixed);
                if (stop == content_end) strip_trailing_ws(&fixed);
                strbuf_append_n(&output, fixed.data, fixed.len);
                strbuf_free(&fixed); free(part); pos = stop;
            }
        }
        strbuf_append_char(&output, '\n');

        off = end < source_len ? end + 1 : end;
        line_no++;
    }
    while (output.len > 1 && output.data[output.len - 1] == '\n' && output.data[output.len - 2] == '\n') {
        output.data[--output.len] = '\0';
    }
    if (!output.len || output.data[output.len - 1] != '\n') strbuf_append_char(&output, '\n');
    free(depth); free(continuation); free_tokenlist(&tl);
    if (temporary_state) { eigs_thread_detach(); eigs_state_destroy(temporary_state); }
    return strbuf_finish(&output);
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
