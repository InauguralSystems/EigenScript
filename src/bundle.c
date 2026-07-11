/* ================================================================
 * EigenScript --bundle — single-file distribution (#413)
 * ================================================================
 * `eigenscript --bundle app.eigs out [--with-tape tape]` copies the
 * running runtime binary and appends an archive: the script, the
 * adjacent eigs_modules/ tree (if any), the stdlib lib/ modules, and
 * optionally a trace tape. The result is one executable that runs on
 * a machine with no EigenScript checkout — and with a tape attached,
 * `out --replay` is a self-replaying reproducer (an executable bug
 * report that replays deterministically).
 *
 * Startup self-exec detection: main() calls eigs_bundle_selfexec()
 * first; a trailer magic at EOF marks a bundle. Entries extract to a
 * mkdtemp directory and argv is rewritten to run the extracted script
 * — every existing resolution rule then just works: the script's dir
 * is the resolve base, so `import name` finds tmpdir/eigs_modules/...
 * and `import json` finds tmpdir/lib/json.eigs. No VFS, no resolver
 * changes. The tempdir is removed at exit (best-effort).
 *
 * Archive format (fmt 1), appended after the runtime image:
 *   entry*: [u32 path_len][path bytes, no NUL][u64 size][bytes]
 *   trailer (24 bytes at EOF):
 *     [u64 archive_off][u32 entry_count][u32 fmt=1][8-byte magic]
 * The FIRST entry is always the script. Integers are little-endian
 * (x86-64 only today, same assumption the JIT already makes).
 *
 * The tape entry (".eigs_bundle.tape") pins the #411 contract by
 * construction: the tape names its recording version, and the bundle
 * carries the exact binary that recorded it — the pair can't drift.
 *
 * CLI-only (Makefile CLI_ONLY set): excluded from embed/LSP/
 * freestanding builds like main.c/repl.c/step.c.
 * ================================================================ */

#include "eigenscript.h"

#include <dirent.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <unistd.h>

#define BUNDLE_MAGIC   "EIGSBNDL"
#define BUNDLE_FMT     1u
#define BUNDLE_TAPE    ".eigs_bundle.tape"
#define TRAILER_SIZE   24

/* ---- own-executable path (Linux readlink; argv0 fallback for macOS,
 * which is how the suite invokes bundles anyway: an explicit path) ---- */
static int own_exe_path(const char *argv0, char *out, size_t cap) {
    ssize_t n = readlink("/proc/self/exe", out, cap - 1);
    if (n > 0 && n < (ssize_t)cap) { out[n] = '\0'; return 1; }
    if (argv0 && strchr(argv0, '/') && realpath(argv0, out)) return 1;
    return 0;
}

/* ---- trailer probe: returns 1 and fills off/count if `f` is a bundle */
static int read_trailer(FILE *f, uint64_t *off, uint32_t *count) {
    unsigned char t[TRAILER_SIZE];
    if (fseek(f, -(long)TRAILER_SIZE, SEEK_END) != 0) return 0;
    if (fread(t, 1, TRAILER_SIZE, f) != TRAILER_SIZE) return 0;
    if (memcmp(t + 16, BUNDLE_MAGIC, 8) != 0) return 0;
    uint32_t fmt;
    memcpy(off,   t,      8);
    memcpy(count, t + 8,  4);
    memcpy(&fmt,  t + 12, 4);
    if (fmt != BUNDLE_FMT) {
        fprintf(stderr, "bundle: archive format v%u, this binary reads v%u — "
                "re-bundle on this version\n", fmt, BUNDLE_FMT);
        return 0;
    }
    return 1;
}

/* ---- writer ----------------------------------------------------- */

static int copy_stream(FILE *src, FILE *dst, uint64_t nbytes) {
    char buf[65536];
    while (nbytes > 0) {
        size_t want = nbytes < sizeof(buf) ? (size_t)nbytes : sizeof(buf);
        size_t got = fread(buf, 1, want, src);
        if (got == 0) return 0;
        if (fwrite(buf, 1, got, dst) != got) return 0;
        nbytes -= got;
    }
    return 1;
}

static int emit_entry_header(FILE *out, const char *path, uint64_t size) {
    uint32_t plen = (uint32_t)strlen(path);
    if (fwrite(&plen, 4, 1, out) != 1) return 0;
    if (fwrite(path, 1, plen, out) != plen) return 0;
    if (fwrite(&size, 8, 1, out) != 1) return 0;
    return 1;
}

/* Append one file under archive path `apath`. Returns 1 on success. */
static int emit_file(FILE *out, const char *fspath, const char *apath,
                     uint32_t *count) {
    FILE *f = fopen(fspath, "rb");
    if (!f) return 0;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return 0; }
    int ok = emit_entry_header(out, apath, (uint64_t)sz) &&
             copy_stream(f, out, (uint64_t)sz);
    fclose(f);
    if (ok) (*count)++;
    return ok;
}

/* Recursively append every regular file under `fsdir` as `adir/...`.
 * Missing dir is not an error (a script may have no eigs_modules). */
static int emit_tree(FILE *out, const char *fsdir, const char *adir,
                     uint32_t *count, int depth) {
    if (depth > 16) return 1;
    DIR *d = opendir(fsdir);
    if (!d) return 1;
    struct dirent *e;
    int ok = 1;
    while (ok && (e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        char fs[4096], ar[4096];
        snprintf(fs, sizeof(fs), "%s/%s", fsdir, e->d_name);
        snprintf(ar, sizeof(ar), "%s/%s", adir, e->d_name);
        struct stat st;
        if (stat(fs, &st) != 0) continue;
        if (S_ISDIR(st.st_mode))
            ok = emit_tree(out, fs, ar, count, depth + 1);
        else if (S_ISREG(st.st_mode))
            ok = emit_file(out, fs, ar, count);
    }
    closedir(d);
    return ok;
}

/* Stdlib source dir: repo layout (<exe>/../lib) or install layout
 * (<exe>/../lib/eigenscript). Archive paths are lib/<name>.eigs either
 * way — exactly what `import` requests against the script dir. Derived
 * from the exe path directly: --bundle runs before any EigsState is
 * attached, so the g_exe_dir state macro is off-limits here. */
static const char *stdlib_dir(const char *self, char *buf, size_t cap) {
    char dir[4096];
    snprintf(dir, sizeof(dir), "%s", self);
    char *slash = strrchr(dir, '/');
    if (!slash) return NULL;
    *slash = '\0';
    char probe[4600];
    snprintf(buf, cap, "%.4000s/../lib/eigenscript", dir);
    snprintf(probe, sizeof(probe), "%.4500s/string.eigs", buf);
    if (access(probe, F_OK) == 0) return buf;
    snprintf(buf, cap, "%.4000s/../lib", dir);
    snprintf(probe, sizeof(probe), "%.4500s/string.eigs", buf);
    if (access(probe, F_OK) == 0) return buf;
    return NULL;
}

int eigs_bundle_create(const char *argv0, const char *script,
                       const char *outpath, const char *tape) {
    char self[4096];
    if (!own_exe_path(argv0, self, sizeof(self))) {
        fprintf(stderr, "bundle: cannot locate own executable\n");
        return 1;
    }
    FILE *in = fopen(self, "rb");
    if (!in) { fprintf(stderr, "bundle: cannot open '%s'\n", self); return 1; }

    /* Re-bundling from a bundle: copy only the runtime image, not the
     * old archive. */
    uint64_t img_end; uint32_t old_count;
    if (read_trailer(in, &img_end, &old_count)) {
        /* img_end = old archive start = end of the runtime image */
    } else {
        fseek(in, 0, SEEK_END);
        img_end = (uint64_t)ftell(in);
    }
    fseek(in, 0, SEEK_SET);

    /* explicit mode — never world-writable regardless of umask; the
     * final chmod below still stamps the executable bit set. */
    int outfd = open(outpath, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    FILE *out = outfd >= 0 ? fdopen(outfd, "wb") : NULL;
    if (!out) {
        if (outfd >= 0) close(outfd);
        fprintf(stderr, "bundle: cannot write '%s'\n", outpath);
        fclose(in);
        return 1;
    }

    int ok = copy_stream(in, out, img_end);
    fclose(in);
    uint64_t archive_off = img_end;
    uint32_t count = 0;

    /* 1. the script — ALWAYS the first entry, archived by basename */
    const char *base = strrchr(script, '/');
    base = base ? base + 1 : script;
    ok = ok && emit_file(out, script, base, &count);
    if (!ok) fprintf(stderr, "bundle: cannot read script '%s'\n", script);

    /* 2. the adjacent eigs_modules/ tree (whole tree: dependency
     * analysis can't see dynamic imports, and the superset is cheap) */
    if (ok) {
        char sdir[4096], mods[4600];
        snprintf(sdir, sizeof(sdir), "%s", script);
        char *slash = strrchr(sdir, '/');
        if (slash) *slash = '\0'; else snprintf(sdir, sizeof(sdir), ".");
        snprintf(mods, sizeof(mods), "%.4000s/eigs_modules", sdir);
        ok = emit_tree(out, mods, "eigs_modules", &count, 0);
    }

    /* 3. the stdlib, so `import json` works on a bare machine */
    if (ok) {
        char libbuf[4096];
        const char *lib = stdlib_dir(self, libbuf, sizeof(libbuf));
        if (lib) ok = emit_tree(out, lib, "lib", &count, 0);
        else fprintf(stderr, "bundle: warning: stdlib dir not found — "
                     "bundle will lack lib/ imports\n");
    }

    /* 4. optional tape */
    if (ok && tape) {
        ok = emit_file(out, tape, BUNDLE_TAPE, &count);
        if (!ok) fprintf(stderr, "bundle: cannot read tape '%s'\n", tape);
    }

    /* trailer */
    if (ok) {
        uint32_t fmt = BUNDLE_FMT;
        ok = fwrite(&archive_off, 8, 1, out) == 1 &&
             fwrite(&count, 4, 1, out) == 1 &&
             fwrite(&fmt, 4, 1, out) == 1 &&
             fwrite(BUNDLE_MAGIC, 1, 8, out) == 8;
    }
    /* fchmod on the still-open fd: the exec bit lands on the file we
     * wrote, not whatever a path race could swap in (cpp/toctou). */
    if (ok && fchmod(fileno(out), 0755) != 0) ok = 0;
    if (fclose(out) != 0) ok = 0;
    if (!ok) {
        fprintf(stderr, "bundle: write failed\n");
        unlink(outpath);
        return 1;
    }
    printf("bundled %s + %u file(s)%s -> %s\n", base, count - 1,
           tape ? " + tape" : "", outpath);
    return 0;
}

/* ---- self-exec reader ------------------------------------------- */

static char g_bundle_tmpdir[4096];

/* fd-anchored recursive delete (openat/fstatat/unlinkat): each step is
 * relative to an open directory fd, so a mid-walk path swap can't
 * redirect the traversal (cpp/toctou). O_NOFOLLOW on the descent — we
 * created every entry; a symlink here is someone else's. */
static void rm_tree_fd(int dirfd, int depth) {
    if (depth > 16) { close(dirfd); return; }
    DIR *d = fdopendir(dirfd);
    if (!d) { close(dirfd); return; }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        struct stat st;
        if (fstatat(dirfd, e->d_name, &st, AT_SYMLINK_NOFOLLOW) != 0)
            continue;
        if (S_ISDIR(st.st_mode)) {
            int sub = openat(dirfd, e->d_name,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (sub >= 0) rm_tree_fd(sub, depth + 1);   /* closes sub */
            unlinkat(dirfd, e->d_name, AT_REMOVEDIR);
        } else {
            unlinkat(dirfd, e->d_name, 0);
        }
    }
    closedir(d);   /* also closes dirfd */
}

static void bundle_cleanup(void) {
    if (g_bundle_tmpdir[0]) {
        int fd = open(g_bundle_tmpdir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (fd >= 0) rm_tree_fd(fd, 0);
        rmdir(g_bundle_tmpdir);
    }
}

/* mkdir -p for the dirname of `path` (relative to tmpdir extraction). */
static void mkdirs_for(char *path) {
    for (char *p = path + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(path, 0755);
            *p = '/';
        }
    }
}

/* Detect an appended archive on our own binary; extract and rewrite
 * argv so the ordinary script path runs the extracted entry script.
 * Returns 1 in bundle mode (argc/argv rewritten in place), 0 otherwise.
 * In bundle mode ONLY `--replay` (as the first arg) is intercepted —
 * every other argument belongs to the bundled script. */
int eigs_bundle_selfexec(int *argc, char ***argv) {
    char self[4096];
    if (!own_exe_path((*argv)[0], self, sizeof(self))) return 0;
    FILE *f = fopen(self, "rb");
    if (!f) return 0;

    uint64_t off; uint32_t count;
    if (!read_trailer(f, &off, &count)) { fclose(f); return 0; }

    const char *tmp = getenv("TMPDIR");
    snprintf(g_bundle_tmpdir, sizeof(g_bundle_tmpdir),
             "%s/eigsbndl.XXXXXX", (tmp && tmp[0]) ? tmp : "/tmp");
    if (!mkdtemp(g_bundle_tmpdir)) {
        fprintf(stderr, "bundle: mkdtemp failed\n");
        fclose(f);
        exit(1);
    }
    atexit(bundle_cleanup);

    static char script_path[4600];
    char tape_path[4600];
    tape_path[0] = '\0';

    fseek(f, (long)off, SEEK_SET);
    for (uint32_t i = 0; i < count; i++) {
        uint32_t plen;
        uint64_t size;
        char rel[2048];
        if (fread(&plen, 4, 1, f) != 1 || plen == 0 || plen >= sizeof(rel) ||
            fread(rel, 1, plen, f) != plen) goto torn;
        rel[plen] = '\0';
        if (fread(&size, 8, 1, f) != 1) goto torn;
        /* Refuse traversal: entries are relative, no '..' segments. */
        if (rel[0] == '/' || strstr(rel, "..")) goto torn;

        char dst[4600];
        snprintf(dst, sizeof(dst), "%.2500s/%.2000s", g_bundle_tmpdir, rel);
        mkdirs_for(dst);
        int ofd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        FILE *o = ofd >= 0 ? fdopen(ofd, "wb") : NULL;
        if (ofd >= 0 && !o) close(ofd);
        if (!o || !copy_stream(f, o, size)) {
            if (o) fclose(o);
            goto torn;
        }
        fclose(o);
        if (i == 0) snprintf(script_path, sizeof(script_path), "%s", dst);
        if (strcmp(rel, BUNDLE_TAPE) == 0)
            snprintf(tape_path, sizeof(tape_path), "%s", dst);
    }
    fclose(f);

    /* `out --replay ...`: serve the attached tape */
    int shift = 0;
    if (*argc >= 2 && strcmp((*argv)[1], "--replay") == 0) {
        if (!tape_path[0]) {
            fprintf(stderr, "bundle: --replay but no tape attached\n");
            exit(3);
        }
        setenv("EIGS_REPLAY", tape_path, 1);
        shift = 1;
    }

    /* argv becomes: [argv0, extracted-script, script args...] */
    static char *new_argv[256];
    int n = 0;
    new_argv[n++] = (*argv)[0];
    new_argv[n++] = script_path;
    for (int i = 1 + shift; i < *argc && n < 255; i++)
        new_argv[n++] = (*argv)[i];
    new_argv[n] = NULL;
    *argc = n;
    *argv = new_argv;
    return 1;

torn:
    fprintf(stderr, "bundle: torn or malformed archive — refusing to run\n");
    fclose(f);
    exit(3);
}
