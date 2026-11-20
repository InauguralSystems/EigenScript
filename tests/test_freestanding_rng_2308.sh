#!/usr/bin/env bash
# Hosted-RNG half of the freestanding symbol gate must fail closed (#2308;
# found by the hq#58 CI inventory as finding ES-CIB-1).
#
# tools/freestanding_check.sh greps the runtime sources for libc rand/srand
# calls; rand/srand are in tools/freestanding_allowlist.txt, so stage 1 cannot
# catch them and this grep is the only check. CI runs it in a container as a
# different user from the one that checked the tree out, so git refused the
# repository ("detected dubious ownership", rc 128). `git grep ... || true`
# turned the refusal into an empty result, and the gate printed "OK hosted RNG"
# on every freestanding run from 2026-10-28 without searching anything.
#
# Every case drives the REAL gate (`tools/freestanding_check.sh --rng-only`,
# which runs exactly the code CI runs and stops before the compile rows) in a
# scratch git repository. The foreign-owner cases use git's own
# GIT_TEST_ASSUME_DIFFERENT_OWNER switch, so they need no root or chown; a
# liveness probe first proves that switch makes a plain `git grep` fail the
# way CI's did, so the cases cannot pass vacuously on a git that ignores it.
#
# Usage: tests/test_freestanding_rng_2308.sh --selftest
set -u
[ "${1:-}" = "--selftest" ] || { echo "usage: $0 --selftest" >&2; exit 2; }
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_fs_rng.XXXXXX") || exit 2
trap 'rm -rf "$WORK"' EXIT
REAL_GIT=$(command -v git) || { echo "  FAIL: git is required"; exit 1; }
<<<<<<< HEAD
echo "PLAN: 12"
=======
echo "PLAN: 37"
>>>>>>> origin/main
pass=0; fail=0

# A fresh HOME with no global or system config: a developer's own
# `safe.directory = *` must not make the foreign-owner cases pass.
mkdir -p "$WORK/home"
run_env() { env -u XDG_CONFIG_HOME -u GIT_DIR -u GIT_WORK_TREE HOME="$WORK/home" GIT_CONFIG_NOSYSTEM=1 "$@"; }

make_repo() {   # make_repo <dir>: a clean tree the gate can examine
    local d=$1
    mkdir -p "$d/tools" "$d/src/freestanding" "$d/extensions"
    cp "$ROOT/tools/freestanding_check.sh" "$ROOT/tools/read_werror_flags.sh" \
        "$ROOT/tools/werror_flags.txt" "$d/tools/" || exit 2
    printf 'int clean_a(void) { return 4; }\n' > "$d/src/a.c"
    printf 'int clean_e(void) { return 5; }\n' > "$d/extensions/e.c"
    # The freestanding libc implements rand(); the exclusion must keep it legal.
    printf 'int rand(void) { return 7; }\n' > "$d/src/freestanding/mini_libc.c"
    cat > "$d/Makefile" <<'EOF'
SOURCES := src/a.c
CLI_ONLY :=
print-%:
	@echo "$($*)"
EOF
    run_env "$REAL_GIT" -C "$d" init -q &&
        run_env "$REAL_GIT" -C "$d" add . &&
        run_env "$REAL_GIT" -C "$d" -c user.name=selftest -c user.email=selftest@example.invalid \
            commit -qm control || exit 2
}

commit_plant() {   # commit_plant <dir> <path> <body>
    printf '%s\n' "$3" > "$1/$2"
    run_env "$REAL_GIT" -C "$1" add "$2" &&
        run_env "$REAL_GIT" -C "$1" -c user.name=selftest -c user.email=selftest@example.invalid \
            commit -qm plant || exit 2
}

case_() {   # case_ <name> <dir> <want-rc> <want-substring> [env assignments...]
    local name=$1 dir=$2 want_rc=$3 want=$4 out rc
    shift 4
    out=$(cd "$dir" && run_env "$@" bash tools/freestanding_check.sh --rng-only 2>&1); rc=$?
    case "$out" in
        *"$want"*) if [ "$rc" -eq "$want_rc" ]; then
                       echo "  PASS: $name"; pass=$((pass + 1)); return
                   fi ;;
    esac
    echo "  FAIL: $name (rc=$rc, want rc=$want_rc and '$want')"
    printf '%s\n' "$out" | sed 's/^/      /'
    fail=$((fail + 1))
}

# 1. Clean control, same owner: green, and it says how much it examined.
make_repo "$WORK/clean"
case_ "clean control passes and counts its population" "$WORK/clean" 0 \
    "OK hosted RNG objects: no libc rand/srand imports in 1 hosted object(s)"

# Header, macro-alias and function-pointer plants each have an immediately
# preceding clean control. The word search must catch all three.
for kind in header macro pointer; do
    make_repo "$WORK/$kind-control"
    case_ "$kind plant clean control passes" "$WORK/$kind-control" 0 \
        "OK hosted RNG objects: no libc rand/srand imports in 1 hosted object(s)"
    make_repo "$WORK/$kind"
    case "$kind" in
        header)
            printf '#include <stdlib.h>\nstatic inline int r(void) { return rand(); }\n' > "$WORK/$kind/src/rng.h"
            printf '#include "rng.h"\nint clean_a(void) { return r(); }\n' > "$WORK/$kind/src/a.c" ;;
        macro)
            printf '#include <stdlib.h>\n#define RNG rand\nint clean_a(void) { return RNG(); }\n' > "$WORK/$kind/src/a.c" ;;
        pointer)
            printf '#include <stdlib.h>\nint clean_a(void) { int (*p)(void) = rand; return p(); }\n' > "$WORK/$kind/src/a.c" ;;
    esac
    run_env "$REAL_GIT" -C "$WORK/$kind" add src &&
        run_env "$REAL_GIT" -C "$WORK/$kind" -c user.name=selftest \
            -c user.email=selftest@example.invalid commit -qm "$kind plant" || exit 2
    if [ "$kind" = header ]; then expected='src/rng.h:'; else expected='src/a.c:'; fi
    case_ "$kind plant is red at the word search" "$WORK/$kind" 1 "$expected"
done

# Blind-review regressions: all three issue plants in an extension source that
# is absent from SOURCES, an extension-guarded plant in a SOURCES file, and a
# CLI-only function pointer. Every plant has its own freshly made control.
extended_plant() { # extended_plant <case> <path> <body> <name>
    local tag=$1 path=$2 body=$3 name=$4
    make_repo "$WORK/$tag-control"
    case_ "$name clean control passes" "$WORK/$tag-control" 0 \
        "OK hosted RNG: the words rand and srand appear in none of the 2 tracked hosted C source/header file(s)"
    make_repo "$WORK/$tag"
    commit_plant "$WORK/$tag" "$path" "$body"
    case_ "$name is red and names its file and identifier" "$WORK/$tag" 1 "$path:"
}
extended_plant ext-http-header src/ext_http.c \
    '#include <stdlib.h>
static inline int planted(void) { return rand(); }' 'ext_http.c header-style call plant'
extended_plant ext-http-macro src/ext_http.c \
    '#include <stdlib.h>
#define RNG rand
int planted(void) { return RNG(); }' 'ext_http.c macro alias plant'
extended_plant ext-http-pointer src/ext_http.c \
    '#include <stdlib.h>
int planted(void) { int (*p)(void) = rand; return p(); }' 'ext_http.c function-pointer plant'
extended_plant guarded src/a.c \
    '#if EIGENSCRIPT_EXT_HTTP
#define RNG rand
int planted(void) { return RNG(); }
#endif' 'SOURCES extension-guarded plant'
extended_plant eigenlsp src/eigenlsp.c \
    '#include <stdlib.h>
int planted(void) { int (*p)(void) = rand; return p(); }' 'eigenlsp.c function-pointer plant'
# A lone quote mark on an earlier line (legal in the text of #error) must not
# put the scan into a literal that swallows the lines after it.
extended_plant lone-quote src/ext_net.c \
    '#if 0
#error this build can'"'"'t work
#endif
int planted(void) { int (*p)(void) = rand; return p(); }' 'function-pointer plant after a lone quote mark'
# A string that goes on over a line end, and then opens a comment that never
# closes on that line, must not hide the lines after it (a scan that kept
# state from line to line let these through).
extended_plant continued-string src/ext_net.c \
    'static const char *g = "src\
/*.c";
int planted(void) { int (*p)(void) = rand; return p(); }
void h(void) { srand(1); }' 'plants after a string continued over a line end'
# The word in a comment is refused too: the search does no lexing, and says so.
extended_plant comment-word src/ext_net.c \
    '/* this used to call rand */
int planted(void) { return 4; }' 'the word in a comment'
# Names that only contain the word pass.
make_repo "$WORK/contains"
commit_plant "$WORK/contains" src/b.c 'int my_rand(void) { return 4; }
int rand_state; int srand_x; int drand48_like;'
case_ "names that only contain the word stay green" "$WORK/contains" 0 \
    "OK hosted RNG: the words rand and srand appear in none of the 3 tracked hosted C source/header file(s)"
# The object check has its own witness: a name the preprocessor puts together
# holds the word nowhere in the text, and the built object imports it.
make_repo "$WORK/paste-control"
case_ "pasted-name plant clean control passes" "$WORK/paste-control" 0 \
    "OK hosted RNG objects: no libc rand/srand imports in 1 hosted object(s)"
make_repo "$WORK/paste"
printf '#include <stdlib.h>\n#define CAT(a, b) a##b\nint clean_a(void) { return CAT(ra, nd)(); }\n' > "$WORK/paste/src/a.c"
run_env "$REAL_GIT" -C "$WORK/paste" add src &&
    run_env "$REAL_GIT" -C "$WORK/paste" -c user.name=selftest \
        -c user.email=selftest@example.invalid commit -qm "paste plant" || exit 2
case_ "pasted-name plant passes the word search and is red at the object check" "$WORK/paste" 1 \
    "FAIL: hosted runtime objects import libc rand/srand outside the taped random stream"

# 2-3. Planted calls, same owner: red and named.
make_repo "$WORK/rand"
commit_plant "$WORK/rand" src/b.c 'int planted(void) { return rand(); }'
case_ "planted rand( in src/ is red and named" "$WORK/rand" 1 "src/b.c:1:int planted(void) { return rand(); }"
make_repo "$WORK/srand"
commit_plant "$WORK/srand" extensions/f.c 'void planted(void) { srand (1); }'
case_ "planted srand ( in extensions/ is red and named" "$WORK/srand" 1 "extensions/f.c:1:"

# Liveness: the foreign-owner switch must make plain git refuse this tree, as
# CI's container did. Otherwise cases 4-5 would test nothing.
probe=$(cd "$WORK/rand" && run_env GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$REAL_GIT" grep -n rand -- 'src/*.c' 2>&1); probe_rc=$?
case "$probe_rc:$probe" in
    128:*"dubious ownership"*)
        echo "  PASS: liveness: a foreign-owned checkout makes plain git grep refuse (rc 128)"; pass=$((pass + 1)) ;;
    *)  echo "  FAIL: liveness: GIT_TEST_ASSUME_DIFFERENT_OWNER did not reproduce the refusal (rc=$probe_rc)"
        printf '%s\n' "$probe" | sed 's/^/      /'; fail=$((fail + 1)) ;;
esac

# 4. The CI defect: foreign-owned checkout with a planted call. Before the fix
#    this printed "OK hosted RNG" and exited 0.
case_ "foreign-owned checkout with planted rand( is red, not OK" "$WORK/rand" 1 \
    "FAIL: the word rand or srand appears in a hosted runtime source or header" \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1
# 5. ... and the same clean tree under the same condition is still green.
case_ "foreign-owned clean checkout still passes" "$WORK/clean" 0 \
    "OK hosted RNG: the words rand and srand appear in none of the 2 tracked hosted C source/header file(s)" \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1

# 6. Any git population error is FAIL, not an empty result. A PATH shim makes
#    `git ls-files` die with git's own exit code for a fatal error.
mkdir -p "$WORK/shim"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = ls-files ] && { echo "fatal: planted ls-files failure" >&2; exit 128; }; done\nexec "%s" "$@"\n' \
    "$REAL_GIT" > "$WORK/shim/git"
chmod +x "$WORK/shim/git"
case_ "git ls-files error (rc 128) is red, not OK" "$WORK/clean" 1 \
    "FAIL: hosted RNG check examined no runtime sources (git ls-files rc=128)" \
    PATH="$WORK/shim:$PATH"
# ... and so is an error of the search itself: git grep exits 1 for "no match"
# and 128 for a fatal error, and only the first is a clean result.
mkdir -p "$WORK/grepshim"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && { echo "fatal: planted grep failure" >&2; exit 128; }; done\nexec "%s" "$@"\n' \
    "$REAL_GIT" > "$WORK/grepshim/git"
chmod +x "$WORK/grepshim/git"
case_ "git grep error (rc 128) is red, not OK" "$WORK/clean" 1 \
    "FAIL: hosted RNG check could not search the runtime sources (git grep rc=128)" \
    PATH="$WORK/grepshim:$PATH"
# A message of git grep on its error stream is a failure even when it exits
# with "no match": that is how it passes over a file it could not open.
mkdir -p "$WORK/grepwarn"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && { echo "error: planted grep complaint" >&2; break; }; done\nexec "%s" "$@"\n' \
    "$REAL_GIT" > "$WORK/grepwarn/git"
chmod +x "$WORK/grepwarn/git"
case_ "a complaint of git grep on its error stream is red, not OK" "$WORK/clean" 1 \
    "FAIL: hosted RNG check: git grep reported a problem" \
    PATH="$WORK/grepwarn:$PATH"
# A tracked file that is not in the working tree was not searched.
make_repo "$WORK/missing"
rm "$WORK/missing/src/a.c"
case_ "a tracked file missing from the working tree is red, not OK" "$WORK/missing" 1 \
    "FAIL: hosted RNG check cannot read the tracked file src/a.c"

# 7. A git warning on stderr is not an examined file: the count stays exact.
mkdir -p "$WORK/warnshim"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = ls-files ] && { echo "warning: planted ls-files warning" >&2; break; }; done\nexec "%s" "$@"\n' \
    "$REAL_GIT" > "$WORK/warnshim/git"
chmod +x "$WORK/warnshim/git"
case_ "git ls-files stderr warning is not counted as a file" "$WORK/clean" 0 \
    "OK hosted RNG: the words rand and srand appear in none of the 2 tracked hosted C source/header file(s)" \
    PATH="$WORK/warnshim:$PATH"

# 8. Every tracked path counted by the gate must still be readable.
make_repo "$WORK/missing"
unlink "$WORK/missing/extensions/e.c"
case_ "a tracked file outside Makefile SOURCES missing from the working tree is red" \
    "$WORK/missing" 1 "FAIL: hosted RNG check cannot read tracked runtime source(s):"

# 9-10. NUL-delimited discovery preserves names that Git would otherwise quote.
make_repo "$WORK/unicode-clean"
commit_plant "$WORK/unicode-clean" 'src/café.c' 'int cafe_clean(void) { return 6; }'
case_ "a clean tracked non-ASCII source name passes" "$WORK/unicode-clean" 0 \
    "OK hosted RNG: no libc rand/srand calls in 3 tracked runtime source file(s)"
make_repo "$WORK/unicode-rand"
commit_plant "$WORK/unicode-rand" 'src/café.c' 'int cafe_bad(void) { return rand(); }'
case_ "rand in a tracked non-ASCII source is red and named" "$WORK/unicode-rand" 1 \
    'src/café.c:1:int cafe_bad(void) { return rand(); }'

# 11. An empty population is not a pass.
mkdir -p "$WORK/empty"
make_repo "$WORK/empty"
run_env "$REAL_GIT" -C "$WORK/empty" rm -q src/a.c extensions/e.c &&
    run_env "$REAL_GIT" -C "$WORK/empty" -c user.name=selftest -c user.email=selftest@example.invalid \
        commit -qm empty || exit 2
case_ "no tracked runtime sources is red (vacuous)" "$WORK/empty" 1 \
    "FAIL: hosted RNG check examined no runtime sources"

echo "freestanding RNG selftest: $pass passed, $fail failed"
<<<<<<< HEAD
[ "$fail" -eq 0 ] && [ "$pass" -eq 12 ]
=======
[ "$fail" -eq 0 ] && [ "$pass" -eq 37 ]
>>>>>>> origin/main
