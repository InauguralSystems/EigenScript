#!/bin/bash
# tools/werror_cache_key.sh — the cache key for the [99i] compile-line audit (#1160)
#
# [99i] (tools/werror_switch_check.sh) is the single most expensive thing the
# suite does: dry runs of every make target plus a scan of every tracked shell
# script, 10-15 min on the dev box and minutes on a runner. Measured on PR
# #1158 it ran inside TEN jobs, for a property that depends on the Makefile and
# the scripts — not on which extensions the binary was built with.
#
# So CI runs it ONCE per PR in its own job, and that job is cached on this key.
# A cache HIT means "this exact audit input already passed on this repo"; a
# MISS means the audit runs.
#
# WHAT THE KEY COVERS, and why each part is in it
#   Makefile              - the audit dry-runs its targets; every compile line
#                           it examines comes from here.
#   every tracked *.sh    - the enrollment scan reads all of them (the audit
#                           itself uses `git ls-files '*.sh'`), and
#                           SCRIPT_AUDITS/SCRIPT_ENROLL_PINS live in one of
#                           them (tools/werror_switch_check.sh), so the gate's
#                           own source is covered without a special case.
#   the NAMES of tracked  - the Makefile compiles `$(wildcard src/*.c)`-shaped
#   files under src/        lists, so ADDING a source file changes the compile
#   tests/ tools/ web/      lines even though no covered file's CONTENT moved.
#   fuzz/                   Names only: a .c edit cannot change a compile LINE.
#
# What it deliberately does NOT cover: the contents of .c/.h files, docs, and
# anything outside those directories. Those cannot change a compile invocation,
# and putting them in the key would miss the cache on every documentation PR —
# which is exactly the contributor wait this issue exists to remove.
#
# THAT EXCLUSION IS ONLY SOUND BECAUSE THE GATE IS SPLIT (#1160 round 2).
# tools/werror_switch_check.sh also RUNS the two LSP index generators, and
# gen_lsp_builtin_index.sh reads reserved observer words out of src/lexer.c.
# A blind critic planted `return TOK_REPORT;` -> `return (TOK_REPORT);` there:
# the audit FAILED ("could not regenerate builtin LSP index") while this key
# was byte-identical. A cache hit would have skipped a now-different audit.
# So CI runs the generator half as `--headers-only`, UNCACHED, on every run
# (0.5 s measured), and caches only `--no-headers`, whose inputs really are
# the Makefile and the tracked scripts. `--selftest` gates that split against
# .github/workflows/ci.yml so the two homes cannot drift apart.
#
# Usage:
#   tools/werror_cache_key.sh            # print the sha256 key
#   tools/werror_cache_key.sh --inputs   # print the input list (reviewable)
#   tools/werror_cache_key.sh --explain  # key + input counts
#   tools/werror_cache_key.sh --selftest # planted-invalidation controls
#   [--root DIR]                         # operate on another checkout

set -u

KEY_VERSION="werror-audit-v1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="key"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --inputs|--explain|--selftest|--key) MODE="${1#--}"; shift ;;
        *) echo "werror_cache_key: unknown argument '$1'" >&2; exit 1 ;;
    esac
done

die() { echo "werror_cache_key: ERROR: $*" >&2; exit 1; }

# Resolve the hasher ONCE, up front, and fail here rather than inside a
# pipeline: a missing tool reported through `2>/dev/null` renders an
# unrunnable instrument as "no change", which is the worst reading a cache
# key can produce (mechanical-gates §7).
if command -v sha256sum >/dev/null 2>&1; then HASHER="sha256sum"
elif command -v shasum >/dev/null 2>&1; then HASHER="shasum -a 256"
else die "no sha256sum and no shasum on PATH"; fi

hash_stdin() { $HASHER | cut -d' ' -f1; }
hash_file()  { $HASHER < "$1" | cut -d' ' -f1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs_werror_key.XXXXXX") || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

# Tracked-file enumeration. `git ls-files` is authoritative inside a work tree;
# an EMPTY answer inside one is an instrument failure, not an empty repo, and
# must never be silently swapped for a `find` population (the same trap
# tools/werror_switch_check.sh documents at its own enrollment scan).
collect_inputs() {
    ( cd "$ROOT" && git ls-files '*.sh' 2>/dev/null ) | sort -u > "$WORK/sh"
    [ -s "$WORK/sh" ] || die "'git ls-files *.sh' listed nothing in $ROOT"
    {
        echo "Makefile"
        cat "$WORK/sh"
    } | sort -u > "$WORK/content"
    ( cd "$ROOT" && git ls-files src tests tools web fuzz 2>/dev/null ) | sort -u > "$WORK/names"
    [ -s "$WORK/names" ] || die "'git ls-files src tests tools web fuzz' listed nothing in $ROOT"

    CONTENT_COUNT=$(grep -c . "$WORK/content")
    NAME_COUNT=$(grep -c . "$WORK/names")
    # A floor, not an emptiness test: a population that shrinks to 3 files
    # hashes fine and silently caches an audit over a tree it never saw.
    [ "$CONTENT_COUNT" -ge 50 ] || die "content input population collapsed ($CONTENT_COUNT < floor 50)"
    [ "$NAME_COUNT" -ge 100 ] || die "name input population collapsed ($NAME_COUNT < floor 100)"
}

build_manifest() {
    : > "$WORK/manifest"
    echo "$KEY_VERSION" >> "$WORK/manifest"
    cat "$WORK/names" >> "$WORK/manifest"
    local f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        # Hash each covered file's CONTENT with its path, so a rename that
        # preserves bytes still moves the key.
        if [ -f "$ROOT/$f" ]; then
            printf '%s %s\n' "$f" "$(hash_file "$ROOT/$f")" >> "$WORK/manifest"
        else
            printf '%s MISSING\n' "$f" >> "$WORK/manifest"
        fi
    done < "$WORK/content"
}

compute_key() {
    collect_inputs
    build_manifest
    KEY=$(hash_stdin < "$WORK/manifest")
    [ -n "$KEY" ] || die "hasher produced no key"
}

selftest() {
    local pass=0 fail=0 dir k1 k2
    ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
    bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

    echo "werror_cache_key selftest (every fault is planted in a throwaway repo)"
    dir=$(mktemp -d "${TMPDIR:-/tmp}/eigs_werror_key_st.XXXXXX")
    (
        cd "$dir" || exit 1
        git init -q . >/dev/null 2>&1
        git config user.email t@t; git config user.name t
        mkdir -p src tests tools web fuzz
        printf 'all:\n\t@true src/a.c\n' > Makefile
        i=0
        while [ "$i" -lt 60 ]; do printf '#!/bin/sh\necho %s\n' "$i" > "tools/s$i.sh"; i=$((i + 1)); done
        i=0
        while [ "$i" -lt 120 ]; do printf 'int x%s;\n' "$i" > "src/f$i.c"; i=$((i + 1)); done
        printf 'docs\n' > README.md
        git add -A >/dev/null 2>&1
    )
    if [ ! -f "$dir/Makefile" ]; then
        echo "  FAIL: could not build the throwaway repo"
        echo "werror_cache_key selftest: checks=1 failures=1"
        rm -rf "$dir"
        return 1
    fi

    k1=$("$0" --root "$dir")
    if [ -z "$k1" ]; then
        echo "  FAIL: baseline key was empty"
        echo "werror_cache_key selftest: checks=1 failures=1"
        rm -rf "$dir"
        return 1
    fi
    ok "baseline key computed ($k1)"

    k2=$("$0" --root "$dir")
    if [ "$k1" = "$k2" ]; then ok "control: the key is stable across two runs of an unchanged tree"
    else bad "control: the key changed with no edit ($k1 -> $k2)"; fi

    # THE planted invalidation control: a one-line Makefile edit must MISS.
    # (The fixture recipe deliberately names NO compiler: tools/werror_switch_check.sh
    #  scans every tracked *.sh for compile invocations, and a fixture string that
    #  looks like one would enroll this file as a compile-bearing script.)
    printf 'all:\n\t@true src/a.c\n\t@echo planted\n' > "$dir/Makefile"
    k2=$("$0" --root "$dir")
    if [ "$k1" != "$k2" ]; then ok "planted: a one-line Makefile edit MISSES the cache"
    else bad "planted: a one-line Makefile edit still HIT the cache — the audit would be skipped over changed compile lines"; fi
    printf 'all:\n\t@true src/a.c\n' > "$dir/Makefile"

    # Second half of the control (a control with only the red half is
    # satisfied by a key that always changes): an edit OUTSIDE the covered
    # population must HIT.
    printf 'docs, edited\n' > "$dir/README.md"
    k2=$("$0" --root "$dir")
    if [ "$k1" = "$k2" ]; then ok "control: a docs-only edit still HITS the cache"
    else bad "control: a docs-only edit missed the cache — every docs PR would pay for the audit"; fi

    # A new source FILE changes the compile lines even though no covered
    # file's content moved.
    printf 'int y;\n' > "$dir/src/new.c"
    ( cd "$dir" && git add -A >/dev/null 2>&1 )
    k2=$("$0" --root "$dir")
    if [ "$k1" != "$k2" ]; then ok "planted: a new tracked src/*.c file MISSES the cache"
    else bad "planted: a new tracked src/*.c file still HIT the cache"; fi
    ( cd "$dir" && rm -f src/new.c && git add -A >/dev/null 2>&1 )

    # An edited audited script must MISS.
    printf '#!/bin/sh\necho planted\n' > "$dir/tools/s3.sh"
    k2=$("$0" --root "$dir")
    if [ "$k1" != "$k2" ]; then ok "planted: an edited tracked *.sh MISSES the cache"
    else bad "planted: an edited tracked *.sh still HIT the cache"; fi

    rm -rf "$dir"

    # THE SPLIT, gated. The key's soundness rests on CI caching only the half
    # whose inputs this key hashes. That is a fact about two files, so it gets
    # a check that reads BOTH homes rather than a comment (mechanical-gates
    # §26): the audit script must offer both halves, and ci.yml must use them.
    local ci="$ROOT/.github/workflows/ci.yml"
    local wsc="$ROOT/tools/werror_switch_check.sh"
    if grep -q -- '--headers-only' "$wsc" && grep -q -- '--no-headers' "$wsc"; then
        ok "the audit script offers both halves (--headers-only / --no-headers)"
    else
        bad "tools/werror_switch_check.sh no longer offers both halves — the cache key's exclusion of .c content is unsound without the split"
    fi
    if [ -f "$ci" ]; then
        if grep -q 'werror_switch_check.sh --headers-only' "$ci" \
           && grep -q 'werror_switch_check.sh --no-headers' "$ci"; then
            ok "ci.yml runs the generator half uncached and caches only the dry-run half"
        else
            bad "ci.yml does not use both halves — either the generator probes are being cached (unsound) or they stopped running"
        fi
        if grep -qE 'werror_switch_check\.sh[[:space:]]*$' "$ci"; then
            bad "ci.yml still runs the UNSPLIT audit somewhere — that path caches a verdict that depends on .c content"
        else
            ok "ci.yml runs no unsplit invocation of the audit"
        fi
    else
        bad "ci.yml not found; the split cannot be verified"
    fi

    echo "werror_cache_key selftest: checks=$((pass + fail)) failures=$fail"
    [ "$fail" -eq 0 ]
}

case "$MODE" in
    key)
        compute_key
        echo "$KEY"
        ;;
    inputs)
        collect_inputs
        echo "# content-hashed ($CONTENT_COUNT):"
        cat "$WORK/content"
        echo "# name-only ($NAME_COUNT):"
        cat "$WORK/names"
        ;;
    explain)
        compute_key
        echo "key=$KEY"
        echo "version=$KEY_VERSION"
        echo "content-hashed inputs: $CONTENT_COUNT (floor 50)"
        echo "name-only inputs: $NAME_COUNT (floor 100)"
        ;;
    selftest)
        selftest
        ;;
esac
