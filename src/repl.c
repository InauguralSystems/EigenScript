/*
 * EigenScript REPL — the CLI read-eval-print loop (#392).
 *
 * Two input paths sharing one eval body:
 *  - piped / non-tty stdin: the original fgets loop, byte-identical to the
 *    pre-#392 REPL (the suite pipes scripts through the binary and greps
 *    the transcript — see tests/test_cli.sh CLI09–CLI13);
 *  - interactive tty: a zero-dependency raw-termios line editor ported from
 *    the EigenOS console editor (EigenOS src/hal.c, eigs_repl) — history
 *    with draft parking, cursor editing, and tab completion over the live
 *    global env (builtins are env bindings, so one walk covers builtins and
 *    session names alike). No readline/libedit: the zero-dep invariant is
 *    load-bearing for embedding, which is also why this file, like main.c,
 *    stays out of the runtime library (LSP/embed/fuzz/amalgamation builds).
 *
 * Cursor-column math is per-byte (like classic linenoise): multi-byte UTF-8
 * input is stored and submitted correctly, but the visual cursor drifts
 * while editing such a line. Bytes-forever (#416) makes this acceptable.
 */

#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "trace.h"
#include "repl.h"

#ifndef EIGENSCRIPT_VERSION
#define EIGENSCRIPT_VERSION "dev"
#endif

#include <termios.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/stat.h>
#include <fcntl.h>

/* ---- shared eval body ----
 * Tokenize/parse/compile/run one accumulated input buffer and print the
 * result. Returns 1 when the REPL must stop (`exit of N` ran), else 0.
 * Output bytes are identical to the pre-#392 inline code; the one change
 * is free_ast on the parse-error path (parse returns a partial tree on
 * error — cf. #214 — which the old loop leaked). */
static int repl_eval_buffer(Env *env, strbuf *input) {
    /* Skip empty input */
    char *check = input->data;
    while (*check == ' ' || *check == '\t' || *check == '\n' || *check == '\r') check++;
    if (*check == '\0') return 0;

    g_parse_errors = 0;
    TokenList tl = tokenize(input->data);
    if (g_parse_errors > 0) {
        free_tokenlist(&tl);
        return 0;
    }

    parser_set_caret_source(input->data); /* #407: excerpt+caret on col errors */
    ASTNode *ast = parse(&tl);
    parser_set_caret_source(NULL);
    if (g_parse_errors > 0) {
        free_ast(ast);
        free_tokenlist(&tl);
        return 0;
    }

    g_returning = 0;
    g_return_val = NULL;
    g_has_error = 0;   /* don't carry a prior line's error into this one */
    EigsChunk *repl_chunk = compile_ast(ast, env);
    if (g_parse_errors > 0) {   /* e.g. an un-encodable jump/loop offset */
        fprintf(stderr, "%d compile error(s) — line not run\n", g_parse_errors);
        chunk_free(repl_chunk);
        free_tokenlist(&tl);
        free_ast(ast);
        return 0;
    }
    Value *result = vm_execute(repl_chunk, env);
    if (g_exit_requested) {                 /* `exit of N` typed at the REPL */
        g_has_error = 0;
        chunk_free(repl_chunk);
        if (result) val_decref(result);
        free_tokenlist(&tl);
        free_ast(ast);
        return 1;
    }
    /* Chunks are refcounted: drop the creator ref. Functions defined
     * on this line hold their own refs on their nested chunks. */
    chunk_free(repl_chunk);

    /* Print non-null results */
    if (result && result->type != VAL_NULL) {
        char *s = value_to_string(result);
        printf("=> %s\n", s);
        free(s);
    }
    if (result) val_decref(result);

    free_tokenlist(&tl);
    /* Function bodies are cloned (AST fns) or compiled into chunks
     * (bytecode fns), so the per-line AST is safe to free. */
    free_ast(ast);
    return 0;
}

/* ---- piped / non-tty path: the original fgets loop ---- */

static void repl_plain(Env *env) {
    char line_buf[4096];
    strbuf input;
    strbuf_init(&input);
    int continuation = 0;

    while (1) {
        printf(continuation ? "...   " : "eigs> ");
        fflush(stdout);

        if (!fgets(line_buf, sizeof(line_buf), stdin)) {
            printf("\n");
            break;
        }

        /* Exit commands */
        if (!continuation) {
            char *trimmed = line_buf;
            while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
            if (strcmp(trimmed, "exit\n") == 0 || strcmp(trimmed, "quit\n") == 0 ||
                strcmp(trimmed, "exit\r\n") == 0 || strcmp(trimmed, "quit\r\n") == 0) {
                break;
            }
        }

        int len = strlen(line_buf);
        strbuf_append_n(&input, line_buf, (size_t)len);

        /* Multi-line detection */
        if (!continuation) {
            /* Check if line ends with colon (block opener) */
            char *end = line_buf + len - 1;
            while (end > line_buf && (*end == '\n' || *end == '\r' || *end == ' ')) end--;
            if (*end == ':') {
                continuation = 1;
                continue;
            }
        } else {
            /* In continuation: blank line or unindented line ends block */
            char *trimmed = line_buf;
            while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
            if (*trimmed == '\n' || *trimmed == '\r' || *trimmed == '\0') {
                continuation = 0;
                /* fall through to execute */
            } else if (line_buf[0] == ' ' || line_buf[0] == '\t') {
                continue; /* still indented, keep accumulating */
            } else {
                continuation = 0;
                /* unindented non-blank: end of block */
            }
        }

        if (repl_eval_buffer(env, &input)) break;
        input.len = 0;
        input.data[0] = '\0';
    }
    strbuf_free(&input);
}

/* ---- interactive tty path: the line editor ---- */

#define ED_BUF   4096
#define ED_HIST  500

enum { K_UP = 1000, K_DOWN, K_RIGHT, K_LEFT, K_HOME, K_END, K_DEL };
enum { RL_EOF = -1, RL_CANCEL = -2 };

static char *g_hist[ED_HIST];      /* oldest at [0], newest at [g_hist_n-1] */
static int   g_hist_n;

static struct termios g_orig_termios;
static int g_raw_active = 0;

/* TCSADRAIN, not TCSAFLUSH: raw mode toggles around every eval, and
 * TCSAFLUSH discards type-ahead — a line pasted (or piped by the pty test
 * harness) while the previous line was still evaluating would vanish. */
static void raw_off(void) {
    if (g_raw_active) {
        tcsetattr(STDIN_FILENO, TCSADRAIN, &g_orig_termios);
        g_raw_active = 0;
    }
}

static int raw_on(void) {
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, &g_orig_termios) == -1) return -1;
    raw = g_orig_termios;
    raw.c_iflag &= ~(tcflag_t)(BRKINT | ICRNL | INPCK | ISTRIP | IXON);
    /* OPOST stays on: "\n" from printf/the editor still renders CRNL. */
    raw.c_lflag &= ~(tcflag_t)(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_cc[VMIN] = 1;
    raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSADRAIN, &raw) == -1) return -1;
    g_raw_active = 1;
    return 0;
}

static int term_cols(void) {
    struct winsize ws;
    if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0)
        return (int)ws.ws_col;
    return 80;
}

static void ed_write(const char *s, size_t n) {
    ssize_t off = 0;
    while (off < (ssize_t)n) {
        ssize_t w = write(STDOUT_FILENO, s + off, n - off);
        if (w <= 0) return;
        off += w;
    }
}

/* ---- history ---- */

static const char *hist_path(void) {
    static char path[4096];
    const char *p = getenv("EIGS_HISTORY");
    if (p && *p) return p;
    const char *home = getenv("HOME");
    if (!home || !*home) return NULL;
    snprintf(path, sizeof(path), "%s/.eigenscript_history", home);
    return path;
}

/* In-memory add: dedupe against the newest entry, drop the oldest at cap. */
static void hist_add_mem(const char *line) {
    if (!*line) return;
    if (g_hist_n > 0 && strcmp(g_hist[g_hist_n - 1], line) == 0) return;
    if (g_hist_n == ED_HIST) {
        free(g_hist[0]);
        memmove(g_hist, g_hist + 1, sizeof(char *) * (ED_HIST - 1));
        g_hist_n--;
    }
    g_hist[g_hist_n++] = strdup(line);
}

static void hist_load(void) {
    const char *p = hist_path();
    if (!p) return;
    FILE *f = fopen(p, "r");
    if (!f) return;
    char buf[ED_BUF];
    while (fgets(buf, sizeof(buf), f)) {
        size_t n = strlen(buf);
        while (n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r')) buf[--n] = '\0';
        hist_add_mem(buf);
    }
    fclose(f);
}

/* Rewrite (and thereby truncate) the file from the in-memory ring; created
 * 0600 — session history can hold secrets, same posture as bash. */
static void hist_save(void) {
    const char *p = hist_path();
    if (!p) return;
    int fd = open(p, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return;
    FILE *f = fdopen(fd, "w");
    if (!f) { close(fd); return; }
    for (int i = 0; i < g_hist_n; i++) fprintf(f, "%s\n", g_hist[i]);
    fclose(f);
}

static void hist_free(void) {
    for (int i = 0; i < g_hist_n; i++) free(g_hist[i]);
    g_hist_n = 0;
}

/* ---- key input ---- */

static int rd_byte(unsigned char *c) {
    ssize_t n;
    do { n = read(STDIN_FILENO, c, 1); } while (n == -1 && errno == EINTR);
    return n == 1;
}

/* Short-timeout read for ESC-sequence continuation bytes: a bare ESC
 * keypress must not wedge the editor waiting for a '[' that never comes. */
static int rd_byte_t(unsigned char *c) {
    fd_set r;
    struct timeval tv = { 0, 50000 };   /* 50 ms */
    FD_ZERO(&r);
    FD_SET(STDIN_FILENO, &r);
    if (select(STDIN_FILENO + 1, &r, NULL, NULL, &tv) != 1) return 0;
    return rd_byte(c);
}

/* One keypress -> a byte, a K_* code, or -1 on EOF/error. Unrecognized
 * escape sequences are swallowed (returned as 0, ignored by the caller). */
static int ed_getkey(void) {
    unsigned char c;
    if (!rd_byte(&c)) return -1;
    if (c != 27) return c;
    unsigned char s0, s1;
    if (!rd_byte_t(&s0)) return 0;           /* bare ESC: ignore */
    if (s0 == '[') {
        if (!rd_byte_t(&s1)) return 0;
        switch (s1) {
        case 'A': return K_UP;
        case 'B': return K_DOWN;
        case 'C': return K_RIGHT;
        case 'D': return K_LEFT;
        case 'H': return K_HOME;
        case 'F': return K_END;
        default:
            if (s1 >= '0' && s1 <= '9') {
                unsigned char s2;
                if (!rd_byte_t(&s2)) return 0;
                if (s2 == '~') {
                    if (s1 == '1' || s1 == '7') return K_HOME;
                    if (s1 == '4' || s1 == '8') return K_END;
                    if (s1 == '3') return K_DEL;
                }
            }
            return 0;
        }
    }
    if (s0 == 'O') {
        if (!rd_byte_t(&s1)) return 0;
        if (s1 == 'H') return K_HOME;
        if (s1 == 'F') return K_END;
        return 0;
    }
    return 0;
}

/* ---- rendering ---- */

typedef struct {
    char buf[ED_BUF];
    int len, cur;
    const char *prompt;
    int plen;
    int nav;                    /* history offset; -1 = editing the draft */
    char draft[ED_BUF];
    int draft_len;
} EdState;

/* Repaint the whole line: prompt + a horizontally-scrolled window of the
 * buffer sized to the terminal, erase rightward residue, park the cursor. */
static void ed_refresh(EdState *e) {
    int cols = term_cols();
    int avail = cols - e->plen - 1;
    if (avail < 1) avail = 1;
    int start = 0;
    if (e->cur >= avail) start = e->cur - avail + 1;
    int show = e->len - start;
    if (show > avail) show = avail;

    char out[ED_BUF + 256];
    int o = 0;
    out[o++] = '\r';
    memcpy(out + o, e->prompt, (size_t)e->plen); o += e->plen;
    memcpy(out + o, e->buf + start, (size_t)show); o += show;
    memcpy(out + o, "\x1b[0K\r", 5); o += 5;      /* erase right, col 0 */
    int col = e->plen + (e->cur - start);
    if (col > 0) o += snprintf(out + o, sizeof(out) - (size_t)o, "\x1b[%dC", col);
    ed_write(out, (size_t)o);
}

/* ---- tab completion over the live env chain ----
 * Builtins are ordinary bindings in the global env (register_builtins), so
 * walking env->names covers builtins and session top-level names in one
 * pass. Word chars include '.' for dotted module bindings. */

static int ed_word_char(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_' || c == '.';
}

static int cmp_str(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

#define COMP_MAX 512

static void ed_complete(EdState *e, Env *env) {
    int ws = e->cur;
    while (ws > 0 && ed_word_char(e->buf[ws - 1])) ws--;
    int wlen = e->cur - ws;
    if (wlen == 0) { ed_write("\a", 1); return; }

    const char *m[COMP_MAX];
    int n = 0;
    for (Env *scope = env; scope; scope = scope->parent) {
        for (int i = 0; i < scope->count && n < COMP_MAX; i++) {
            const char *name = scope->names[i];
            if (!name) continue;
            if (strncmp(name, e->buf + ws, (size_t)wlen) != 0) continue;
            int dup = 0;
            for (int j = 0; j < n; j++)
                if (strcmp(m[j], name) == 0) { dup = 1; break; }
            if (!dup) m[n++] = name;
        }
    }
    if (n == 0) { ed_write("\a", 1); return; }

    qsort(m, (size_t)n, sizeof(char *), cmp_str);

    /* Longest common prefix across the matches. */
    int lcp = (int)strlen(m[0]);
    for (int i = 1; i < n; i++) {
        int k = 0;
        while (k < lcp && m[i][k] == m[0][k]) k++;
        lcp = k;
    }

    if (lcp > wlen) {                       /* extend in place */
        int add = lcp - wlen;
        if (e->len + add >= ED_BUF - 1) return;
        memmove(e->buf + e->cur + add, e->buf + e->cur, (size_t)(e->len - e->cur));
        memcpy(e->buf + e->cur, m[0] + wlen, (size_t)add);
        e->len += add;
        e->cur += add;
        ed_refresh(e);
        return;
    }
    if (n == 1) return;                     /* already complete */

    /* Ambiguous with nothing to extend: list candidates, then repaint. */
    int cols = term_cols();
    int col = 0;
    ed_write("\n", 1);
    for (int i = 0; i < n; i++) {
        int w = (int)strlen(m[i]) + 2;
        if (col > 0 && col + w > cols) { ed_write("\n", 1); col = 0; }
        ed_write(m[i], strlen(m[i]));
        ed_write("  ", 2);
        col += w;
    }
    ed_write("\n", 1);
    ed_refresh(e);
}

/* ---- the editor ----
 * Returns the line length (buf NUL-terminated), RL_EOF on Ctrl-D at an
 * empty line, RL_CANCEL on Ctrl-C (which also abandons any open block). */
static int ed_readline(Env *env, EdState *e, const char *prompt, char *out) {
    e->len = e->cur = 0;
    e->draft_len = 0;
    e->nav = -1;
    e->prompt = prompt;
    e->plen = (int)strlen(prompt);
    ed_write("\r", 1);
    ed_write(prompt, (size_t)e->plen);

    for (;;) {
        int c = ed_getkey();
        if (c == -1) {                       /* stdin EOF/error */
            ed_write("\n", 1);
            return e->len > 0 ? (memcpy(out, e->buf, (size_t)e->len),
                                 out[e->len] = '\0', e->len)
                              : RL_EOF;
        }
        if (c == 0) continue;                /* swallowed escape */

        switch (c) {
        case '\r':
        case '\n':
            e->buf[e->len] = '\0';
            ed_write("\n", 1);
            memcpy(out, e->buf, (size_t)e->len + 1);
            return e->len;

        case 3:                              /* Ctrl-C: cancel line + block */
            ed_write("^C\n", 3);
            return RL_CANCEL;

        case 4:                              /* Ctrl-D: EOF if empty, else delete */
            if (e->len == 0) { ed_write("\n", 1); return RL_EOF; }
            /* fall through */
        case K_DEL:
            if (e->cur < e->len) {
                memmove(e->buf + e->cur, e->buf + e->cur + 1,
                        (size_t)(e->len - e->cur - 1));
                e->len--;
                ed_refresh(e);
            }
            break;

        case 8:                              /* Ctrl-H */
        case 127:                            /* Backspace */
            if (e->cur > 0) {
                memmove(e->buf + e->cur - 1, e->buf + e->cur,
                        (size_t)(e->len - e->cur));
                e->len--; e->cur--;
                ed_refresh(e);
            }
            break;

        case K_LEFT:
            if (e->cur > 0) { e->cur--; ed_refresh(e); }
            break;
        case K_RIGHT:
            if (e->cur < e->len) { e->cur++; ed_refresh(e); }
            break;
        case 1: /* Ctrl-A */
        case K_HOME:
            e->cur = 0; ed_refresh(e);
            break;
        case 5: /* Ctrl-E */
        case K_END:
            e->cur = e->len; ed_refresh(e);
            break;

        case K_UP:
        case K_DOWN:
            if (g_hist_n == 0) break;
            if (c == K_UP) {
                if (e->nav + 1 >= g_hist_n) break;
                if (e->nav == -1) {          /* park the in-progress line */
                    memcpy(e->draft, e->buf, (size_t)e->len);
                    e->draft_len = e->len;
                }
                e->nav++;
            } else {
                if (e->nav == -1) break;
                e->nav--;
            }
            if (e->nav == -1) {
                memcpy(e->buf, e->draft, (size_t)e->draft_len);
                e->len = e->draft_len;
            } else {
                const char *h = g_hist[g_hist_n - 1 - e->nav];
                e->len = (int)strlen(h);
                if (e->len > ED_BUF - 1) e->len = ED_BUF - 1;
                memcpy(e->buf, h, (size_t)e->len);
            }
            e->cur = e->len;
            ed_refresh(e);
            break;

        case 21:                             /* Ctrl-U: clear the line */
            e->len = e->cur = 0;
            ed_refresh(e);
            break;
        case 11:                             /* Ctrl-K: kill to end */
            e->len = e->cur;
            ed_refresh(e);
            break;
        case 23:                             /* Ctrl-W: delete word left */
            if (e->cur > 0) {
                int p = e->cur;
                while (p > 0 && e->buf[p - 1] == ' ') p--;
                while (p > 0 && e->buf[p - 1] != ' ') p--;
                memmove(e->buf + p, e->buf + e->cur, (size_t)(e->len - e->cur));
                e->len -= e->cur - p;
                e->cur = p;
                ed_refresh(e);
            }
            break;
        case 12:                             /* Ctrl-L: clear screen */
            ed_write("\x1b[H\x1b[2J", 7);
            ed_refresh(e);
            break;
        case '\t':
            ed_complete(e, env);
            break;

        default:
            /* Insert byte (>=128 kept for UTF-8 content; see header note). */
            if (c >= 32 && c != 127 && e->len < ED_BUF - 1) {
                memmove(e->buf + e->cur + 1, e->buf + e->cur,
                        (size_t)(e->len - e->cur));
                e->buf[e->cur] = (char)c;
                e->len++; e->cur++;
                ed_refresh(e);
            }
            break;
        }
    }
}

static void repl_interactive(Env *env) {
    /* Temporal interrogatives on session bindings: in a script the compiler
     * flips these when it sees a temporal query, but the REPL compiles line
     * by line — `x is 5` would record nothing and a later `prev of x` finds
     * no history. Interactive sessions record from the start (the piped
     * path is left untouched: byte-identical output is its contract). */
    g_trace_hist = 1;
    g_trace_obs_hist = 1;

    hist_load();
    atexit(raw_off);   /* never leave the terminal raw, whatever the exit path */

    char line[ED_BUF];
    static EdState ed;             /* ~12 KiB: static, not stack (PR #361 rule) */
    strbuf input;
    strbuf_init(&input);
    int continuation = 0;

    for (;;) {
        if (raw_on() == -1) break;
        int len = ed_readline(env, &ed, continuation ? "...   " : "eigs> ", line);
        raw_off();     /* cooked during eval: scripts may read stdin; SIGINT works */

        if (len == RL_EOF) break;
        if (len == RL_CANCEL) {
            continuation = 0;
            input.len = 0;
            input.data[0] = '\0';
            continue;
        }

        if (len > 0) hist_add_mem(line);

        /* Exit commands (top level only, same rule as the piped path) */
        if (!continuation) {
            char *trimmed = line;
            while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
            if (strcmp(trimmed, "exit") == 0 || strcmp(trimmed, "quit") == 0) break;
        }

        strbuf_append_n(&input, line, (size_t)len);
        strbuf_append_n(&input, "\n", 1);

        /* Multi-line block rules, identical to the piped path */
        if (!continuation) {
            int e = len;
            while (e > 0 && line[e - 1] == ' ') e--;
            if (e > 0 && line[e - 1] == ':') {
                continuation = 1;
                continue;
            }
        } else {
            char *trimmed = line;
            while (*trimmed == ' ' || *trimmed == '\t') trimmed++;
            if (*trimmed == '\0') {
                continuation = 0;            /* blank line: run the block */
            } else if (line[0] == ' ' || line[0] == '\t') {
                continue;                    /* still indented, accumulate */
            } else {
                continuation = 0;            /* unindented: ends + included */
            }
        }

        if (repl_eval_buffer(env, &input)) break;
        input.len = 0;
        input.data[0] = '\0';
    }

    strbuf_free(&input);
    hist_save();
    hist_free();
}

/* ---- entry ---- */

static int repl_use_editor(void) {
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) return 0;
    if (getenv("EIGS_REPL_PLAIN")) return 0;   /* escape hatch / test hook */
    const char *t = getenv("TERM");
    if (!t || strcmp(t, "dumb") == 0 || strcmp(t, "cons25") == 0 ||
        strcmp(t, "emacs") == 0) return 0;
    return 1;
}

void eigenscript_repl(Env *env) {
    printf("EigenScript %s\n", EIGENSCRIPT_VERSION);
    printf("Type 'exit' or Ctrl-D to quit.\n\n");
    fflush(stdout);

    if (repl_use_editor())
        repl_interactive(env);
    else
        repl_plain(env);
}
