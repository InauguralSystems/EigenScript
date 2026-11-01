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
echo "PLAN: 9"
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
    "OK hosted RNG: no libc rand/srand calls in 2 tracked runtime source file(s) outside src/freestanding"

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
    "FAIL: hosted runtime calls libc rand/srand outside the taped random stream" \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1
# 5. ... and the same clean tree under the same condition is still green.
case_ "foreign-owned clean checkout still passes" "$WORK/clean" 0 \
    "OK hosted RNG: no libc rand/srand calls in 2 tracked runtime source file(s)" \
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1

# 6. Any other git grep error is FAIL, not an empty result. A PATH shim makes
#    `git grep` die with git's own exit code for a fatal error.
mkdir -p "$WORK/shim"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = grep ] && { echo "fatal: planted grep failure" >&2; exit 128; }; done\nexec "%s" "$@"\n' \
    "$REAL_GIT" > "$WORK/shim/git"
chmod +x "$WORK/shim/git"
case_ "git grep error (rc 128) is red, not OK" "$WORK/clean" 1 \
    "FAIL: hosted RNG check could not search the runtime sources (git grep rc=128)" \
    PATH="$WORK/shim:$PATH"

# 7. A git warning on stderr is not an examined file: the count stays exact.
mkdir -p "$WORK/warnshim"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = ls-files ] && { echo "warning: planted ls-files warning" >&2; break; }; done\nexec "%s" "$@"\n' \
    "$REAL_GIT" > "$WORK/warnshim/git"
chmod +x "$WORK/warnshim/git"
case_ "git ls-files stderr warning is not counted as a file" "$WORK/clean" 0 \
    "OK hosted RNG: no libc rand/srand calls in 2 tracked runtime source file(s)" \
    PATH="$WORK/warnshim:$PATH"

# 8. An empty population is not a pass.
mkdir -p "$WORK/empty"
make_repo "$WORK/empty"
run_env "$REAL_GIT" -C "$WORK/empty" rm -q src/a.c extensions/e.c &&
    run_env "$REAL_GIT" -C "$WORK/empty" -c user.name=selftest -c user.email=selftest@example.invalid \
        commit -qm empty || exit 2
case_ "no tracked runtime sources is red (vacuous)" "$WORK/empty" 1 \
    "FAIL: hosted RNG check examined no runtime sources"

echo "freestanding RNG selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ] && [ "$pass" -eq 9 ]
