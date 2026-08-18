/*
 * EigenScript host-only builtins (#741).
 *
 * Every builtin in this TU needs a real operating system underneath —
 * filesystem, subprocesses, a terminal, POSIX regex, /dev/urandom. The
 * whole TU is gated like ext_store.c: under EIGENSCRIPT_FREESTANDING it
 * compiles to the linkable no-op registrar (plus the resolver stub), so
 * builtins.c stays free of per-function #ifdef carve-outs and a builtin
 * that quietly grows a host dependency belongs HERE — the freestanding
 * symbol gate (tools/freestanding_check.sh) then names the leaked
 * builtin_* symbol instead of a stray libc import.
 *
 * Registration: register_builtins (builtins.c) calls
 * register_host_builtins unconditionally, inside the
 * [0, g_builtin_binding_count) builtin band.
 */

#include "eigenscript.h"
#include "state.h"
#include "vm.h"
#include "builtins_internal.h"
#include "trace.h"

#if EIGENSCRIPT_FREESTANDING

/* Linkable no-op surface for the freestanding profile (the ext_store.c
 * pattern): registration registers nothing, and nothing resolves without
 * a filesystem. */
void register_host_builtins(Env *env) { (void)env; }

int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap) {
    (void)base; (void)path; (void)resolved; (void)resolved_cap;
    return 0;   /* nothing resolves without a filesystem */
}

int resolve_eigenscript_file_from_ex(const char *base, const char *path,
                                      char *resolved, size_t resolved_cap,
                                      int *origin) {
    (void)base; (void)path; (void)resolved; (void)resolved_cap;
    if (origin) *origin = EIGS_RESOLVE_PROJECT;
    return 0;
}

#else /* host profile */

#include <termios.h>

/* ---- Terminal: raw_key of null — non-blocking single keypress read.
 * Returns the key as a string, or "" if no key pressed.
 * Sets terminal to raw mode on first call, restores on exit. ---- */

static struct termios g_orig_termios;
static int g_raw_mode = 0;

static void restore_terminal(void) {
    if (g_raw_mode) {
        tcsetattr(STDIN_FILENO, TCSAFLUSH, &g_orig_termios);
        g_raw_mode = 0;
    }
}

static void enable_raw_mode(void) {
    if (g_raw_mode) return;
    tcgetattr(STDIN_FILENO, &g_orig_termios);
    atexit(restore_terminal);
    struct termios raw = g_orig_termios;
    raw.c_lflag &= ~(ECHO | ICANON);
    raw.c_cc[VMIN] = 0;   /* non-blocking */
    raw.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw);
    g_raw_mode = 1;
}

Value* builtin_raw_key(Value *arg) {
    (void)arg;
    enable_raw_mode();
    char buf[4] = {0};
    ssize_t n = read(STDIN_FILENO, buf, sizeof(buf) - 1);
    if (n <= 0) return make_str("");
    buf[n] = '\0';
    /* Arrow keys come as ESC [ A/B/C/D */
    if (buf[0] == 27 && n >= 3 && buf[1] == '[') {
        switch (buf[2]) {
            case 'A': return make_str("up");
            case 'B': return make_str("down");
            case 'C': return make_str("right");
            case 'D': return make_str("left");
        }
    }
    return make_str(buf);
}

/* ==== BUILTIN: match — regex match, return list of groups ==== */
/* match of [string, pattern] -> [full_match, group1, ...] or [] */
Value* builtin_match(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "regex_match requires [string, pattern]");
        return make_list(0);
    }
    if (arg->data.list.items[0]->type != VAL_STR || arg->data.list.items[1]->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_match: string and pattern must be strings");
        return make_list(0);
    }
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;

    regex_t re;
    /* #500: an invalid pattern used to return [] — indistinguishable from a
     * clean no-match. Raise so a broken pattern is visible. */
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {
        rt_error(EK_VALUE, 0, "regex_match: invalid pattern '%s'", pattern);
        return make_list(0);
    }

    /* #629: size the match array from the compiled pattern (full match + one
     * slot per capture group) rather than a fixed 16. A fixed cap silently
     * dropped groups past 15; a loop CONDITION of `rm_so >= 0` also terminated
     * emission at the first non-participating optional group, deleting every
     * later capture. re_nsub is bounded by POSIX pattern complexity;
     * xmalloc_array guards the +1 and *sizeof against size_t overflow. */
    size_t ng = re.re_nsub + 1;
    regmatch_t *matches = xmalloc_array(ng, sizeof(regmatch_t));
    if (regexec(&re, str, ng, matches, 0) != 0) {
        free(matches);
        regfree(&re);
        return make_list(0);
    }

    Value *result = make_list(8);
    for (size_t i = 0; i < ng; i++) {
        /* POSIX sets rm_so = -1 for a group that didn't participate (e.g. an
         * unmatched optional (x)?). Emit null so positional indexing holds —
         * group n stays at index n — rather than stopping the loop (#629). */
        if (matches[i].rm_so < 0) {
            list_append_owned(result, make_null());
            continue;
        }
        int len = matches[i].rm_eo - matches[i].rm_so;
        char *buf = xmalloc(len + 1);
        memcpy(buf, str + matches[i].rm_so, len);
        buf[len] = '\0';
        list_append_owned(result, make_str(buf));
        free(buf);
    }
    free(matches);
    regfree(&re);
    return result;
}

/* ==== BUILTIN: match_all — find all matches of pattern ==== */
/* match_all of [string, pattern] -> [match1, match2, ...] */
Value* builtin_match_all(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "regex_find requires [string, pattern]");
        return make_list(0);
    }
    if (arg->data.list.items[0]->type != VAL_STR || arg->data.list.items[1]->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_find: string and pattern must be strings");
        return make_list(0);
    }
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;

    regex_t re;
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {           /* #500 */
        rt_error(EK_VALUE, 0, "regex_find: invalid pattern '%s'", pattern);
        return make_list(0);
    }

    Value *result = make_list(16);
    regmatch_t m[1];
    const char *p = str;
    while (regexec(&re, p, 1, m, 0) == 0) {
        int len = m[0].rm_eo - m[0].rm_so;
        char *buf = xmalloc(len + 1);
        memcpy(buf, p + m[0].rm_so, len);
        buf[len] = '\0';
        list_append_owned(result, make_str(buf));
        free(buf);
        p += m[0].rm_eo;
        if (len == 0) p++; /* avoid infinite loop on zero-length match */
        if (!*p) break;
    }
    regfree(&re);
    return result;
}

/* ==== BUILTIN: regex_replace — replace all matches ==== */
/* regex_replace of [string, pattern, replacement] -> string */
Value* builtin_regex_replace(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "regex_replace requires [string, pattern, replacement]");
        return make_str("");
    }
    if (arg->data.list.items[0]->type != VAL_STR ||
        arg->data.list.items[1]->type != VAL_STR ||
        arg->data.list.items[2]->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_replace: string, pattern and replacement must be strings");
        return make_str("");
    }
    const char *str = arg->data.list.items[0]->data.str;
    const char *pattern = arg->data.list.items[1]->data.str;
    const char *replacement = arg->data.list.items[2]->data.str;

    regex_t re;
    /* #500: an invalid pattern used to return the input unchanged — a silent
     * no-op that hides the broken pattern. Raise. */
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {
        rt_error(EK_VALUE, 0, "regex_replace: invalid pattern '%s'", pattern);
        return make_str("");
    }

    strbuf out;
    strbuf_init(&out);
    const char *p = str;
    regmatch_t m[1];
    size_t rep_len = strlen(replacement);

    while (regexec(&re, p, 1, m, 0) == 0) {
        strbuf_append_n(&out, p, (size_t)m[0].rm_so);
        strbuf_append_n(&out, replacement, rep_len);
        p += m[0].rm_eo;
        if (m[0].rm_eo == m[0].rm_so) {
            if (*p) strbuf_append_char(&out, *p++);
            else break;
        }
    }
    strbuf_append(&out, p);

    regfree(&re);
    /* #965: the strbuf payload is already charged (reserve growth + finish
     * shortfall); take ownership instead of copying (a copy would charge it twice). */
    Value *v = make_str_owned(strbuf_finish(&out));
    return v;
}

/* ================================================================
 * STREAMING BINARY WRITER — write tensor-format data incrementally
 * ================================================================
 * stream_open of ["path", count]  → opens file, writes header with count, returns 1
 * stream_write of value           → writes one float64, returns 1
 * stream_close of null            → closes the stream file, returns 1
 *
 * Format: [uint32 ndim=1][uint32 rows=1][uint32 cols=count][uint32 flags=0]
 *         then count × float64 values (written one at a time via stream_write)
 */

/* g_stream_file is a per-thread bridge macro (eigenscript.h, #739): one FILE*
 * per PROCESS meant stream_open's unconditional close tore down another
 * state's in-flight stream. */


Value* builtin_stream_open(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *count_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR || !count_val || count_val->type != VAL_NUM)
        return make_num(0);
    if (g_stream_file) { fclose(g_stream_file); g_stream_file = NULL; }
    g_stream_file = xfopen_write(path_val->data.str, "wb");
    if (!g_stream_file) return make_num(0);
    uint32_t count = (uint32_t)count_val->data.num;
    uint32_t header[4] = { 1, 1, count, 0 }; /* ndim=1, rows=1, cols=count, flags=0 */
    if (fwrite(header, sizeof(uint32_t), 4, g_stream_file) != 4) {
        fclose(g_stream_file);
        g_stream_file = NULL;
        return make_num(0);
    }
    return make_num(1);
}

Value* builtin_stream_write(Value *arg) {
    if (!g_stream_file || !arg || arg->type != VAL_NUM) return make_num(0);
    double val = arg->data.num;
    if (fwrite(&val, sizeof(double), 1, g_stream_file) != 1) {
        fclose(g_stream_file);
        g_stream_file = NULL;
        return make_num(0);
    }
    return make_num(1);
}

Value* builtin_stream_close(Value *arg) {
    (void)arg;
    if (!g_stream_file) return make_num(0);
    int ok = (fclose(g_stream_file) == 0);
    g_stream_file = NULL;
    return make_num(ok ? 1 : 0);
}

/* ---- Filesystem ---- */


/* mkdir of "path" → 1 on success, 0 on failure. Creates parents. */
/* #585: mkdir's return (a success bit) is filesystem-dependent, so it is a
 * taped nondeterminism source. Under EIGS_REPLAY the TAKE short-circuits
 * before any mkdir(2), so the recorded bit is served and the filesystem is
 * NOT mutated a second time — the same "don't re-run side effects on replay"
 * rule as the proc-star / audio-capture boundary. Its return IS pinnable by
 * the tape (unlike a proc fd), so it is Recorded, not #148-non-replayable. */
Value* builtin_mkdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("mkdir", make_num(0));
    TRACE_NONDET_TAKE("mkdir");
    /* Simple recursive mkdir */
    char *path = xstrdup(arg->data.str);
    int len = strlen(path);
    for (int i = 1; i <= len; i++) {
        if (path[i] == '/' || path[i] == '\0') {
            char saved = path[i];
            path[i] = '\0';
            mkdir(path, 0755); /* ignore errors on intermediate dirs */
            path[i] = saved;
        }
    }
    free(path);
    struct stat st;
    TRACE_NONDET_RECORD("mkdir",
        make_num(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : 0));
}

/* ls of "path" → list of filenames in directory, or [] on failure.
 * Matches `ls -1` default behavior: hidden entries (starting with '.') are excluded. */
Value* builtin_ls(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("ls", make_list(0));
    /* #585: builds its return (a list) via readdir, so under EIGS_REPLAY the
     * TAKE short-circuits before opendir — the recorded listing is served and
     * the live directory is never read. */
    TRACE_NONDET_TAKE("ls");
    Value *list = make_list(0);
    DIR *d = opendir(arg->data.str);
    if (!d) TRACE_NONDET_RECORD("ls", list);
    struct dirent *entry;
    while ((entry = readdir(d))) {
        if (entry->d_name[0] == '.') continue;
        list_append_owned(list, make_str(entry->d_name));
    }
    closedir(d);
    TRACE_NONDET_RECORD("ls", list);
}

/* getcwd of null → current working directory as string */
Value* builtin_getcwd(Value *arg) {
    (void)arg;
    /* #585: the cwd is process environment, nondeterministic across
     * invocations and machines — taped so replay serves the recorded path. */
    TRACE_NONDET_TAKE("getcwd");
    char buf[4096];
    if (getcwd(buf, sizeof(buf))) TRACE_NONDET_RECORD("getcwd", make_str(buf));
    TRACE_NONDET_RECORD("getcwd", make_str(""));
}

/* exe_path of null → absolute path of the running interpreter binary.
 * Lets an EigenScript program re-invoke the same interpreter — e.g. a
 * test runner spawning `exec_capture of [exe_path of null, testfile]`,
 * which is more robust than assuming `eigenscript` is on PATH. Reads
 * /proc/self/exe; falls back to argv[0]. */
Value* builtin_exe_path(Value *arg) {
    (void)arg;
    /* #585: the interpreter path is machine-dependent — taped so replay
     * serves the recorded path without touching /proc/self/exe. */
    TRACE_NONDET_TAKE("exe_path");
    char buf[4096];
    ssize_t n = readlink("/proc/self/exe", buf, sizeof(buf) - 1);
    if (n > 0 && n < (ssize_t)sizeof(buf)) {
        buf[n] = '\0';
        TRACE_NONDET_RECORD("exe_path", make_str(buf));
    }
    if (g_argv && g_argc > 0 && g_argv[0])
        TRACE_NONDET_RECORD("exe_path", make_str(g_argv[0]));
    TRACE_NONDET_RECORD("exe_path", make_str("eigenscript"));
}

/* chdir of "path" → 1 on success, 0 on failure */
Value* builtin_chdir(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(chdir(arg->data.str) == 0 ? 1 : 0);
}

/* mktemp of null → path to a new temporary file */
Value* builtin_mktemp(Value *arg) {
    (void)arg;
    char tmpl[] = "/tmp/eigen_XXXXXX";
    int fd = mkstemp(tmpl);
    if (fd < 0) return make_str("");
    close(fd);
    return make_str(tmpl);
}

/* rm of "path" → 1 on success, 0 on failure */
Value* builtin_rm(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(unlink(arg->data.str) == 0 ? 1 : 0);
}

/* Identifier frequency entry */
typedef struct {
    char *name;
    int count;
} IdentEntry;

Value* builtin_build_corpus(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 4)
        return make_null();

    Value *file_list = arg->data.list.items[0];
    Value *topn_val = arg->data.list.items[1];
    Value *stream_path_val = arg->data.list.items[2];
    Value *vocab_path_val = arg->data.list.items[3];

    if (!file_list || file_list->type != VAL_LIST) return make_null();
    if (!topn_val || topn_val->type != VAL_NUM) return make_null();
    if (!stream_path_val || stream_path_val->type != VAL_STR) return make_null();
    if (!vocab_path_val || vocab_path_val->type != VAL_STR) return make_null();

    int top_n = (int)topn_val->data.num;
    int n_files = file_list->data.list.count;

    /* ---- SLOT MODE (optional 6th arg: slot_count > 0) --------------------
     * Measured on the 2026-07 ecosystem corpus: of 379,321 identifier
     * occurrences, only 7.1% are builtin/stdlib names (219 distinct) and
     * 92.9% are local names (25,355 distinct). A correctness requirement
     * attaches only to the first group -- you cannot call `pront` -- while
     * ANY consistent renaming of a local yields an equally correct program.
     *
     * Frequency mode spends the whole budget memorising the 25,355 arbitrary
     * names and still drops 45.7% of occurrences into one fallback token, so
     * distinct variables become indistinguishable and a correct program is
     * not expressible: `v0 is v0 + v1` collapses to <ident> is <ident> +
     * <ident>.
     *
     * Slot mode instead gives every builtin an exact token and encodes each
     * local by WHICH local it is, via an LRU slot table. Distinct locals per
     * real 32-token window: median 5, p99 10, max 17 -- so 20 slots cover
     * 100% of windows, and no eviction can occur inside a window (all of a
     * window's locals are more recently used than anything it would evict).
     * Vocabulary lands comparable to frequency mode's -- measured 362 on the
     * 2026-07 ecosystem corpus at slot_count=20, against 341 -- with ZERO
     * identifier information lost. The win is losslessness, not vocab size.
     * (That 362 was measured before the registry fix below, so it counts four
     * driver-defined names that no longer qualify; the corrected figure has not
     * been re-measured on the full corpus.) */
    int slot_count = 0;
    if (arg->data.list.count >= 6) {
        Value *sv = arg->data.list.items[5];
        if (sv && sv->type == VAL_NUM) slot_count = (int)sv->data.num;
    }
    if (slot_count < 0) slot_count = 0;

    /* ---- INTEGER LITERALS (optional 7th arg: int_count > 0) -------------
     * Every numeric literal tokenizes to a single TOK_NUM, so the value is
     * ERASED from the stream: `[1,2,3]` and `[0,0,0]` become the identical
     * `<num>,<num>,<num>`. Measured on the 2026-07 corpus this is doubly
     * costly. (1) A spec written as assertions is uninformative -- `(f of 4)
     * == 1` and `(f of 3) == 0` reach the model as one sequence, so it cannot
     * learn what the test demands. (2) It MANUFACTURES the degenerate
     * repetition the model collapses into: measured, essentially all of the
     * corpus's `0,0,0,0` / `"s","s"` cycles (5.3% of tokens) route through the
     * collapsed literal tokens, and integers 0..31 are 76% of all numeric
     * literals. Giving small integers exact tokens both makes tests readable
     * and breaks that false repetition -- `[1,2,3,4]` stops looking like a
     * cycle -- without discarding any real code a repetition filter would cut.
     *
     * int_count == N gives exact tokens to the integers [0, N). N=32 covers
     * 76% of numeric-literal occurrences for +32 tokens; larger N has a long
     * tail (0..255 is 86%). Non-integer, negative, and >=N literals keep the
     * lossy TOK_NUM fallback -- lossless is not the goal here, breaking the
     * high-frequency collision is. Opt-in: 0 leaves the stream byte-identical. */
    int int_count = 0;
    if (arg->data.list.count >= 7) {
        Value *iv = arg->data.list.items[6];
        if (iv && iv->type == VAL_NUM) int_count = (int)iv->data.num;
    }
    if (int_count < 0) int_count = 0;
    /* Source of truth: the size of the TokType enum. Hardcoding 54 (which is
     * what this was before) silently aliases TOK_LBRACKET (=54) onto the most
     * common extended ident slot whenever the enum grows. */
    const int BASE_VOCAB = tok_base_string_id_count();
    const int FIRST_IDENT = BASE_VOCAB;

    /* ---- Pass 1: tokenize all files, count identifier frequencies ---- */
    IdentEntry *idents = NULL;
    int n_idents = 0;
    int idents_cap = 0;

    int *file_tok_counts = xcalloc(n_files, sizeof(int));
    int total_tokens = 0;
    int files_found = 0;

    for (int fi = 0; fi < n_files; fi++) {
        Value *path_val = file_list->data.list.items[fi];
        if (!path_val || path_val->type != VAL_STR) { file_tok_counts[fi] = 0; continue; }
        const char *path = path_val->data.str;

        /* Read file */
        long fsize = 0;
        char *source = read_file_util(path, &fsize);
        if (!source) {
            fprintf(stderr, "  skip: %s\n", path);
            file_tok_counts[fi] = 0;
            continue;
        }

        /* Tokenize */
        TokenList tl = tokenize(source);
        file_tok_counts[fi] = tl.count;
        total_tokens += tl.count;
        files_found++;

        /* Count identifiers */
        for (int i = 0; i < tl.count; i++) {
            if (tl.tokens[i].type == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                const char *name = tl.tokens[i].str_val;
                /* Linear scan for existing entry */
                int found = -1;
                for (int j = 0; j < n_idents; j++) {
                    if (strcmp(idents[j].name, name) == 0) { found = j; break; }
                }
                if (found >= 0) {
                    idents[found].count++;
                } else {
                    if (n_idents >= idents_cap) {
                        idents_cap = idents_cap < 256 ? 256 : idents_cap * 2;
                        idents = xrealloc_array(idents, idents_cap, sizeof(IdentEntry));
                    }
                    idents[n_idents].name = xstrdup(name);
                    idents[n_idents].count = 1;
                    n_idents++;
                }
            }
        }

        fprintf(stderr, "  %s: %d tokens\n", path, tl.count);
        free_tokenlist(&tl);
        free(source);
    }

    fprintf(stderr, "\nFiles: %d/%d\n", files_found, n_files);
    fprintf(stderr, "Distinct identifiers: %d\n", n_idents);

    /* ---- Pass 2: pick the exact-token identifiers ----
     * Slot mode asks the RUNTIME'S OWN registry which names are builtins,
     * rather than carrying a hardcoded list that would silently drift as
     * builtins are added. Everything else becomes a slot.
     *
     * The registry is the set captured at REGISTRATION time, not the live
     * global env. Reading the live env instead promotes the driver script's own
     * top-level functions to exact tokens — measured: `collect_eigs`,
     * `_skip_dir`, `_skip_repo` and `_has_pathological_repetition` from
     * iLambdaAi's build_corpus_v3.eigs landed in the vocabulary beside `print`
     * and `len`. That is wrong twice over: those names are not part of the
     * language, and it makes the vocabulary a function of whichever script
     * built the corpus, so adding a helper to the driver silently renumbers
     * tokens and quietly invalidates comparison against every model trained on
     * an earlier build. */
    if (slot_count > 0) {
        int keep = 0;
        for (int i = 0; i < n_idents; i++) {
            if (eigs_is_registered_builtin(idents[i].name)) {
                if (keep != i) { IdentEntry tmp = idents[keep]; idents[keep] = idents[i]; idents[i] = tmp; }
                keep++;
            }
        }
        top_n = keep;
        fprintf(stderr, "Slot mode: %d builtin names kept exact, %d locals -> %d slots\n",
                keep, n_idents - keep, slot_count);
    }
    int actual_top = top_n < n_idents ? top_n : n_idents;
    if (actual_top <= 0) actual_top = 0;
    char **top_names = xcalloc(actual_top > 0 ? actual_top : 1, sizeof(char*));
    int *top_ids = xcalloc(actual_top > 0 ? actual_top : 1, sizeof(int));

    /* Work on a copy of counts */
    int *work_counts = xmalloc_array(n_idents, sizeof(int));
    for (int i = 0; i < n_idents; i++) work_counts[i] = idents[i].count;

    if (slot_count > 0) {
        /* Slot mode already partitioned the builtins to the front; take them
         * verbatim. Re-selecting by frequency here would hand the exact tokens
         * to the most COMMON names (which are locals like `total`/`items`) and
         * push the builtins into slots -- exactly backwards, since a local's
         * name is arbitrary and a builtin's is not. */
        for (int t = 0; t < actual_top; t++) {
            top_names[t] = idents[t].name;
            top_ids[t] = FIRST_IDENT + t;
        }
    } else {
        for (int t = 0; t < actual_top; t++) {
            int best_idx = -1, best_val = -1;
            for (int j = 0; j < n_idents; j++) {
                if (work_counts[j] > best_val) { best_val = work_counts[j]; best_idx = j; }
            }
            if (best_idx < 0) break;
            top_names[t] = idents[best_idx].name;
            top_ids[t] = FIRST_IDENT + t;
            work_counts[best_idx] = -1;
        }
    }
    free(work_counts);

    /* LRU slot table state (slot mode only). */
    char **slot_names = NULL; long *slot_used = NULL; long slot_clock = 0;
    if (slot_count > 0) {
        slot_names = xcalloc(slot_count, sizeof(char*));
        slot_used  = xcalloc(slot_count, sizeof(long));
    }

    fprintf(stderr, "\nTop %d identifiers:\n", actual_top);
    for (int i = 0; i < 10 && i < actual_top; i++) {
        fprintf(stderr, "  %3d  %-20s  %d uses\n", top_ids[i], top_names[i],
                idents[top_ids[i] - FIRST_IDENT].count);
    }

    /* ---- Pass 3: re-tokenize and write binary stream ---- */
    int stream_size = total_tokens + files_found * 2; /* +2 EOF per file */

    FILE *stream_file = xfopen_write(stream_path_val->data.str, "wb");
    if (!stream_file) {
        fprintf(stderr, "Error: cannot open %s\n", stream_path_val->data.str);
        free(file_tok_counts); free(top_names); free(top_ids);
        for (int i = 0; i < n_idents; i++) free(idents[i].name);
        free(idents);
        return make_null();
    }

    /* Write header: ndim=1, rows=1, cols=stream_size, flags=0 */
    uint32_t header[4] = { 1, 1, (uint32_t)stream_size, 0 };
    fwrite(header, sizeof(uint32_t), 4, stream_file);
    int stream_pos = 0;

    for (int fi = 0; fi < n_files; fi++) {
        if (file_tok_counts[fi] <= 0) continue;

        Value *path_val = file_list->data.list.items[fi];
        long fsize = 0;
        char *source = read_file_util(path_val->data.str, &fsize);
        if (!source) continue;

        /* Write double-EOF separator */
        double eof_val = (double)TOK_EOF;
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        fwrite(&eof_val, sizeof(double), 1, stream_file);
        stream_pos += 2;

        TokenList tl = tokenize(source);

        for (int i = 0; i < tl.count; i++) {
            int tid = tl.tokens[i].type;
            /* Replace known identifiers with extended IDs */
            if (tid == TOK_IDENT && tl.tokens[i].str_val && tl.tokens[i].str_val[0]) {
                int matched = 0;
                for (int j = 0; j < actual_top; j++) {
                    if (strcmp(top_names[j], tl.tokens[i].str_val) == 0) {
                        tid = top_ids[j];
                        matched = 1;
                        break;
                    }
                }
                if (!matched && slot_count > 0) {
                    /* LRU slot table: a name keeps its slot until evicted, so
                     * every occurrence inside a window maps to the SAME token
                     * -- which is precisely what lets the model express "the
                     * variable I just read" and what the fallback destroyed. */
                    int hit = -1;
                    for (int j = 0; j < slot_count; j++)
                        if (slot_names[j] && strcmp(slot_names[j], tl.tokens[i].str_val) == 0) { hit = j; break; }
                    if (hit < 0) {
                        int lru = 0;
                        for (int j = 1; j < slot_count; j++)
                            if (slot_used[j] < slot_used[lru]) lru = j;
                        free(slot_names[lru]);
                        slot_names[lru] = xstrdup(tl.tokens[i].str_val);
                        hit = lru;
                    }
                    slot_used[hit] = ++slot_clock;
                    tid = FIRST_IDENT + actual_top + hit;
                }
            } else if (int_count > 0 && tid == TOK_NUM) {
                /* Give small non-negative integer literals exact tokens; the
                 * region sits directly after the slots. floor==value rejects
                 * 3.5 etc.; the lexer emits '-' as its own token so num_val is
                 * never negative for a literal, but guard anyway. */
                double nv = tl.tokens[i].num_val;
                if (nv >= 0.0 && nv < (double)int_count && nv == (double)(long)nv)
                    tid = FIRST_IDENT + actual_top + slot_count + (int)nv;
            }
            double d = (double)tid;
            fwrite(&d, sizeof(double), 1, stream_file);
            stream_pos++;
        }

        free_tokenlist(&tl);
        free(source);
    }

    fclose(stream_file);
    if (slot_names) {
        for (int j = 0; j < slot_count; j++) free(slot_names[j]);
        free(slot_names); free(slot_used);
    }
    fprintf(stderr, "\nWritten: %s (%d tokens)\n", stream_path_val->data.str, stream_pos);

    /* ---- Write identifier vocab JSON ----
     * Emits base_names[] (placeholder text for each base TokType, in ID order)
     * and structural_ids{} (the IDs the detokenizer special-cases). Downstream
     * scripts read these instead of hardcoding TokType ordinals so the stream
     * and detokenizer stay aligned when the enum grows. */
    FILE *vocab_file = xfopen_write(vocab_path_val->data.str, "w");
    if (vocab_file) {
        fprintf(vocab_file,
                "{\"first_ident_id\": %d, \"ext_vocab_size\": %d, \"base_vocab\": %d, \"slot_count\": %d, \"first_slot_id\": %d, \"int_count\": %d, \"first_int_id\": %d, \"top_n\": %d",
                FIRST_IDENT, BASE_VOCAB + actual_top + slot_count + int_count, BASE_VOCAB,
                slot_count, FIRST_IDENT + actual_top,
                int_count, FIRST_IDENT + actual_top + slot_count, actual_top);
        fprintf(vocab_file, ", \"structural_ids\": {\"newline\": %d, \"indent\": %d, \"dedent\": %d, \"eof\": %d, \"ident_fallback\": %d}",
                (int)TOK_NEWLINE, (int)TOK_INDENT, (int)TOK_DEDENT, (int)TOK_EOF, (int)TOK_IDENT);
        fprintf(vocab_file, ", \"base_names\": [");
        for (int i = 0; i < BASE_VOCAB; i++) {
            if (i > 0) fprintf(vocab_file, ", ");
            fprintf(vocab_file, "\"");
            const char *s = tok_base_string((TokType)i);
            for (const char *q = s; *q; q++) {
                if (*q == '"' || *q == '\\') fputc('\\', vocab_file);
                fputc(*q, vocab_file);
            }
            fprintf(vocab_file, "\"");
        }
        fprintf(vocab_file, "], \"names\": [");
        for (int i = 0; i < actual_top; i++) {
            if (i > 0) fprintf(vocab_file, ", ");
            fprintf(vocab_file, "\"%s\"", top_names[i]);
        }
        fprintf(vocab_file, "]}");
        fclose(vocab_file);
        fprintf(stderr, "Written: %s\n", vocab_path_val->data.str);
    }

    /* ---- Optional 5th arg: full identifier histogram JSON ----
     * Sorted by count descending. Enables exact coverage(top_n) curves
     * without re-running the full corpus build. */
    if (arg->data.list.count >= 5) {
        Value *idents_path_val = arg->data.list.items[4];
        if (idents_path_val && idents_path_val->type == VAL_STR && n_idents > 0) {
            /* Build index array, sort descending by count via simple sort */
            int *order = xmalloc_array(n_idents, sizeof(int));
            for (int i = 0; i < n_idents; i++) order[i] = i;
            /* Insertion sort is fine — n_idents is small thousands and runs once */
            for (int i = 1; i < n_idents; i++) {
                int key = order[i];
                int kc = idents[key].count;
                int j = i - 1;
                while (j >= 0 && idents[order[j]].count < kc) {
                    order[j+1] = order[j];
                    j--;
                }
                order[j+1] = key;
            }
            FILE *hist_file = xfopen_write(idents_path_val->data.str, "w");
            if (hist_file) {
                fprintf(hist_file, "{\"n_idents\": %d, \"entries\": [", n_idents);
                for (int i = 0; i < n_idents; i++) {
                    int idx = order[i];
                    if (i > 0) fprintf(hist_file, ", ");
                    fprintf(hist_file, "[\"%s\", %d]", idents[idx].name, idents[idx].count);
                }
                fprintf(hist_file, "]}");
                fclose(hist_file);
                fprintf(stderr, "Written: %s\n", idents_path_val->data.str);
            }
            free(order);
        }
    }

    /* ---- Cleanup ---- */
    free(file_tok_counts);
    free(top_names);
    free(top_ids);
    for (int i = 0; i < n_idents; i++) free(idents[i].name);
    free(idents);

    /* Return [stream_length, distinct_identifiers, files_found] */
    Value *result = make_list(3);
    list_append_owned(result, make_num(stream_pos));
    list_append_owned(result, make_num(n_idents));
    list_append_owned(result, make_num(files_found));
    return result;
}

/* ================================================================
 * LOAD_FILE — include mechanism for .eigs modules
 * ================================================================ */


/* File I/O helper — used by load_file and main() */
char* read_file_util(const char *path, long *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    /* #314: fopen succeeds on a directory, and ftell then reports LONG_MAX —
     * which sailed straight into xmalloc's fatal-OOM abort. Reject
     * directories here so callers hit their existing clean error paths. */
    struct stat st;
    if (fstat(fileno(f), &st) == 0 && !S_ISREG(st.st_mode)) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    if (size < 0 || size == LONG_MAX) { fclose(f); return NULL; }
    fseek(f, 0, SEEK_SET);
    char *buf = xmalloc(size + 1);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, size, f);
    fclose(f);
    if ((long)got != size) { free(buf); return NULL; }
    buf[size] = '\0';
    if (out_size) *out_size = size;
    return buf;
}

static int try_resolve_path(const char *candidate, char *resolved, size_t resolved_cap) {
    if (!candidate || access(candidate, F_OK) != 0) return 0;
    snprintf(resolved, resolved_cap, "%s", candidate);
    return 1;
}

/* Phase 0c: walk from `base` upward looking for
 *   <dir>/eigs_modules/<name>/<name>.eigs
 * at each level. Stop at the project root (a directory containing
 * eigs.json) — its eigs_modules/ is checked once, then we don't go
 * higher. Only fires for bare `<name>.eigs` requests (no slashes); the
 * resolver's existing chain still handles paths with directory
 * components. Bounded to 64 levels for safety. */
static int try_eigs_modules_walk(const char *base, const char *path,
                                  char *resolved, size_t resolved_cap) {
    if (!base || !base[0] || !path) return 0;
    if (strchr(path, '/')) return 0;
    size_t plen = strlen(path);
    if (plen < 6 || strcmp(path + plen - 5, ".eigs") != 0) return 0;
    if (plen - 5 >= 512) return 0;

    char name[512];
    memcpy(name, path, plen - 5);
    name[plen - 5] = '\0';

    char cur[4096];
    snprintf(cur, sizeof(cur), "%s", base);

    for (int i = 0; i < 64; i++) {
        char candidate[8192];
        snprintf(candidate, sizeof(candidate),
                 "%.3000s/eigs_modules/%.500s/%.500s.eigs",
                 cur, name, name);
        if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

        char marker[4400];
        snprintf(marker, sizeof(marker), "%.4000s/eigs.json", cur);
        if (access(marker, F_OK) == 0) return 0;

        char *slash = strrchr(cur, '/');
        if (!slash || slash == cur) return 0;
        *slash = '\0';
    }
    return 0;
}

int resolve_eigenscript_file_from_ex(const char *base, const char *path,
                                      char *resolved, size_t resolved_cap,
                                      int *origin) {
    char candidate[8192];

    /* #904: report which half of the chain answered. The tail steps below
     * are the *installed stdlib roots* (`<prefix>/lib/eigenscript/`, from
     * `make install`), and they answer a bare `<name>.eigs` request just as
     * readily as `lib/<name>.eigs` — so a hit there is the stdlib wearing a
     * project-shaped request, not a project file. Callers that must tell
     * the two apart (import's collision diagnostic) pass `origin`. */
#define RESOLVED(step)                                                       \
    do { if (origin) *origin = (step); return 1; } while (0)

    if (origin) *origin = EIGS_RESOLVE_PROJECT;
    if (!path || !resolved || resolved_cap == 0) return 0;
    if (!base || !base[0]) base = g_script_dir;

    if (path[0] == '/') {
        return try_resolve_path(path, resolved, resolved_cap);
    }

    if (try_resolve_path(path, resolved, resolved_cap)) return 1;

    if (try_eigs_modules_walk(base, path, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/%.4000s", base, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../%.4000s", base, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../%.4000s", g_exe_dir, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) return 1;

    snprintf(candidate, sizeof(candidate), "%.4000s/../lib/eigenscript/%.4000s", g_exe_dir, path);
    if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);

    if (strncmp(path, "lib/", 4) == 0) {
        snprintf(candidate, sizeof(candidate), "%.4000s/../lib/eigenscript/%.4000s", g_exe_dir, path + 4);
        if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);
    }

    const char *home = getenv("HOME");
    if (home) {
        snprintf(candidate, sizeof(candidate), "%.2000s/.local/lib/eigenscript/%.4000s", home, path);
        if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);

        if (strncmp(path, "lib/", 4) == 0) {
            snprintf(candidate, sizeof(candidate), "%.2000s/.local/lib/eigenscript/%.4000s", home, path + 4);
            if (try_resolve_path(candidate, resolved, resolved_cap)) RESOLVED(EIGS_RESOLVE_STDLIB_ROOT);
        }
    }

    return 0;
#undef RESOLVED
}

int resolve_eigenscript_file_from(const char *base, const char *path,
                                   char *resolved, size_t resolved_cap) {
    return resolve_eigenscript_file_from_ex(base, path, resolved, resolved_cap, NULL);
}

Value* builtin_load_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) {
        rt_error(EK_TYPE, 0, "load_file requires a string path argument");
        return make_null();
    }
    char resolved[8192];
    const char *path = arg->data.str;
    long size = 0;
    char *source = NULL;

    if (resolve_eigenscript_file(arg->data.str, resolved, sizeof(resolved))) {
        path = resolved;
        source = read_file_util(path, &size);
    }

    if (!source) {
        /* #490: match import's severity — a missing path is a catchable io
         * error, not a stderr-warn + silent null (rc=0). Callers that ignore
         * the return otherwise run on half-initialized state. */
        rt_error(EK_IO, 0, "load_file: cannot read '%s'", arg->data.str);
        return make_null();
    }

    /* #496: circular-load guard. load_file has no module cache — it
     * re-executes every call — so a mutual load (a loads b, b loads a)
     * recurses through vm_execute to a C-stack SIGSEGV. Key on the
     * canonical path (shared with import's cycle stack) and raise if this
     * path's load is already on the stack. Sequential re-loads of the same
     * file stay legal: the entry pops when each load completes. */
    char abs_key[8192];
    if (!realpath(path, abs_key))
        snprintf(abs_key, sizeof(abs_key), "%s", path);
    if (eigs_loading_active(abs_key)) {
        free(source);
        rt_error(EK_IO, 0,
            "load_file: circular dependency — '%s' is already being loaded",
            arg->data.str);
        return make_null();
    }

    /* #560: silent by default — no other successful builtin announces
     * itself, and shipped CLI tools built on load_file must be able to keep
     * stderr clean. Set EIGS_VERBOSE_LOAD=1 for the development banner. */
    if (getenv("EIGS_VERBOSE_LOAD"))
        fprintf(stderr, "[load_file] Loading %s (%ld bytes)\n", path, size);

    /* A parse error in the loaded file must surface, not be silently run as a
     * partial/incorrect AST. Direct execution aborts on g_parse_errors; mirror
     * that here (and match builtin_eval) by raising a catchable runtime error.
     * Without this, malformed statements a module can't parse — e.g. an
     * expression-rooted lvalue like `(call).field is x` — were silently accepted
     * and their effect dropped (the load_file half of liferaft FINDINGS F1).
     * Save/restore g_parse_errors so a recovered (try/catch'd) load doesn't
     * perturb a caller's count. */
    int saved_errors = g_parse_errors;
    g_parse_errors = 0;

    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);

    if (g_parse_errors > 0 || !ast) {
        g_parse_errors = saved_errors;
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        rt_error(EK_PARSE, 0, "load_file: parse error in '%s'", arg->data.str);
        return make_null();
    }
    /* Compile-stage diagnostics must fail the load too (#337) — same
     * rationale as eval above. */
    Env *target = g_load_env ? g_load_env : g_global_env;
    int saved_boundary = g_compile_module_boundary;
    g_compile_module_boundary = 1;                       /* #373 */
    EigsChunk *lf_chunk = compile_ast(ast, target, source);
    g_compile_module_boundary = saved_boundary;
    if (g_parse_errors > 0) {
        g_parse_errors = saved_errors;
        chunk_free(lf_chunk);
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        rt_error(EK_PARSE, 0, "load_file: compile error in '%s'", arg->data.str);
        return make_null();
    }
    g_parse_errors = saved_errors;
    eigs_loading_enter(abs_key);            /* #496 */
    Value *result = vm_execute(lf_chunk, target);
    eigs_loading_leave(abs_key);            /* #496 */
    chunk_free(lf_chunk);   /* creator ref; loaded fns hold their own */
    free_ast(ast);
    free(source);
    free_tokenlist(&tl);
    return result ? result : make_null();
}

Value* builtin_file_exists(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("file_exists", make_num(0));
    /* #585: fs-dependent read — taped so replay serves the recorded answer.
     * TAKE short-circuits before the fopen probe under EIGS_REPLAY. */
    TRACE_NONDET_TAKE("file_exists");
    FILE *f = fopen(arg->data.str, "r");
    int ex = (f != NULL);
    if (f) fclose(f);
    TRACE_NONDET_RECORD("file_exists", make_num(ex));
}

/* is_dir of path — 1 if path names a directory, 0 for a plain file, a
 * missing path, or a non-string arg. Replaces the consumer-side
 * `file_exists of f"{path}/."` probe (#576). Nondeterministic fs read →
 * trace-recorded per the tape-first rule (NB: the older fs predicates —
 * file_exists, ls, mkdir, getcwd — predate the tape and are untraced;
 * that inconsistency is flagged on the PR, not silently copied here). */
Value* builtin_is_dir(Value *arg) {
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RET("is_dir", make_num(0));
    struct stat st;
    TRACE_NONDET_RET("is_dir",
        make_num(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode) ? 1 : 0));
}

/* rename of [old_path, new_path] — rename/replace a file. On POSIX rename(2) is
 * atomic: a crash leaves either the old file or the new file fully in place,
 * never a torn mix — the basis for crash-safe log compaction (write a new log to
 * a temp file, then atomically swap it in). Returns 1 on success, 0 on failure. */
Value* builtin_rename(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) return make_num(0);
    Value *from = arg->data.list.items[0];
    Value *to = arg->data.list.items[1];
    if (!from || from->type != VAL_STR || !to || to->type != VAL_STR) return make_num(0);
    return make_num(rename(from->data.str, to->data.str) == 0 ? 1 : 0);
}

/* remove_file of path — delete a file. Returns 1 on success, 0 on failure. */
Value* builtin_remove_file(Value *arg) {
    if (!arg || arg->type != VAL_STR) return make_num(0);
    return make_num(remove(arg->data.str) == 0 ? 1 : 0);
}

/* ==== BUILTIN: read_text ==== */
/* read_text of "path" → file contents as string, or "" on failure. */
/* read_bytes of path — read binary file, return list of byte values (0-255) */
Value* builtin_read_bytes(Value *arg) {
    TRACE_NONDET_TAKE("read_bytes");
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RECORD("read_bytes", make_null());
    FILE *f = fopen(arg->data.str, "rb");
    if (!f) TRACE_NONDET_RECORD("read_bytes", make_null());
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 10 * 1024 * 1024) { /* 10 MB cap */
        fclose(f);
        TRACE_NONDET_RECORD("read_bytes", make_null());
    }
    unsigned char *buf = xmalloc(len);
    if (!buf) { fclose(f); TRACE_NONDET_RECORD("read_bytes", make_null()); }
    size_t nread = fread(buf, 1, len, f);
    fclose(f);
    Value *result = make_list((int)nread);
    for (size_t i = 0; i < nread; i++)
        list_append_owned(result, make_num((double)buf[i]));
    free(buf);
    TRACE_NONDET_RECORD("read_bytes", result);
}

/* read_bytes_buf of path — read binary file, return VAL_BUFFER of byte values.
 * read_bytes_buf of [path, max_bytes] — opt-in cap override (#601).
 * Zero per-element allocation; O(1) indexed access.
 *
 * Cap policy (#601): the 1-arg form keeps the historical 10 MB cap (the
 * security posture is unchanged — a script that never asks for more never
 * gets more). An over-cap file RAISES a catchable `io` error naming the
 * size and the active cap; the old behavior returned null, which was
 * indistinguishable from "file missing" and surfaced downstream as a
 * misleading diagnosis (DeslanStudio: a >10 MB WAV died as "not a WAV
 * file"). max_bytes is bounded by a 512 MB hard ceiling: a VAL_BUFFER
 * holds one double per byte (8x expansion — 512 MB of file is already
 * ~4 GiB resident), so the ceiling keeps the opt-in from becoming an
 * unbounded fs->RAM amplifier while blocking no realistic asset.
 * Missing/unopenable file still returns null (existing contract). */
#define READ_BYTES_BUF_DEFAULT_CAP (10LL * 1024 * 1024)
#define READ_BYTES_BUF_HARD_CAP    (512LL * 1024 * 1024)

/* One raise site shared by the live and replay paths so the message
 * cannot drift between them. */
static void read_bytes_buf_cap_raise(const char *path, long long len,
                                     long long cap) {
    rt_error(EK_IO, 0,
             "read_bytes_buf: '%s' is %lld bytes, over the %lld-byte cap — "
             "pass read_bytes_buf of [path, max_bytes] (hard ceiling %lld) "
             "to raise it",
             path, len, cap, READ_BYTES_BUF_HARD_CAP);
}

Value* builtin_read_bytes_buf(Value *arg) {
    /* Deterministic argument parse, BEFORE the tape boundary: a bad call
     * shape takes the same path live and under replay, consuming no N
     * record either way. */
    Value *path = arg;
    long long cap = READ_BYTES_BUF_DEFAULT_CAP;
    if (arg && arg->type == VAL_LIST) {
        if (arg->data.list.count < 1) {
            rt_error(EK_TYPE, 0, "read_bytes_buf requires a path: "
                     "read_bytes_buf of path, or read_bytes_buf of [path, max_bytes]");
            return make_null();
        }
        path = arg->data.list.items[0];
        if (arg->data.list.count >= 2) {
            Value *mv = arg->data.list.items[1];
            if (!mv || mv->type != VAL_NUM) {
                rt_error(EK_VALUE, 0, "read_bytes_buf: max_bytes must be a number");
                return make_null();
            }
            if (!(mv->data.num >= 1 &&
                  mv->data.num <= (double)READ_BYTES_BUF_HARD_CAP)) {
                rt_error(EK_VALUE, 0,
                         "read_bytes_buf: max_bytes must be in 1..%lld (got %g)",
                         READ_BYTES_BUF_HARD_CAP, mv ? mv->data.num : 0.0);
                return make_null();
            }
            cap = (long long)mv->data.num;
        }
    }
    if (!path || path->type != VAL_STR) return make_null();

    /* Tape boundary. Success records the VAL_BUFFER; unopenable file
     * records null; the over-cap raise records the observed SIZE as a
     * VAL_NUM N record (unambiguous — no other path records a number) so
     * the identical raise is re-derived under EIGS_REPLAY without
     * touching the live filesystem. */
    if (__builtin_expect(g_replay_enabled, 0)) {
        Value *tv;
        if (trace_replay_take("read_bytes_buf", &tv)) {
            if (tv && tv->type == VAL_NUM) {
                long long len = (long long)tv->data.num;
                val_decref(tv);
                read_bytes_buf_cap_raise(path->data.str, len, cap);
                return make_null();
            }
            return tv;
        }
    }
    FILE *f = fopen(path->data.str, "rb");
    if (!f) TRACE_NONDET_RECORD("read_bytes_buf", make_null());
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) { /* unseekable (pipe/fifo): existing null contract */
        fclose(f);
        TRACE_NONDET_RECORD("read_bytes_buf", make_null());
    }
    if ((long long)len > cap) {
        fclose(f);
        if (__builtin_expect(g_trace_enabled, 0)) {
            Value *sz = make_num((double)len);
            trace_nondet_value("read_bytes_buf", sz);
            val_decref(sz);
        }
        read_bytes_buf_cap_raise(path->data.str, (long long)len, cap);
        return make_null();
    }
    unsigned char *buf = xmalloc(len);
    if (!buf) { fclose(f); TRACE_NONDET_RECORD("read_bytes_buf", make_null()); }
    size_t nread = fread(buf, 1, len, f);
    fclose(f);
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = (int)nread;
    v->data.buffer.data = xcalloc(nread > 0 ? nread : 1, sizeof(double));
    v->refcount = 1;
    for (size_t i = 0; i < nread; i++)
        v->data.buffer.data[i] = (double)buf[i];
    free(buf);
    TRACE_NONDET_RECORD("read_bytes_buf", v);
}

Value* builtin_read_text(Value *arg) {
    TRACE_NONDET_TAKE("read_text");
    if (!arg || arg->type != VAL_STR) TRACE_NONDET_RECORD("read_text", make_str(""));
    FILE *f = fopen(arg->data.str, "r");
    if (!f) TRACE_NONDET_RECORD("read_text", make_str(""));
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0 || len > 10 * 1024 * 1024) { /* 10 MB cap */
        fclose(f);
        TRACE_NONDET_RECORD("read_text", make_str(""));
    }
    char *buf = xmalloc(len + 1);
    if (!buf) { fclose(f); TRACE_NONDET_RECORD("read_text", make_str("")); }
    size_t read = fread(buf, 1, len, f);
    fclose(f);
    buf[read] = '\0';
    Value *result = make_str(buf);
    free(buf);
    TRACE_NONDET_RECORD("read_text", result);
}

/* ==== BUILTIN: read_line ==== */
/* read_line of null — blocking line read from stdin via getline(3):
 * returns the next line without its trailing newline (a "\r\n"
 * terminator is stripped as one unit), or null at EOF. An empty line is
 * "" — distinguishable from EOF. The stream-safe stdin primitive
 * (#558): read_text of "/dev/stdin" sizes with fseek/ftell, which fails
 * on an unseekable fd, so a PIPE silently reads as "" — any CLI meant to
 * sit in a shell pipeline needs this instead. Nondeterministic input →
 * tape-first: TAKE/RECORD like read_bytes, so under EIGS_REPLAY the
 * recorded lines are served and no live stdin read runs. */
Value* builtin_read_line(Value *arg) {
    (void)arg;
    TRACE_NONDET_TAKE("read_line");
    char *line = NULL;
    size_t cap = 0;
    ssize_t n = getline(&line, &cap, stdin);
    if (n < 0) {
        free(line);
        TRACE_NONDET_RECORD("read_line", make_null());
    }
    if (n > 0 && line[n - 1] == '\n') line[--n] = '\0';
    if (n > 0 && line[n - 1] == '\r') line[--n] = '\0';
    Value *v = make_str(line);
    free(line);
    TRACE_NONDET_RECORD("read_line", v);
}

/* ==== BUILTIN: write_text ==== */
/* write_text of ["path", text] → 1 on success, 0 on failure. */
Value* builtin_write_text(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *text_val = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR ||
        !text_val || text_val->type != VAL_STR)
        return make_num(0);
    FILE *f = xfopen_write(path_val->data.str, "w");
    if (!f) return make_num(0);
    size_t len = strlen(text_val->data.str);
    size_t written = fwrite(text_val->data.str, 1, len, f);
    int close_ok = (fclose(f) == 0);
    return make_num(written == len && close_ok ? 1 : 0);
}

/* ==== BUILTIN: exec_capture ==== */
/* exec_capture of ["cmd", "arg1", ...]               → [exit_code, stdout_text]
 * exec_capture of [["cmd", "arg1", ...], timeout_sec] → same, with timeout
 *
 * Runs a subprocess with fork/exec, captures stdout. No shell.
 * Child stdin is /dev/null. 10 MB output cap.
 *
 * Timeout form: pass a 2-element list where the first element is the
 * command list and the second is the timeout in seconds.
 * On timeout the child is killed and the return is [-2, partial_stdout].
 *
 * Always returns a 2-item list. Returns [-1, ""] on failure. */

static Value* exec_capture_result(int code, const char *text) {
    Value *result = make_list(2);
    result->data.list.items[0] = make_num(code);
    result->data.list.items[1] = make_str(text);
    result->data.list.count = 2;
    return result;
}

Value* builtin_exec_capture(Value *arg) {
    if (replay_blocks("exec_capture")) return exec_capture_result(-1, "");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1)
        return exec_capture_result(-1, "");

    /* Detect timeout form: [["cmd", ...], timeout_num] */
    double timeout_sec = -1;
    Value *cmd_list = arg;
    if (arg->data.list.count == 2
        && arg->data.list.items[0] && arg->data.list.items[0]->type == VAL_LIST
        && arg->data.list.items[1] && arg->data.list.items[1]->type == VAL_NUM) {
        cmd_list = arg->data.list.items[0];
        timeout_sec = arg->data.list.items[1]->data.num;
        if (cmd_list->data.list.count < 1)
            return exec_capture_result(-1, "");
    }

    int total = cmd_list->data.list.count;

    /* Build argv array */
    char **argv = xmalloc_array((size_t)total + 1, sizeof(char*));
    if (!argv) return exec_capture_result(-1, "");
    for (int i = 0; i < total; i++) {
        Value *v = cmd_list->data.list.items[i];
        if (!v || v->type != VAL_STR) {
            free(argv);
            return exec_capture_result(-1, "");
        }
        argv[i] = v->data.str;
    }
    argv[total] = NULL;

    /* Create pipe for stdout capture. FD_CLOEXEC on both ends so the pipe
     * doesn't leak into siblings of subsequent exec_capture / proc_spawn
     * children — see issue #149. The child reroutes the write end into
     * stdout via dup2, which clears FD_CLOEXEC on the destination, so the
     * child's stdout still survives execvp. */
    int pipefd[2];
    if (pipe(pipefd) != 0) { free(argv); return exec_capture_result(-1, ""); }
    (void)fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        return exec_capture_result(-1, "");
    }

    if (pid == 0) {
        /* Child: redirect stdout to pipe, stdin to /dev/null.
         * Reset SIGPIPE to SIG_DFL — proc_spawn installs a process-wide
         * SIG_IGN once, and that disposition survives fork; without an
         * explicit reset here the captured child silently no-ops on
         * broken-pipe writes instead of dying (issue #150). */
        signal(SIGPIPE, SIG_DFL);
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) { dup2(devnull, STDIN_FILENO); close(devnull); }
        execvp(argv[0], argv);
        _exit(127); /* exec failed */
    }

    /* Parent: read from pipe, close write end */
    close(pipefd[1]);
    free(argv);

    /* Compute deadline */
    struct timespec deadline;
    int has_timeout = (timeout_sec >= 0);
    if (has_timeout) {
        clock_gettime(CLOCK_MONOTONIC, &deadline);
        deadline.tv_sec += (time_t)timeout_sec;
        deadline.tv_nsec += (long)((timeout_sec - (time_t)timeout_sec) * 1e9);
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec++;
            deadline.tv_nsec -= 1000000000L;
        }
    }

    size_t cap = 4096, len = 0;
    char *buf = xmalloc(cap + 1);
    if (!buf) {
        close(pipefd[0]);
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        return exec_capture_result(-1, "");
    }

    int timed_out = 0;

    /* Read loop with optional timeout via poll() */
    for (;;) {
        int poll_ms = -1; /* infinite */
        if (has_timeout) {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            long remaining_ms = (deadline.tv_sec - now.tv_sec) * 1000
                              + (deadline.tv_nsec - now.tv_nsec) / 1000000;
            if (remaining_ms <= 0) { timed_out = 1; break; }
            poll_ms = (int)remaining_ms;
        }

        struct pollfd pfd = { .fd = pipefd[0], .events = POLLIN };
        int pr = poll(&pfd, 1, poll_ms);
        if (pr == 0) { timed_out = 1; break; }       /* timeout */
        if (pr < 0) { if (errno == EINTR) continue; break; } /* error */

        ssize_t n = read(pipefd[0], buf + len, cap - len);
        if (n <= 0) break; /* EOF or error */
        len += n;
        if (len >= cap) {
            if (cap >= 10 * 1024 * 1024) break;
            size_t newcap = cap * 2;
            if (newcap > 10 * 1024 * 1024) newcap = 10 * 1024 * 1024;
            char *newbuf = xrealloc(buf, newcap + 1);
            if (!newbuf) break;
            buf = newbuf;
            cap = newcap;
        }
    }
    close(pipefd[0]);
    buf[len] = '\0';

    int exit_code;
    if (timed_out) {
        kill(pid, SIGKILL);
        waitpid(pid, NULL, 0);
        exit_code = -2;
    } else {
        int status = 0;
        waitpid(pid, &status, 0);
        exit_code = WIFEXITED(status) ? WEXITSTATUS(status) : -1;
    }

    Value *result = exec_capture_result(exit_code, buf);
    free(buf);
    return result;
}

/* ==== BUILTIN: proc_spawn / proc_write / proc_read_line / proc_read /
 *               proc_close / proc_wait — streaming subprocess I/O (0.13.0) ====
 *
 * Sibling API to exec_capture for cases where you need to interact with a
 * child process over time instead of waiting for it to terminate.
 *
 *   proc_spawn of ["cmd", "arg1", ...]     → [pid, in_fd, out_fd]  | [-1,-1,-1]
 *   proc_write of [in_fd, "text"]          → bytes_written | -1 on broken pipe
 *   proc_read_line of out_fd               → string (no trailing \n) | null EOF
 *   proc_read of [out_fd, max_bytes]       → string (raw bytes; NUL-truncates) | null EOF
 *   proc_read_buf of [out_fd, max_bytes]   → VAL_BUFFER (binary-safe) | null EOF
 *   proc_close of fd                       → null (idempotent on EBADF)
 *   proc_wait of pid                       → exit_code | -1 on error
 *
 * Pipes are raw read(2)/write(2); no stdio buffering on the parent side.
 * Children using stdio block-buffer their own stdout when not on a tty —
 * wrap unbuffered programs with stdbuf -oL / -o0 if you need line streaming.
 *
 * SIGPIPE is set to SIG_IGN once on first spawn so a writing parent gets
 * EPIPE instead of dying when the child exits. */

static pthread_once_t g_proc_sigpipe_once = PTHREAD_ONCE_INIT;

static void proc_install_sigpipe_ignore(void) {
    signal(SIGPIPE, SIG_IGN);
}

static Value* proc_spawn_fail(void) {
    Value *r = make_list(3);
    r->data.list.items[0] = make_num(-1);
    r->data.list.items[1] = make_num(-1);
    r->data.list.items[2] = make_num(-1);
    r->data.list.count = 3;
    return r;
}

Value* builtin_proc_spawn(Value *arg) {
    if (replay_blocks("proc_spawn")) return proc_spawn_fail();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 1)
        return proc_spawn_fail();

    int total = arg->data.list.count;
    char **argv = xmalloc_array((size_t)total + 1, sizeof(char*));
    if (!argv) return proc_spawn_fail();
    for (int i = 0; i < total; i++) {
        Value *v = arg->data.list.items[i];
        if (!v || v->type != VAL_STR) { free(argv); return proc_spawn_fail(); }
        argv[i] = v->data.str;
    }
    argv[total] = NULL;

    pthread_once(&g_proc_sigpipe_once, proc_install_sigpipe_ignore);

    /* FD_CLOEXEC on both ends of both pipes so subsequent proc_spawn /
     * exec_capture children don't inherit the parent's open pipes (#149).
     * The child re-dup2s these into stdin/stdout, which clears FD_CLOEXEC
     * on the destination, so the child's own stdin/stdout survives exec. */
    int in_pipe[2], out_pipe[2];
    if (pipe(in_pipe) != 0)  { free(argv); return proc_spawn_fail(); }
    if (pipe(out_pipe) != 0) { close(in_pipe[0]); close(in_pipe[1]);
                               free(argv); return proc_spawn_fail(); }
    (void)fcntl(in_pipe[0],  F_SETFD, FD_CLOEXEC);
    (void)fcntl(in_pipe[1],  F_SETFD, FD_CLOEXEC);
    (void)fcntl(out_pipe[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(out_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(in_pipe[0]); close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        free(argv);
        return proc_spawn_fail();
    }

    if (pid == 0) {
        /* Child: stdin from in_pipe read end, stdout to out_pipe write end.
         * Reset SIGPIPE to SIG_DFL — parent ignores SIGPIPE so it sees EPIPE
         * on write, but the child should die silently on broken pipe like
         * a conventional Unix process. */
        signal(SIGPIPE, SIG_DFL);
        dup2(in_pipe[0],  STDIN_FILENO);
        dup2(out_pipe[1], STDOUT_FILENO);
        close(in_pipe[0]);  close(in_pipe[1]);
        close(out_pipe[0]); close(out_pipe[1]);
        execvp(argv[0], argv);
        _exit(127);
    }

    /* Parent: keep in_pipe[1] (write to child) and out_pipe[0] (read from child). */
    close(in_pipe[0]);
    close(out_pipe[1]);
    free(argv);

    Value *r = make_list(3);
    r->data.list.items[0] = make_num((double)pid);
    r->data.list.items[1] = make_num((double)in_pipe[1]);
    r->data.list.items[2] = make_num((double)out_pipe[0]);
    r->data.list.count = 3;
    return r;
}

Value* builtin_proc_write(Value *arg) {
    if (replay_blocks("proc_write")) return make_num(-1);
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return make_num(-1);
    Value *fd_v  = arg->data.list.items[0];
    Value *str_v = arg->data.list.items[1];
    if (!fd_v || fd_v->type != VAL_NUM || !str_v || str_v->type != VAL_STR)
        return make_num(-1);
    int fd = (int)fd_v->data.num;
    if (fd < 0) return make_num(-1);
    const char *buf = str_v->data.str;
    size_t total = strlen(buf);
    size_t off = 0;
    while (off < total) {
        ssize_t n = write(fd, buf + off, total - off);
        if (n < 0) {
            if (errno == EINTR) continue;
            /* #159: return partial bytes-written instead of -1 so a
             * caller retrying on short-write doesn't double-send the
             * delivered prefix. -1 only when nothing was written. */
            return make_num(off > 0 ? (double)off : -1);
        }
        off += (size_t)n;
    }
    return make_num((double)off);
}

Value* builtin_proc_read_line(Value *arg) {
    if (replay_blocks("proc_read_line")) return make_null();
    if (!arg || arg->type != VAL_NUM) return make_null();
    int fd = (int)arg->data.num;
    if (fd < 0) return make_null();
    size_t cap = 256, len = 0;
    char *buf = xmalloc(cap + 1);
    if (!buf) return make_null();
    for (;;) {
        if (len >= cap) {
            size_t newcap = cap * 2;
            char *nb = xrealloc(buf, newcap + 1);
            if (!nb) { free(buf); return make_null(); }
            buf = nb; cap = newcap;
        }
        char c;
        ssize_t n = read(fd, &c, 1);
        if (n == 0) break;        /* EOF */
        if (n < 0) {
            if (errno == EINTR) continue;
            /* #159: mid-stream read error — return the partial line
             * we already buffered (mirrors the EOF-with-partial path
             * just below). null is reserved for "EOF, nothing read". */
            if (len == 0) { free(buf); return make_null(); }
            break;
        }
        if (c == '\n') {
            buf[len] = '\0';
            Value *s = make_str(buf);
            free(buf);
            return s;
        }
        buf[len++] = c;
    }
    if (len == 0) { free(buf); return make_null(); }
    buf[len] = '\0';
    Value *s = make_str(buf);
    free(buf);
    return s;
}

Value* builtin_proc_read(Value *arg) {
    if (replay_blocks("proc_read")) return make_null();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return make_null();
    Value *fd_v  = arg->data.list.items[0];
    Value *max_v = arg->data.list.items[1];
    if (!fd_v || fd_v->type != VAL_NUM || !max_v || max_v->type != VAL_NUM)
        return make_null();
    int fd = (int)fd_v->data.num;
    int max = (int)max_v->data.num;
    if (fd < 0 || max <= 0) return make_null();
    if (max > 10 * 1024 * 1024) max = 10 * 1024 * 1024;
    char *buf = xmalloc((size_t)max + 1);
    if (!buf) return make_null();
    ssize_t n;
    for (;;) {
        n = read(fd, buf, (size_t)max);
        if (n >= 0) break;
        if (errno == EINTR) continue;
        free(buf);
        return make_null();
    }
    if (n == 0) { free(buf); return make_null(); }
    buf[n] = '\0';
    return make_str_owned(buf);
}

/* #159: binary-safe variant of proc_read. Returns a VAL_BUFFER (no
 * NUL-truncation), null on EOF. Same 10 MB cap as proc_read. */
Value* builtin_proc_read_buf(Value *arg) {
    if (replay_blocks("proc_read_buf")) return make_null();
    if (!arg || arg->type != VAL_LIST || arg->data.list.count != 2)
        return make_null();
    Value *fd_v  = arg->data.list.items[0];
    Value *max_v = arg->data.list.items[1];
    if (!fd_v || fd_v->type != VAL_NUM || !max_v || max_v->type != VAL_NUM)
        return make_null();
    int fd = (int)fd_v->data.num;
    int max = (int)max_v->data.num;
    if (fd < 0 || max <= 0) return make_null();
    if (max > 10 * 1024 * 1024) max = 10 * 1024 * 1024;
    unsigned char *buf = xmalloc((size_t)max);
    if (!buf) return make_null();
    ssize_t n;
    for (;;) {
        n = read(fd, buf, (size_t)max);
        if (n >= 0) break;
        if (errno == EINTR) continue;
        free(buf);
        return make_null();
    }
    if (n == 0) { free(buf); return make_null(); }
    Value *v = xcalloc(1, sizeof(Value));
    v->type = VAL_BUFFER;
    v->data.buffer.count = (int)n;
    v->data.buffer.data = xcalloc((size_t)n, sizeof(double));
    v->refcount = 1;
    for (ssize_t i = 0; i < n; i++)
        v->data.buffer.data[i] = (double)buf[i];
    free(buf);
    return v;
}

Value* builtin_proc_close(Value *arg) {
    if (replay_blocks("proc_close")) return make_null();
    if (!arg || arg->type != VAL_NUM) return make_null();
    int fd = (int)arg->data.num;
    if (fd >= 0) close(fd);
    return make_null();
}

Value* builtin_proc_wait(Value *arg) {
    if (replay_blocks("proc_wait")) return make_num(-1);
    if (!arg || arg->type != VAL_NUM) return make_num(-1);
    pid_t pid = (pid_t)arg->data.num;
    if (pid <= 0) return make_num(-1);
    int status = 0;
    for (;;) {
        pid_t r = waitpid(pid, &status, 0);
        if (r == pid) break;
        if (r < 0 && errno == EINTR) continue;
        return make_num(-1);
    }
    int code = WIFEXITED(status) ? WEXITSTATUS(status)
             : WIFSIGNALED(status) ? (128 + WTERMSIG(status))
             : -1;
    return make_num((double)code);
}

/* ==== BUILTIN: random_hex ==== */
/* random_hex of n → string of n random hex characters from /dev/urandom.
 * Capability builtin: provides randomness so .eigs libraries can generate tokens. */
Value* builtin_random_hex(Value *arg) {
    int n = (arg && arg->type == VAL_NUM) ? (int)arg->data.num : 0;
    if (n <= 0 || n > 256) TRACE_NONDET_RET("random_hex", make_str(""));
    int bytes_needed = (n + 1) / 2;
    unsigned char raw[128];
    FILE *urand = fopen("/dev/urandom", "rb");
    if (!urand) TRACE_NONDET_RET("random_hex", make_str(""));
    size_t got = fread(raw, 1, bytes_needed, urand);
    fclose(urand);
    if ((int)got < bytes_needed) TRACE_NONDET_RET("random_hex", make_str(""));
    char hex[257];
    for (int i = 0; i < bytes_needed && i * 2 < n; i++)
        snprintf(hex + i * 2, 3, "%02x", raw[i]);
    hex[n] = '\0';
    TRACE_NONDET_RET("random_hex", make_str(hex));
}

/* write_bytes of [path, data, append?] — write raw bytes to a file.
 * `data` is a list of byte ints or a buffer (values taken mod 256). `append`
 * (optional, default 0): 0 truncates the file, nonzero appends. Returns the
 * number of bytes written, or 0 on failure. Unlike write_text this is
 * binary-clean — NUL bytes are written verbatim, not treated as terminators —
 * so it can carry CBOR / arbitrary binary. Surfaced by tidelog's append-only
 * log (write_text is truncate-mode and NUL-truncating). */
Value* builtin_write_bytes(Value *arg) {
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2)
        return make_num(0);
    Value *path_val = arg->data.list.items[0];
    Value *data = arg->data.list.items[1];
    if (!path_val || path_val->type != VAL_STR) return make_num(0);
    int append = 0;
    if (arg->data.list.count >= 3 && arg->data.list.items[2] &&
        arg->data.list.items[2]->type == VAL_NUM)
        append = (arg->data.list.items[2]->data.num != 0.0);

    int n = 0;
    Value **items = NULL;
    double *bufd = NULL;
    if (data && data->type == VAL_LIST) {
        n = data->data.list.count;
        items = data->data.list.items;
    } else if (data && data->type == VAL_BUFFER) {
        n = data->data.buffer.count;
        bufd = data->data.buffer.data;
    } else {
        return make_num(0);
    }

    unsigned char *out = xmalloc((size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) {
        double dv = items ? (items[i] && items[i]->type == VAL_NUM ? items[i]->data.num : 0.0)
                          : bufd[i];
        out[i] = (unsigned char)((int)dv & 0xFF);
    }
    FILE *f = xfopen_write(path_val->data.str, append ? "ab" : "wb");
    if (!f) { free(out); return make_num(0); }
    size_t written = fwrite(out, 1, (size_t)n, f);
    int close_ok = (fclose(f) == 0);
    free(out);
    return make_num((close_ok && written == (size_t)n) ? (double)written : 0);
}

void register_host_builtins(Env *env) {
    env_set_local_owned(env, "raw_key", make_builtin(builtin_raw_key));
    env_set_local_owned(env, "mkdir", make_builtin(builtin_mkdir));
    env_set_local_owned(env, "ls", make_builtin(builtin_ls));
    env_set_local_owned(env, "getcwd", make_builtin(builtin_getcwd));
    env_set_local_owned(env, "exe_path", make_builtin(builtin_exe_path));
    env_set_local_owned(env, "chdir", make_builtin(builtin_chdir));
    env_set_local_owned(env, "mktemp", make_builtin(builtin_mktemp));
    env_set_local_owned(env, "rm", make_builtin(builtin_rm));
    env_set_local_owned(env, "stream_open", make_builtin(builtin_stream_open));
    env_set_local_owned(env, "stream_write", make_builtin(builtin_stream_write));
    env_set_local_owned(env, "stream_close", make_builtin(builtin_stream_close));
    env_set_local_owned(env, "build_corpus", make_builtin(builtin_build_corpus));
    env_set_local_owned(env, "regex_match", make_builtin(builtin_match));
    env_set_local_owned(env, "regex_find", make_builtin(builtin_match_all));
    env_set_local_owned(env, "regex_replace", make_builtin(builtin_regex_replace));
    env_set_local_owned(env, "load_file", make_builtin(builtin_load_file));
    env_set_local_owned(env, "file_exists", make_builtin(builtin_file_exists));
    env_set_local_owned(env, "is_dir", make_builtin(builtin_is_dir));
    env_set_local_owned(env, "rename", make_builtin(builtin_rename));
    env_set_local_owned(env, "remove_file", make_builtin(builtin_remove_file));
    env_set_local_owned(env, "read_bytes", make_builtin(builtin_read_bytes));
    env_set_local_owned(env, "read_bytes_buf", make_builtin(builtin_read_bytes_buf));
    env_set_local_owned(env, "read_text", make_builtin(builtin_read_text));
    env_set_local_owned(env, "read_line", make_builtin(builtin_read_line));
    env_set_local_owned(env, "write_text", make_builtin(builtin_write_text));
    env_set_local_owned(env, "write_bytes", make_builtin(builtin_write_bytes));
    env_set_local_owned(env, "exec_capture", make_builtin(builtin_exec_capture));
    env_set_local_owned(env, "proc_spawn", make_builtin(builtin_proc_spawn));
    env_set_local_owned(env, "proc_write", make_builtin(builtin_proc_write));
    env_set_local_owned(env, "proc_read_line", make_builtin(builtin_proc_read_line));
    env_set_local_owned(env, "proc_read", make_builtin(builtin_proc_read));
    env_set_local_owned(env, "proc_read_buf", make_builtin(builtin_proc_read_buf));
    env_set_local_owned(env, "proc_close", make_builtin(builtin_proc_close));
    env_set_local_owned(env, "proc_wait", make_builtin(builtin_proc_wait));
    env_set_local_owned(env, "random_hex", make_builtin(builtin_random_hex));
    env_set_local_owned(env, "tensor_save", make_builtin(builtin_tensor_save));
    env_set_local_owned(env, "tensor_load", make_builtin(builtin_tensor_load));
}

#endif /* EIGENSCRIPT_FREESTANDING */
