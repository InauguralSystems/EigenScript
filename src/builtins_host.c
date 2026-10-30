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
#include "env_flag.h"
#include "state.h"
#include "vm.h"
#include "builtins_internal.h"
#include "fsutil.h"
#include "trace.h"

#if EIGENSCRIPT_FREESTANDING

/* Linkable no-op surface for the freestanding profile (the ext_store.c
 * pattern): registration registers nothing, and nothing resolves without
 * a filesystem. */
void register_host_builtins(Env *env) { (void)env; }

#else /* host profile */

#include <termios.h>

/* ==== BUILTIN: match — regex match, return list of groups ==== */
/* match of [string, pattern] -> [full_match, group1, ...] or [] */
Value* builtin_match(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "regex_match");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "regex_match requires [string, pattern]");
        return make_list(0);
    }
    if (list_elem_type(arg, 0) != VAL_STR || list_elem_type(arg, 1) != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_match: string and pattern must be strings");
        return make_list(0);
    }
    const char *str = list_get_ref(arg, 0)->data.str;
    const char *pattern = list_get_ref(arg, 1)->data.str;

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
    STRICT_LIST_MAX(arg, 2, "regex_find");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 2) {
        rt_error(EK_TYPE, 0, "regex_find requires [string, pattern]");
        return make_list(0);
    }
    if (list_elem_type(arg, 0) != VAL_STR || list_elem_type(arg, 1) != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_find: string and pattern must be strings");
        return make_list(0);
    }
    const char *str = list_get_ref(arg, 0)->data.str;
    const char *pattern = list_get_ref(arg, 1)->data.str;

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
    STRICT_LIST_MAX(arg, 3, "regex_replace");
    if (!arg || arg->type != VAL_LIST || arg->data.list.count < 3) {
        rt_error(EK_TYPE, 0, "regex_replace requires [string, pattern, replacement]");
        /* fs:CHANNEL the rt_error above already raised on g_has_error (it is
         * unconditional, not gated on g_strict), so this builtin is ALREADY
         * loud in both modes; the "" only satisfies the C signature, and the VM
         * discards it at the CHECK_ERROR seam. */
        return make_str("");
    }
    if (list_elem_type(arg, 0) != VAL_STR ||
        list_elem_type(arg, 1) != VAL_STR ||
        list_elem_type(arg, 2) != VAL_STR) {
        rt_error(EK_TYPE, 0, "regex_replace: string, pattern and replacement must be strings");
        /* fs:CHANNEL same as above — the unconditional rt_error is the error
         * channel; converting to ARG_GUARD would make this site quieter with
         * strict OFF, not louder. */
        return make_str("");
    }
    const char *str = list_get_ref(arg, 0)->data.str;
    const char *pattern = list_get_ref(arg, 1)->data.str;
    const char *replacement = list_get_ref(arg, 2)->data.str;

    regex_t re;
    /* #500: an invalid pattern used to return the input unchanged — a silent
     * no-op that hides the broken pattern. Raise. */
    if (regcomp(&re, pattern, REG_EXTENDED) != 0) {
        rt_error(EK_VALUE, 0, "regex_replace: invalid pattern '%s'", pattern);
        /* fs:CHANNEL #500 already made the invalid pattern raise unconditionally
         * (EK_VALUE, a regcomp domain failure — not an argument TYPE); the ""
         * is the discarded post-raise value. */
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
 * stream_open of ["path", count] — integral count 1..10000000; outside that range raises limit even with EIGS_STRICT=0; returns true on success, false on I/O failure
 * stream_write of value           → writes one float64, returns true on success, false on failure
 * stream_close of null            → closes the stream file, returns true on success, false on failure
 *
 * Format: [uint32 ndim=1][uint32 rows=1][uint32 cols=count][uint32 flags=0]
 *         then count × float64 values (written one at a time via stream_write)
 */

/* g_stream_file is a per-thread bridge macro (eigenscript.h, #739): one FILE*
 * per PROCESS meant stream_open's unconditional close tore down another
 * state's in-flight stream. */


Value* builtin_stream_open(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "stream_open");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "stream_open", "[path, count]", make_bool(0));
    EIGS_VIEW(path_val_view);
    Value *path_val = list_get_view(arg, 0, &path_val_view);
    EIGS_VIEW(count_val_view);
    Value *count_val = list_get_view(arg, 1, &count_val_view);
    ARG_GUARD(!path_val || path_val->type != VAL_STR || !count_val || count_val->type != VAL_NUM,
              "stream_open", "[a string path, a number count]", make_bool(0));
    if (eigs_num_arg(count_val, __func__) < 1 ||
        eigs_num_arg(count_val, __func__) > EIGS_TENSOR_MAX_ELEMENTS ||
        eigs_num_arg(count_val, __func__) != floor(eigs_num_arg(count_val, __func__))) {
        rt_error(EK_LIMIT, 0,
                 "stream_open: '%s' count %.17g is outside the 1..%d element cap",
                 path_val->data.str, eigs_num_arg(count_val, __func__),
                 EIGS_TENSOR_MAX_ELEMENTS);
        return make_bool(0);
    }
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0, "stream_open: not replayable under EIGS_REPLAY "
                 "(filesystem boundary; see docs/TRACE.md)");
        return make_bool(0);
    }
    if (g_stream_file) { fclose(g_stream_file); g_stream_file = NULL; }
    g_stream_file = xfopen_write(path_val->data.str, "wb");
    /* fs:ANSWER the arguments were already validated by the two guards above;
     * reaching here with a NULL FILE* is xfopen_write failing, and the block
     * comment over this section documents stream_open as answering 1 — so 0
     * is the "could not open" answer, not a type mistake. */
    if (!g_stream_file) return make_bool(0);
    uint32_t count = (uint32_t)eigs_num_arg(count_val, __func__);
    uint32_t header[4] = { 1, 1, count, 0 }; /* ndim=1, rows=1, cols=count, flags=0 */
    if (fwrite(header, sizeof(uint32_t), 4, g_stream_file) != 4) {
        fclose(g_stream_file);
        g_stream_file = NULL;
        /* fs:ANSWER a short fwrite(3) of the header — an I/O failure after the
         * file was already opened; 0 is the failure bit paired with the
         * make_bool(1) success value below. */
        return make_bool(0);
    }
    return make_bool(1);
}

Value* builtin_stream_write(Value *arg) {
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0, "stream_write: not replayable under EIGS_REPLAY "
                 "(filesystem boundary; see docs/TRACE.md)");
        return make_bool(0);
    }
    /* The two halves of the original single condition are separated because
     * only one of them is about the ARGUMENT: `!g_stream_file` is a stream
     * state, and strict must not report it as a type error. Both halves still
     * answer make_bool(0) with strict off, in either order, so the non-strict
     * result is unchanged. */
    ARG_GUARD(!arg || arg->type != VAL_NUM, "stream_write", "a number", make_bool(0));
    /* fs:ANSWER no stream is open — the state, not the argument (which the
     * guard above already accepted); 0 is the failure bit paired with the
     * make_bool(1) success value below. */
    if (!g_stream_file) return make_bool(0);
    double val = eigs_num_arg(arg, __func__);
    if (fwrite(&val, sizeof(double), 1, g_stream_file) != 1) {
        fclose(g_stream_file);
        g_stream_file = NULL;
        /* fs:ANSWER a short fwrite(3) of one float64 — an I/O failure, not an
         * argument mistake; 0 is this builtin's documented failure bit. */
        return make_bool(0);
    }
    return make_bool(1);
}

Value* builtin_stream_close(Value *arg) {
    (void)arg;
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0, "stream_close: not replayable under EIGS_REPLAY "
                 "(filesystem boundary; see docs/TRACE.md)");
        return make_bool(0);
    }
    /* fs:ANSWER stream_close ignores `arg` entirely ((void)arg above), so this
     * cannot be an argument guard: no stream is open, and 0 is the failure bit
     * paired with the ok?1:0 value below. */
    if (!g_stream_file) return make_bool(0);
    int ok = (fclose(g_stream_file) == 0);
    g_stream_file = NULL;
    return make_bool(ok);
}

/* ---- Filesystem ---- */


/* Forward declarations for the taped filesystem error representation shared
 * by mkdir/ls and the file readers below. */
static Value *file_io_error(const char *fn, const char *path, int err);
static int file_io_replay(const char *fn, Value **out);

/* mkdir of "path" → true on success; I/O failure raises EK_IO. Creates parents. */
/* #585/#1885: replay is side-effect-free: TAKE precedes mkdir(2), as it does
 * for every replayable filesystem mutation. */
Value* builtin_mkdir(Value *arg) {
    ARG_GUARD_TAPED(!arg || arg->type != VAL_STR, "mkdir", "a string path", make_bool(0));
    Value *replayed = NULL;
    if (file_io_replay("mkdir", &replayed)) return replayed;
    /* Simple recursive mkdir */
    char *path = xstrdup(arg->data.str);
    int len = strlen(path);
    for (int i = 1; i <= len; i++) {
        if (path[i] == '/' || path[i] == '\0') {
            char saved = path[i];
            path[i] = '\0';
            if (mkdir(path, 0755) != 0 && errno != EEXIST) {
                int err = errno;
                free(path);
                return file_io_error("mkdir", arg->data.str, err);
            }
            path[i] = saved;
        }
    }
    free(path);
    struct stat st;
    if (stat(arg->data.str, &st) != 0)
        return file_io_error("mkdir", arg->data.str, errno);
    if (!S_ISDIR(st.st_mode))
        return file_io_error("mkdir", arg->data.str, ENOTDIR);
    TRACE_NONDET_RECORD("mkdir", make_bool(1));
}

static int ls_entry_cmp(const void *a, const void *b) {
    const Value *va = slot_as_ptr(*(const EigsSlot *)a);
    const Value *vb = slot_as_ptr(*(const EigsSlot *)b);
    return strcmp(va->data.str, vb->data.str);
}

/* ls of "path" → bytewise-sorted filenames; I/O failure raises EK_IO.
 * Matches `LC_ALL=C ls -1` default behavior: hidden entries (starting with '.')
 * are excluded and names are sorted bytewise. */
Value* builtin_ls(Value *arg) {
    ARG_GUARD_TAPED(!arg || arg->type != VAL_STR, "ls", "a string path", make_list(0));
    /* #585: builds its return (a list) via readdir, so under EIGS_REPLAY the
     * TAKE short-circuits before opendir — the recorded listing is served and
     * the live directory is never read. */
    Value *replayed = NULL;
    if (file_io_replay("ls", &replayed)) return replayed;
    Value *list = make_list(0);
    DIR *d = opendir(arg->data.str);
    if (!d) {
        int err = errno;
        val_decref(list);
        return file_io_error("ls", arg->data.str, err);
    }
    struct dirent *entry;
    while ((entry = readdir(d))) {
        if (entry->d_name[0] == '.') continue;
        list_append_owned(list, make_str(entry->d_name));
    }
    closedir(d);
    list_sort(list, ls_entry_cmp);
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
 * which is more robust than assuming `eigenscript` is on PATH. The state
 * captures the host path before script code can change the cwd. */
Value* builtin_exe_path(Value *arg) {
    (void)arg;
    /* #585: the interpreter path is machine-dependent — taped so replay
     * serves the recorded path without consulting the host anchor. */
    TRACE_NONDET_TAKE("exe_path");
    TRACE_NONDET_RECORD("exe_path", make_str(g_exe_path ? g_exe_path : "eigenscript"));
}

/* mktemp of null → path to a new temporary file */
Value* builtin_mktemp(Value *arg) {
    (void)arg;
    /* A fresh pathname is host state and creating it is a side effect.  The
     * tape records neither, so replay must stop before mkstemp creates a file. */
    if (__builtin_expect(g_replay_enabled, 0)) {
        rt_error(EK_IO, 0,
                 "mktemp: not replayable under EIGS_REPLAY (filesystem "
                 "boundary; see docs/TRACE.md)");
        return make_str("");
    }
    char tmpl[] = "/tmp/eigen_XXXXXX";
    int fd = mkstemp(tmpl);
    /* fs:ANSWER mktemp ignores `arg` entirely ((void)arg above), so this cannot
     * be an argument guard: mkstemp(3) failed and "" is the no-path result. */
    if (fd < 0) return make_str("");
    close(fd);
    return make_str(tmpl);
}

/* ================================================================
 * LOAD_FILE — include mechanism for .eigs modules
 * ================================================================ */

/* Tape identities are already canonical recording-time identities.  Resolving
 * them again would make replay depend on today's symlinks. */
static char *recorded_file_directory(const char *path) {
    char *dir = xstrdup(path);
    char *slash = strrchr(dir, '/');
    if (slash == dir) dir[1] = '\0';
    else if (slash) *slash = '\0';
    else { free(dir); dir = xstrdup("."); }
    return dir;
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
    char *tape_identity = NULL;
    char *tape_error = NULL;

    int replay_source = trace_source_replay("load_file_source", &source, &size,
                                             &tape_identity, &tape_error);
    if (replay_source < 0) {
        /* The tape reader already raised the precise structural error.  This
         * is not a cache miss: never resolve or read a live path after it. */
        return make_null();
    }
    if (replay_source > 0) {
        if (tape_error) {
            rt_error(EK_IO, 0, "%s", tape_error);
            free(tape_error);
            return make_null();
        }
        snprintf(resolved, sizeof resolved, "%s", tape_identity);
        free(tape_identity);
        tape_identity = NULL;
        path = resolved;
    } else {

        if (resolve_eigenscript_file(arg->data.str, resolved, sizeof(resolved))) {
            path = resolved;
            source = read_file_util(path, &size);
        }

        if (!source) {
        /* #490: match import's severity — a missing path is a catchable io
         * error, not a stderr-warn + silent null (rc=0). Callers that ignore
         * the return otherwise run on half-initialized state. */
            char *message = eigs_file_resolve_message("load_file", eigs_current_file_dir(),
                                                       arg->data.str);
            trace_source_record("load_file_source", NULL, 0, NULL, message);
            rt_error(EK_IO, 0, "%s", message);
            free(message);
            return make_null();
        }
        char canonical[8192];
        if (!realpath(path, canonical)) snprintf(canonical, sizeof canonical, "%s", path);
        trace_source_record("load_file_source", source, (size_t)size, canonical, NULL);
        snprintf(resolved, sizeof resolved, "%s", canonical);
        path = resolved;
    }

    /* #496: circular-load guard. load_file has no module cache — it
     * re-executes every call — so a mutual load (a loads b, b loads a)
     * recurses through vm_execute to a C-stack SIGSEGV. Key on the
     * canonical path (shared with import's cycle stack) and raise if this
     * path's load is already on the stack. Sequential re-loads of the same
     * file stay legal: the entry pops when each load completes. */
    char abs_key[8192];
    if (replay_source > 0)
        snprintf(abs_key, sizeof(abs_key), "%s", path);
    else if (!realpath(path, abs_key))
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
    if (eigs_env_flag("EIGS_VERBOSE_LOAD"))
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

    EigsStderrSilence parse_guard;
    eigs_json_parse_silence_begin(&parse_guard);
    TokenList tl = tokenize(source);
    ASTNode *ast = parse(&tl);
    eigs_json_parse_silence_end(&parse_guard);

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
    /* #915: the observer gate may have CLOSED on evidence gathered when this
     * unit's parent was compiled — the eager pre-pass resolved this literal
     * target and compiled it then. The file it read and the file being compiled
     * now are two separate reads with the whole program running in between, so
     * they can differ: the program can rewrite the module (`write_text` then
     * `load_file`), or create a nearer file that shadows the resolved target.
     * Both shapes can otherwise produce a silently wrong answer —
     * `report of x` read `equilibrium` under the gate and `moving` without it.
     *
     * ASK THE ACTUAL QUESTION. A first draft compared the observer bit before
     * and after the module's compile and raised on a 0 -> 1 transition. Two
     * blind-critic repros killed it:
     *
     *   - ONE-SHOT. The bit is monotonic, so that first transition leaves it at
     *     1 and every later load saw "already open" and skipped the check. The
     *     error is catchable, so a single `try:` around the first load disarmed
     *     the guard for the rest of the run and restored the exact silent-wrong
     *     answer the guard was written to stop.
     *   - OVER-BROAD. The bit flips for any of the eager pass's SIX conservative
     *     bail-outs, not just for staleness. One of them (`L.count > 0 &&
     *     g_vm_multithreaded`) is reachable at run time but not at the parent's
     *     compile time, so `spawn` + a module that itself loads a module became
     *     a hard error with every clause of the message false. That shape is
     *     shipped: lib/io.eigs does `load_file of "lib/string.eigs"`.
     *
     * So the predicate is the module's OWN verdict — does this chunk read
     * observer state? — and the precondition is "this program has bindings with
     * no recorded history", which is sticky rather than derived from a bit that
     * the detection itself changes. */
    /* ACQUIRE: this is the one read that pairs with eigs_obs_enable's
     * store ORDER (gap then needed) — see obs_flag_store in eigenscript.h. */
    int obs_before_module = obs_flag_load_acquire(obs_needed);
    char *saved_resolve_dir = xstrdup(g_import_resolve_dir);
    char *loaded_dir = replay_source > 0
        ? recorded_file_directory(abs_key) : eigs_file_directory(abs_key);
    snprintf(g_import_resolve_dir, sizeof(g_import_resolve_dir), "%s", loaded_dir);
    free(loaded_dir);
    EigsChunk *lf_chunk = compile_ast(ast, target, source, path);
    snprintf(g_import_resolve_dir, sizeof(g_import_resolve_dir), "%s", saved_resolve_dir);
    free(saved_resolve_dir);
    g_compile_module_boundary = saved_boundary;
    if (lf_chunk && chunk_reads_observer(lf_chunk) &&
        (!obs_before_module || g_obs_history_gap)) {
        obs_flag_store(obs_history_gap, 1);
        g_parse_errors = saved_errors;
        chunk_free(lf_chunk);
        free_ast(ast);
        free_tokenlist(&tl);
        free(source);
        rt_error(EK_IO, 0,
            "load_file: '%s' reads observer state, but the observer gate was "
            "closed when this program's earlier assignments ran — they have no "
            "recorded history, so an observer query about them would answer a "
            "rest value rather than the truth. Re-run with EIGS_OBS_FORCE=1.",
            arg->data.str);
        return make_null();
    }
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
    ARG_GUARD_TAPED(!arg || arg->type != VAL_STR, "file_exists", "a string path", make_bool(0));
    /* #585: fs-dependent read — taped so replay serves the recorded answer.
     * TAKE short-circuits before the fopen probe under EIGS_REPLAY. */
    TRACE_NONDET_TAKE("file_exists");
    /* #1070: a stat() probe, not fopen(). fopen on a reader-less fifo (or a
     * device that blocks on open) never returned -- the program hung with no
     * diagnostic, while is_file on the same path answered 0 at once. stat
     * answers the question the name asks and never blocks; directories and
     * devices stay 1 as before. */
    struct stat st;
    int ex = (stat(arg->data.str, &st) == 0);
    TRACE_NONDET_RECORD("file_exists", make_bool(ex));
}

/* is_dir of path — true if path names a directory, false for a plain file, a
 * missing path, or a non-string arg. Replaces the consumer-side
 * `file_exists of f"{path}/."` probe (#576). Nondeterministic fs read →
 * trace-recorded per the tape-first rule (NB: the older fs predicates —
 * file_exists, ls, mkdir, getcwd — predate the tape and are untraced;
 * that inconsistency is flagged on the PR, not silently copied here). */
Value* builtin_is_dir(Value *arg) {
    ARG_GUARD_TAPED(!arg || arg->type != VAL_STR, "is_dir", "a string path", make_bool(0));
    struct stat st;
    TRACE_NONDET_RET("is_dir",
        make_bool(stat(arg->data.str, &st) == 0 && S_ISDIR(st.st_mode)));
}

/* #1058: `is_file of path` -- 1 iff the path names a REGULAR file (S_ISREG).
 * read_file_util admits only regular files (#314), and a driver that must
 * match that admission contract before reading had only file_exists (an
 * fopen probe: opens /dev/null, fifos, directories) and is_dir -- the
 * non-regular non-directory class passed both and read as "", so /dev/null
 * compiled to the empty program. Taped like is_dir. */
Value* builtin_is_file(Value *arg) {
    ARG_GUARD_TAPED(!arg || arg->type != VAL_STR, "is_file", "a string path", make_bool(0));
    struct stat st;
    TRACE_NONDET_RET("is_file",
        make_bool(stat(arg->data.str, &st) == 0 && S_ISREG(st.st_mode)));
}

static Value *file_io_error(const char *fn, const char *path, int err);

/* rename of [old_path, new_path] — rename/replace a file. On POSIX rename(2) is
 * atomic: a crash leaves either the old file or the new file fully in place,
 * never a torn mix — the basis for crash-safe log compaction (write a new log to
 * a temp file, then atomically swap it in). Returns true on success; I/O
 * failure raises EK_IO. */
Value* builtin_rename(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "rename");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "rename", "[old_path, new_path]", make_bool(0));
    EIGS_VIEW(from_view);
    Value *from = list_get_view(arg, 0, &from_view);
    EIGS_VIEW(to_view);
    Value *to = list_get_view(arg, 1, &to_view);
    ARG_GUARD(!from || from->type != VAL_STR || !to || to->type != VAL_STR,
              "rename", "two string paths", make_bool(0));
    Value *replayed = NULL;
    if (file_io_replay("rename", &replayed)) return replayed;
    int ok = rename(from->data.str, to->data.str) == 0;
    int err = ok ? 0 : errno;
    /* #1885: TAKE precedes rename(2); replay never mutates the filesystem. */
    if (!ok) {
        char path[3900];
        snprintf(path, sizeof(path), "%s' to '%s", from->data.str, to->data.str);
        return file_io_error("rename", path, err);
    }
    TRACE_NONDET_RECORD("rename", make_bool(1));
}

/* remove_file of path — delete a file. Returns true on success; I/O failure raises. */
Value* builtin_remove_file(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "remove_file", "a string path", make_bool(0));
    Value *replayed = NULL;
    if (file_io_replay("remove_file", &replayed)) return replayed;
    int ok = remove(arg->data.str) == 0;
    int err = ok ? 0 : errno;
    if (!ok) return file_io_error("remove_file", arg->data.str, err);
    TRACE_NONDET_RECORD("remove_file", make_bool(1));
}

#ifdef EIGS_TEST_HOOKS
/* Supplied only by the dedicated fsync test binary.  Production builds have
 * neither the hook nor any runtime mechanism that can enable it. */
extern int eigs_test_fsync_hook(int fd, const char *kind);
#endif

static int eigs_sync_fd(int fd, const char *kind) {
#ifdef EIGS_TEST_HOOKS
    return eigs_test_fsync_hook(fd, kind);
#else
    (void)kind;
    return fsync(fd);
#endif
}

static Value *sync_path(Value *arg, const char *fn, int want_directory) {
    Value *replayed = NULL;
    if (file_io_replay(fn, &replayed)) return replayed;

    int fd = open(arg->data.str, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) return file_io_error(fn, arg->data.str, errno);
    struct stat st;
    int ok = fstat(fd, &st) == 0;
    int err = ok ? 0 : errno;
    if (ok && ((want_directory && !S_ISDIR(st.st_mode)) ||
               (!want_directory && !S_ISREG(st.st_mode)))) {
        ok = 0;
        err = want_directory ? ENOTDIR : EISDIR;
    }
    if (ok && eigs_sync_fd(fd, fn) != 0) {
        ok = 0;
        err = errno;
    }
    if (close(fd) != 0 && ok) {
        ok = 0;
        err = errno;
    }
    if (!ok) return file_io_error(fn, arg->data.str, err);
    if (want_directory) TRACE_NONDET_RECORD("dir_sync", make_bool(1));
    TRACE_NONDET_RECORD("file_sync", make_bool(1));
}

/* file_sync of path — flush a regular file's data and metadata to storage. */
Value* builtin_file_sync(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "file_sync", "a string path", make_bool(0));
    return sync_path(arg, "file_sync", 0);
}

/* dir_sync of path — flush directory-entry changes to storage. */
Value* builtin_dir_sync(Value *arg) {
    ARG_GUARD(!arg || arg->type != VAL_STR, "dir_sync", "a string path", make_bool(0));
    return sync_path(arg, "dir_sync", 1);
}

/* ==== BUILTIN: read_text ==== */
/* Taped filesystem errors use a result shape that cannot be successful: a
 * one-string list for readers/mkdir, and [message, null] for ls (whose normal
 * result may itself be a one-string list). */
static Value *file_io_error_message(const char *fn, const char *message) {
    int taped = trace_core_kind_declared(fn);
    if (taped && __builtin_expect(g_trace_enabled, 0)) {
        Value *record = make_list(strcmp(fn, "ls") == 0 ? 2 : 1);
        list_append_owned(record, make_str(message));
        /* An ls success may itself be a one-string list.  The trailing null
         * makes its error record an impossible successful directory listing. */
        if (strcmp(fn, "ls") == 0) list_append_owned(record, make_null());
        trace_nondet_value(fn, record);
        val_decref(record);
    }
    rt_error(EK_IO, 0, "%s", message);
    return make_null();
}

static Value *file_io_error(const char *fn, const char *path, int err) {
    char message[3900];
    snprintf(message, sizeof(message), "%s: '%s': %s",
             fn, path, strerror(err));
    return file_io_error_message(fn, message);
}

/* Return zero only when replay is disabled.  Once replay is enabled every
 * result, including an unservable/corrupt record, short-circuits live I/O. */
static int file_io_replay(const char *fn, Value **out) {
    *out = NULL;
    if (!__builtin_expect(g_replay_enabled, 0)) return 0;
    if (trace_replay_refuse_off_owner(fn)) { *out = make_null(); return 1; }
    Value *v = NULL;
    if (!trace_replay_take(fn, &v)) {
        if (!g_has_error) rt_error(EK_IO, 0, "%s: unservable replay record", fn);
        *out = make_null();
        return 1;
    }
    if (v && v->type == VAL_LIST && v->data.list.count >= 1 &&
        list_elem_type(v, 0) == VAL_STR &&
        ((strcmp(fn, "ls") != 0 && v->data.list.count == 1) ||
         (strcmp(fn, "ls") == 0 && v->data.list.count == 2 &&
          list_elem_type(v, 1) == VAL_NULL))) {
        const char *message = list_get_ref(v, 0)->data.str;
        rt_error(EK_IO, 0, "%s", message);
        val_decref(v);
        *out = make_null();
        return 1;
    }
    *out = v;
    return 1;
}

static int file_is_directory(FILE *f) {
    struct stat st;
    return fstat(fileno(f), &st) == 0 && S_ISDIR(st.st_mode);
}

#define READ_BYTES_BUF_DEFAULT_CAP (10LL * 1024 * 1024)
#define READ_BYTES_BUF_HARD_CAP    (512LL * 1024 * 1024)

/* Parse the cap before the tape boundary so live and replay calls use the
 * same policy. Guard failures are returned to each reader so its historical
 * ARG_GUARD_PRETAKE fallback (and tape entry) remains reader-specific. */
static const char *reader_cap_parse(const char *fn, Value *arg, Value **path,
                                    long long *cap) {
    *path = arg;
    *cap = READ_BYTES_BUF_DEFAULT_CAP;
    if (arg && arg->type == VAL_LIST) {
        if (arg->data.list.count < 1) {
            rt_error(EK_TYPE, 0, "%s requires a path: %s of path, or %s of [path, max_bytes]",
                     fn, fn, fn);
            return NULL;
        }
        *path = list_get_ref(arg, 0);
        if (arg->data.list.count >= 2) {
            EIGS_VIEW(mv_view);
            Value *mv = list_get_view(arg, 1, &mv_view);
            if (!mv || mv->type != VAL_NUM) {
                return "max_bytes to be a number";
            }
            double n = eigs_num_arg(mv, __func__);
            int64_t exact;
            if (isfinite(n) && num_to_i64_exact(n, &exact) && exact < 1)
                return "max_bytes to be a positive number";
            if (!isfinite(n) || !num_to_i64_exact(n, &exact) ||
                exact > READ_BYTES_BUF_HARD_CAP) {
                rt_error(EK_VALUE, 0,
                         "%s: max_bytes must be an exact integer in 1..%lld (got %g)",
                         fn, READ_BYTES_BUF_HARD_CAP, n);
                return NULL;
            }
            *cap = (long long)exact;
        }
    }
    if (!*path || (*path)->type != VAL_STR) {
        return "a string path";
    }
    return "";
}

/* One raise site shared by all readers and by live and replay paths. */
static void reader_cap_raise(const char *fn, const char *path, long long len,
                             long long cap) {
    if (__builtin_expect(g_trace_enabled, 0)) {
        Value *sz = make_num((double)len);
        trace_nondet_value(fn, sz);
        val_decref(sz);
    }
    rt_error(EK_IO, 0,
             "%s: '%s' is %lld bytes, over the %lld-byte cap — pass %s of "
             "[path, max_bytes] (hard ceiling %lld) to raise it",
             fn, path, len, cap, fn, READ_BYTES_BUF_HARD_CAP);
}

/* A seekable regular file keeps the historical size-then-read path below.
 * When tell cannot supply a size, grow only as data arrives and stop after
 * cap+1 bytes: that is enough to distinguish success from the capped error
 * without turning an infinite stream into an unbounded allocation. */
static int read_stream_bounded(FILE *f, size_t cap, unsigned char **out,
                               size_t *out_len, int *read_err) {
    unsigned char *buf = NULL;
    size_t len = 0, alloc = 0;
    while (len <= cap) {
        size_t room = alloc - len;
        if (room == 0) {
            size_t next = alloc ? alloc * 2 : 65536;
            if (next > cap + 1) next = cap + 1;
            unsigned char *grown = realloc(buf, next ? next : 1);
            if (!grown) { free(buf); *read_err = ENOMEM; return 0; }
            buf = grown;
            alloc = next;
            room = alloc - len;
        }
        /* Do not mistake the preceding failed seek's ESPIPE for a read error
         * on implementations where stdio sets ferror without setting errno. */
        errno = 0;
        size_t got = fread(buf + len, 1, room, f);
        len += got;
        if (got < room) {
            if (ferror(f)) {
                *read_err = errno ? errno : EIO;
                free(buf);
                return 0;
            }
            break;
        }
        if (len == cap + 1) break;
    }
    *out = buf;
    *out_len = len;
    return 1;
}

static int replay_reader_size(const char *fn, Value *v, long long *out) {
    double n = eigs_num_arg(v, __func__);
    int64_t exact;
    if (!isfinite(n) || n < 0.0 || !num_to_i64_exact(n, &exact)) {
        rt_error(EK_IO, 0,
                 "%s: replay record size is not an exact integer in range; "
                 "refusing to replay", fn);
        return 0;
    }
    *out = (long long)exact;
    return 1;
}

/* read_text of "path" → file contents as string; I/O failure raises EK_IO. */
/* read_bytes of path — read binary file, return list of byte values (0-255) */
Value* builtin_read_bytes(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "read_bytes");
    Value *path;
    long long cap;
    const char *guard = reader_cap_parse("read_bytes", arg, &path, &cap);
    if (!guard) return make_null();
    ARG_GUARD_PRETAKE(*guard, "read_bytes", guard, make_null());
    Value *replayed = NULL;
    if (file_io_replay("read_bytes", &replayed)) {
        if (replayed->type == VAL_NUM) {
            long long len;
            if (!replay_reader_size("read_bytes", replayed, &len)) {
                val_decref(replayed);
                return make_null();
            }
            val_decref(replayed);
            reader_cap_raise("read_bytes", path->data.str, len, cap);
            return make_null();
        }
        return replayed;
    }
    FILE *f = fopen(path->data.str, "rb");
    if (!f) return file_io_error("read_bytes", path->data.str, errno);
    if (file_is_directory(f)) {
        fclose(f);
        return file_io_error("read_bytes", path->data.str, EISDIR);
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) {
        clearerr(f);
        unsigned char *buf = NULL;
        size_t nread = 0;
        int read_err = 0;
        if (!read_stream_bounded(f, (size_t)cap, &buf, &nread, &read_err)) {
            fclose(f);
            return file_io_error("read_bytes", path->data.str, read_err);
        }
        fclose(f);
        if (nread > (size_t)cap) {
            free(buf);
            reader_cap_raise("read_bytes", path->data.str, (long long)nread, cap);
            return make_null();
        }
        Value *result = make_list((int)nread);
        for (size_t i = 0; i < nread; i++)
            list_append_owned(result, make_num((double)buf[i]));
        free(buf);
        TRACE_NONDET_RECORD("read_bytes", result);
    }
    if ((long long)len > cap) {
        fclose(f);
        reader_cap_raise("read_bytes", path->data.str, (long long)len, cap);
        return make_null();
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
 * Missing/unopenable files raise EK_IO, like the other file readers. */
Value* builtin_read_bytes_buf(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "read_bytes_buf");
    /* Deterministic argument parse, BEFORE the tape boundary: a bad call
     * shape takes the same path live and under replay, consuming no N
     * record either way. */
    Value *path;
    long long cap;
    const char *guard = reader_cap_parse("read_bytes_buf", arg, &path, &cap);
    if (!guard) return make_null();
    ARG_GUARD_PRETAKE(*guard, "read_bytes_buf", guard, make_null());

    /* Tape boundary. Success records the VAL_BUFFER; unopenable file
     * records an impossible-success error list. A regular-file over-cap
     * raise records its known size as a VAL_NUM; an unseekable stream records
     * its non-exact error message. Both replay without live filesystem I/O. */
    if (__builtin_expect(g_replay_enabled, 0)) {
        Value *tv = NULL;
        if (file_io_replay("read_bytes_buf", &tv)) {
            if (tv && tv->type == VAL_NUM) {
                long long len;
                if (!replay_reader_size("read_bytes_buf", tv, &len)) {
                    val_decref(tv);
                    return make_null();
                }
                val_decref(tv);
                reader_cap_raise("read_bytes_buf", path->data.str, len, cap);
                return make_null();
            }
            return tv;
        }
    }
    FILE *f = fopen(path->data.str, "rb");
    if (!f) return file_io_error("read_bytes_buf", path->data.str, errno);
    if (file_is_directory(f)) {
        fclose(f);
        return file_io_error("read_bytes_buf", path->data.str, EISDIR);
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) {
        clearerr(f);
        unsigned char *buf = NULL;
        size_t nread = 0;
        int read_err = 0;
        if (!read_stream_bounded(f, (size_t)cap, &buf, &nread, &read_err)) {
            fclose(f);
            return file_io_error("read_bytes_buf", path->data.str, read_err);
        }
        fclose(f);
        if (nread > (size_t)cap) {
            free(buf);
            reader_cap_raise("read_bytes_buf", path->data.str,
                             (long long)nread, cap);
            return make_null();
        }
        Value *v = xcalloc(1, sizeof(Value));
        v->type = VAL_BUFFER; v->data.buffer.count = (int)nread;
        v->data.buffer.data = xcalloc(nread ? nread : 1, sizeof(double));
        v->refcount = 1;
        for (size_t i = 0; i < nread; i++) v->data.buffer.data[i] = (double)buf[i];
        free(buf);
        TRACE_NONDET_RECORD("read_bytes_buf", v);
    }
    if ((long long)len > cap) {
        fclose(f);
        reader_cap_raise("read_bytes_buf", path->data.str, (long long)len, cap);
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
    STRICT_LIST_MAX(arg, 2, "read_text");
    Value *path;
    long long cap;
    const char *guard = reader_cap_parse("read_text", arg, &path, &cap);
    if (!guard) return make_null();
    ARG_GUARD_PRETAKE(*guard, "read_text", guard, make_str(""));
    Value *replayed = NULL;
    if (file_io_replay("read_text", &replayed)) {
        if (replayed->type == VAL_NUM) {
            long long len;
            if (!replay_reader_size("read_text", replayed, &len)) {
                val_decref(replayed);
                return make_null();
            }
            val_decref(replayed);
            reader_cap_raise("read_text", path->data.str, len, cap);
            return make_null();
        }
        return replayed;
    }
    FILE *f = fopen(path->data.str, "r");
    if (!f) return file_io_error("read_text", path->data.str, errno);
    if (file_is_directory(f)) {
        fclose(f);
        return file_io_error("read_text", path->data.str, EISDIR);
    }
    fseek(f, 0, SEEK_END);
    long len = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (len < 0) {
        clearerr(f);
        unsigned char *stream = NULL;
        size_t nread = 0;
        int read_err = 0;
        if (!read_stream_bounded(f, (size_t)cap, &stream, &nread, &read_err)) {
            fclose(f);
            return file_io_error("read_text", path->data.str, read_err);
        }
        fclose(f);
        if (nread > (size_t)cap) {
            free(stream);
            reader_cap_raise("read_text", path->data.str, (long long)nread, cap);
            return make_null();
        }
        char *buf = xmalloc(nread + 1);
        memcpy(buf, stream, nread); buf[nread] = '\0'; free(stream);
        Value *result = make_str(buf); free(buf);
        TRACE_NONDET_RECORD("read_text", result);
    }
    if ((long long)len > cap) {
        fclose(f);
        reader_cap_raise("read_text", path->data.str, (long long)len, cap);
        return make_null();
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
 * returns the next line including its line terminator, or null at EOF.
 * Thus "\r\n" stays byte-exact and a terminated final line differs from
 * an unterminated one. An empty line is "\n" — distinguishable from EOF.
 * The line-oriented stdin primitive (#558). Unlike read_text of
 * "/dev/stdin", this returns one line per call rather than consuming the
 * stream through EOF. Nondeterministic input →
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
    Value *v = make_str(line);
    free(line);
    TRACE_NONDET_RECORD("read_line", v);
}

/* ==== BUILTIN: write_text ==== */
/* write_text of ["path", text] → true on success; I/O failure raises EK_IO. */
Value* builtin_write_text(Value *arg) {
    STRICT_LIST_MAX(arg, 2, "write_text");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "write_text", "[path, text]", make_bool(0));
    EIGS_VIEW(path_val_view);
    Value *path_val = list_get_view(arg, 0, &path_val_view);
    EIGS_VIEW(text_val_view);
    Value *text_val = list_get_view(arg, 1, &text_val_view);
    ARG_GUARD(!path_val || path_val->type != VAL_STR ||
              !text_val || text_val->type != VAL_STR,
              "write_text", "two strings", make_bool(0));
    Value *replayed = NULL;
    if (file_io_replay("write_text", &replayed)) return replayed;
    FILE *f = xfopen_write(path_val->data.str, "w");
    /* Both arguments were accepted by the guards above; a NULL FILE* is
     * xfopen_write failing (missing directory, permissions, sandbox), which
     * raises EK_IO with the path and the OS reason, as the header says (#1668). */
    if (!f) {
        int err = errno;
        return file_io_error("write_text", path_val->data.str, err);
    }
    size_t len = val_str_len(text_val);
    size_t written = fwrite(text_val->data.str, 1, len, f);
    int write_err = written == len ? 0 : errno;
    int close_ok = (fclose(f) == 0);
    int close_err = errno;
    if (written != len || !close_ok)
        return file_io_error("write_text", path_val->data.str,
                             write_err ? write_err : (close_err ? close_err : EIO));
    TRACE_NONDET_RECORD("write_text", make_bool(1));
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
    list_append_num(result, code);
    list_append_owned(result, make_str(text));
    return result;
}

Value* builtin_exec_capture(Value *arg) {
    /* fs:CHANNEL replay refuses the exec; the refusal belongs to the replay
     * layer and [-1, ""] is exec_capture's documented "did not run". */
    /* #1008: these launder through a HELPER, so no `return make_num(-1)`
     * appears and the classifier's matcher — which enumerates literal soft
     * returns — cannot see them at all. ARG_GUARD's soft argument is
     * evaluated only on the non-strict path, so the helper call is fine
     * there and the default answer is unchanged. */
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 1,
              "exec_capture", "[command, ...] or [[command, ...], timeout]",
              exec_capture_result(-1, ""));
    /* fs:CHANNEL replay refuses the exec; the refusal belongs to the replay
     * layer and [-1, ""] is exec_capture's documented "did not run". #1072:
     * after the argument guard, so a wrong-typed call errs the same way in
     * both modes. */
    if (replay_blocks("exec_capture", "subprocess/concurrency")) return exec_capture_result(-1, "");

    /* Detect timeout form: [["cmd", ...], timeout_num] */
    double timeout_sec = -1;
    Value *cmd_list = arg;
    if (arg->data.list.count == 2
        && list_elem_type(arg, 0) == VAL_LIST
        && list_elem_type(arg, 1) == VAL_NUM) {
        cmd_list = list_get_ref(arg, 0);
        timeout_sec = eigs_list_num(arg, 1, __func__);
        ARG_GUARD(cmd_list->data.list.count < 1,
                  "exec_capture", "a non-empty command list", exec_capture_result(-1, ""));
    }

    int total = cmd_list->data.list.count;

    /* Build argv array */
    char **argv = xmalloc_array((size_t)total + 1, sizeof(char*));
    /* fs:ANSWER the allocation failed, so no command was run — a resource
     * outcome, not an argument the caller got wrong. */
    if (!argv) return exec_capture_result(-1, "");
    for (int i = 0; i < total; i++) {
        EIGS_VIEW(v_view);
        Value *v = list_get_view(cmd_list, i, &v_view);
        if (!v || v->type != VAL_STR) {
            free(argv);
            ARG_GUARD(1, "exec_capture", "a list of strings", exec_capture_result(-1, ""));
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
    /* fs:ANSWER pipe() failed (fd exhaustion), so the child was never
     * started — resource state, not a bad argument. */
    if (pipe(pipefd) != 0) { free(argv); return exec_capture_result(-1, ""); }
    (void)fcntl(pipefd[0], F_SETFD, FD_CLOEXEC);
    (void)fcntl(pipefd[1], F_SETFD, FD_CLOEXEC);

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]); close(pipefd[1]);
        free(argv);
        /* fs:ANSWER fork() failed, so nothing ran. Resource state. */
        return exec_capture_result(-1, "");
    }

    if (pid == 0) {
        /* Child: redirect stdout to pipe, stdin to /dev/null.
         * Reset SIGPIPE to SIG_DFL — a host may ignore it, and that
         * disposition survives exec; without an explicit reset here the
         * captured child silently no-ops on
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
        /* fs:ANSWER the output buffer could not be allocated, so the child
     * was killed and there is no capture to report. Resource state. */
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

/* ==== BUILTIN: random_hex ==== */
/* random_hex of n → string of n random hex characters from /dev/urandom.
 * Capability builtin: provides randomness so .eigs libraries can generate tokens. */
Value* builtin_random_hex(Value *arg) {
    /* #971 Phase D: a non-number length answered "" (as does a length of 0,
     * which stays the answer). Taped: the soft half records as before. */
    ARG_GUARD_TAPED(!arg || arg->type != VAL_NUM, "random_hex", "a number of hex digits", make_str(""));
    int n = (arg && arg->type == VAL_NUM) ? (int)eigs_num_arg(arg, __func__) : 0;
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
 * number of bytes written; I/O failure raises EK_IO. Unlike write_text this is
 * binary-clean — NUL bytes are written verbatim, not treated as terminators —
 * so it can carry CBOR / arbitrary binary. Surfaced by tidelog's append-only
 * log (write_text is truncate-mode and NUL-truncating). */
Value* builtin_write_bytes(Value *arg) {
    STRICT_LIST_MAX(arg, 3, "write_bytes");
    ARG_GUARD(!arg || arg->type != VAL_LIST || arg->data.list.count < 2,
              "write_bytes", "[path, data] (optionally [path, data, append])", make_num(0));
    EIGS_VIEW(path_val_view);
    Value *path_val = list_get_view(arg, 0, &path_val_view);
    EIGS_VIEW(data_view);
    Value *data = list_get_view(arg, 1, &data_view);
    ARG_GUARD(!path_val || path_val->type != VAL_STR,
              "write_bytes", "a string path as its first argument", make_num(0));
    /* #1637: append is a flag -- a bool, or the older nonzero number. Any
     * other value raises rather than silently meaning "truncate". */
    int append = 0;
    if (arg->data.list.count >= 3) {
        EIGS_VIEW(fl_view);
        Value *fl = list_get_view(arg, 2, &fl_view);
        if (fl->type == VAL_BOOL) append = fl->data.boolean;
        else if (fl->type != VAL_NULL) append = (eigs_num_arg(fl, "write_bytes") != 0.0);
        if (g_has_error) return make_num(0);
    }

    int n = 0;
    if (data && data->type == VAL_LIST) {
        n = data->data.list.count;
    } else if (data && data->type == VAL_BUFFER) {
        n = data->data.buffer.count;
    } else {
        /* Reaching this else IS the condition: `data` is neither a list of
         * byte ints nor a buffer, the only two forms the header documents. */
        ARG_GUARD(1, "write_bytes",
                  "a list of byte values or a buffer as its second argument",
                  make_num(0));
    }

    unsigned char *out = xmalloc((size_t)(n > 0 ? n : 1));
    for (int i = 0; i < n; i++) {
        /* Coercion, not a guard: a non-number element silently became 0.0 and
         * was written as a NUL byte, so `write_bytes of [p, ["a","b"]]` wrote
         * two zero bytes and reported success. Same class as join/str_replace
         * — no stand-in return, so invisible to the classifier. The free()
         * matters: STRICT_REQUIRE returns, and `out` is already allocated. */
        if (data->type == VAL_LIST && list_elem_type(data, i) != VAL_NUM
            && (g_strict || list_elem_type(data, i) == VAL_BOOL)) {   /* #1637: a bool in every mode */
            free(out);
            rt_error(EK_TYPE, 0, "write_bytes: expected every element to be a number");
            return make_null();
        }
        double dv = data->type == VAL_LIST
                        ? eigs_slot_elem_num(list_slot(data, i), __func__)
                        : buffer_read_num(data, i);
        if (g_has_error) { free(out); return make_null(); }
        out[i] = finite_num_to_byte(dv);
    }
    Value *replayed = NULL;
    if (file_io_replay("write_bytes", &replayed)) { free(out); return replayed; }
    FILE *f = xfopen_write(path_val->data.str, append ? "ab" : "wb");
    /* The path was accepted by the guard above; a NULL FILE* is xfopen_write
     * failing, which raises EK_IO with the path and the OS reason, as the
     * header says (#1668). */
    if (!f) {
        int err = errno;
        free(out);
        return file_io_error("write_bytes", path_val->data.str, err);
    }
    size_t written = fwrite(out, 1, (size_t)n, f);
    int write_err = written == (size_t)n ? 0 : errno;
    int close_ok = (fclose(f) == 0);
    int close_err = errno;
    free(out);
    if (!close_ok || written != (size_t)n)
        return file_io_error("write_bytes", path_val->data.str,
                             write_err ? write_err : (close_err ? close_err : EIO));
    TRACE_NONDET_RECORD("write_bytes", make_num((double)written));
}

void register_host_builtins(Env *env) {
    env_set_local_owned(env, "mkdir", make_builtin(builtin_mkdir));
    env_set_local_owned(env, "ls", make_builtin(builtin_ls));
    env_set_local_owned(env, "getcwd", make_builtin(builtin_getcwd));
    env_set_local_owned(env, "exe_path", make_builtin(builtin_exe_path));
    env_set_local_owned(env, "mktemp", make_builtin(builtin_mktemp));
    env_set_local_owned(env, "stream_open", make_builtin(builtin_stream_open));
    env_set_local_owned(env, "stream_write", make_builtin(builtin_stream_write));
    env_set_local_owned(env, "stream_close", make_builtin(builtin_stream_close));
    env_set_local_owned(env, "regex_match", make_builtin(builtin_match));
    env_set_local_owned(env, "regex_find", make_builtin(builtin_match_all));
    env_set_local_owned(env, "regex_replace", make_builtin(builtin_regex_replace));
    env_set_local_owned(env, "load_file", make_builtin(builtin_load_file));
    env_set_local_owned(env, "file_exists", make_builtin(builtin_file_exists));
    env_set_local_owned(env, "is_dir", make_builtin(builtin_is_dir));
    env_set_local_owned(env, "is_file", make_builtin(builtin_is_file));
    env_set_local_owned(env, "rename", make_builtin(builtin_rename));
    env_set_local_owned(env, "remove_file", make_builtin(builtin_remove_file));
    env_set_local_owned(env, "file_sync", make_builtin(builtin_file_sync));
    env_set_local_owned(env, "dir_sync", make_builtin(builtin_dir_sync));
    env_set_local_owned(env, "read_bytes", make_builtin(builtin_read_bytes));
    env_set_local_owned(env, "read_bytes_buf", make_builtin(builtin_read_bytes_buf));
    env_set_local_owned(env, "read_text", make_builtin(builtin_read_text));
    env_set_local_owned(env, "read_line", make_builtin(builtin_read_line));
    env_set_local_owned(env, "write_text", make_builtin(builtin_write_text));
    env_set_local_owned(env, "write_bytes", make_builtin(builtin_write_bytes));
    env_set_local_owned(env, "exec_capture", make_builtin(builtin_exec_capture));
    env_set_local_owned(env, "random_hex", make_builtin(builtin_random_hex));
    env_set_local_owned(env, "tensor_save", make_builtin(builtin_tensor_save));
    env_set_local_owned(env, "tensor_load", make_builtin(builtin_tensor_load));
}

#endif /* EIGENSCRIPT_FREESTANDING */
