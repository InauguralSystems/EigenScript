/*
 * EigenScript formatter — line-based source formatter.
 * Applies consistent indentation, operator spacing, and whitespace rules.
 *
 * Strategy: use the ORIGINAL indentation to determine nesting level,
 * normalize to 4-space indentation, and apply spacing fixups.
 */

#include "eigenscript.h"

/* ---- helpers ---- */

/* Measure leading whitespace in columns (tabs count as 4 spaces) */
static int measure_indent(const char *line) {
    int col = 0;
    while (*line == ' ' || *line == '\t') {
        if (*line == '\t') col = (col / 4 + 1) * 4;
        else col++;
        line++;
    }
    return col;
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

        /* Two-char operators */
        if (i + 1 < len) {
            char two[3] = {s[i], s[i+1], 0};
            if (strcmp(two, "==") == 0 || strcmp(two, "!=") == 0 ||
                strcmp(two, "<=") == 0 || strcmp(two, ">=") == 0) {
                if (tmp3.len > 0 && tmp3.data[tmp3.len - 1] != ' ')
                    strbuf_append_char(&tmp3, ' ');
                strbuf_append_char(&tmp3, s[i]);
                strbuf_append_char(&tmp3, s[i+1]);
                i++;
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

int eigenscript_fmt(const char *path, int write_mode) {
    long src_size = 0;
    char *source = read_file_util(path, &src_size);
    if (!source) {
        fprintf(stderr, "Error: cannot read file '%s'\n", path);
        return 1;
    }

    strbuf output;
    strbuf_init(&output);

    /*
     * Phase 1: collect all lines with their original indent levels.
     * Then determine the indent "unit" used in the source (minimum non-zero indent).
     * Normalize all indentation to 4-space units.
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

    /* Find the minimum non-zero indent level to determine the "unit" */
    int min_indent = 0;
    for (int i = 0; i < actual_lines; i++) {
        if (indents[i] > 0 && lines[i][0] != '\0') {
            if (min_indent == 0 || indents[i] < min_indent) {
                min_indent = indents[i];
            }
        }
    }
    if (min_indent == 0) min_indent = 4; /* default */

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

        /* Calculate normalized indent level */
        int level = indents[i] / min_indent;

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

    if (write_mode) {
        FILE *fp = xfopen_write(path, "w");
        if (!fp) {
            fprintf(stderr, "Error: cannot write to '%s'\n", path);
            for (int i = 0; i < actual_lines; i++) free(lines[i]);
            free(lines);
            free(indents);
            strbuf_free(&output);
            free(source);
            return 1;
        }
        fwrite(output.data, 1, output.len, fp);
        fclose(fp);
    } else {
        fwrite(output.data, 1, output.len, stdout);
    }

    for (int i = 0; i < actual_lines; i++) free(lines[i]);
    free(lines);
    free(indents);
    strbuf_free(&output);
    free(source);
    return 0;
}
