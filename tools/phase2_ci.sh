#!/usr/bin/env bash
# tools/phase2_ci.sh [--through Rk] [--baseline BIN] <tag-binary> <main-binary> <branch-binary>
# #1758 Phase 2's CI lane (.github/workflows/phase2.yml): the MAP rows that have
# landed (tools/phase2_check.sh, design 9.2) and the stdlib int differential
# (tools/phase2_lib_diff.sh, design 9.5). The three positional binaries are
# the v0.46.0 anchor (make observer-anchor), origin/main and this commit;
# a mechanical round's baseline is passed separately.
#
# By default --through is DERIVED by phase2_check.py's shared helper. A round needs
# all its MAP row files; each R1.6b..z sub-round additionally needs its declaration
# in tests/phase2/builtins_landed.txt. Rowless R1.6 rounds can therefore land
# explicitly. R1.6a migrates none, so its declaration is optional. A partial round stops the prefix even when later files exist.
# The table and C reader test always run, including R1.6a's empty declaration.
# Explicit --through/--baseline are forwarded to the existing checker so a
# rowless mechanical round can run against its exact preceding baseline.
# Matched profile binaries use TAG_BIN_SERVER/ZLIB/DB and
# BRANCH_BIN_SERVER/ZLIB/DB; DATABASE_URL supplies PostgreSQL.
#
# Each tool must exit 0 AND print its own PASS line, whole: a tool that died
# after its last successful command never prints it.
set -u
usage() {
    echo "usage: tools/phase2_ci.sh [--through Rk] [--baseline BIN] <tag-binary> <main-binary> <branch-binary>"
}
through=""
baseline=""
while [ $# -gt 0 ]; do
    case "$1" in
        --through|--baseline)
            [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
            case "$2" in --*) usage; exit 2 ;; esac
            if [ "$1" = --through ]; then through=$2; else baseline=$2; fi
            shift 2 ;;
        --help|-h) usage; exit 0 ;;
        --) shift; break ;;
        -*) echo "phase2-ci: unknown option: $1" >&2; usage; exit 2 ;;
        *) break ;;
    esac
done
[ $# -eq 3 ] || { usage; exit 2; }
bins=()
for b in "$@"; do case "$b" in /*) bins+=("$b") ;; *) bins+=("$PWD/$b") ;; esac; done
if [ -n "$baseline" ]; then
    case "$baseline" in /*) ;; *) baseline="$PWD/$baseline" ;; esac
fi
cd "$(dirname "$0")/.." || exit 2
tmp=$(mktemp "${TMPDIR:-/tmp}/phase2-ci.XXXXXX") || exit 2
trap 'rm -f "$tmp"' EXIT
if [ -z "$through" ]; then
python3 -W error - > "$tmp" <<'EOF' || { cat "$tmp"; echo "phase2-ci: FAIL: could not derive --through"; exit 1; }
import os, sys
sys.path.insert(0, 'tools')
import phase2_check as p
rows, bad = p.parse_map(os.path.join(p.ROOT, 'tests/phase2/MAP.md'))
if bad:
    print('phase2-ci: the MAP does not parse: ' + '; '.join(bad))
    sys.exit(1)
try:
    through, diagnostics = p.derive_through(rows)
except (OSError, ValueError) as error:
    print('phase2-ci: invalid landed declaration: ' + str(error))
    sys.exit(1)
for diagnostic in diagnostics:
    print('phase2-ci: ' + diagnostic)
if through is None:
    print('phase2-ci: no round has all of its row files')
    sys.exit(1)
print('THROUGH ' + through)
EOF
grep -v '^THROUGH ' "$tmp"
through=$(sed -n 's/^THROUGH //p' "$tmp")
echo "phase2-ci: through=$through (the complete declared prefix of MAP rounds)"
else
    echo "phase2-ci: through=$through (explicit)"
fi
check_options=(--through "$through")
if [ -n "$baseline" ]; then check_options+=(--baseline "$baseline"); fi
fails=""
verdict() {   # verdict NAME RC OUTPUT VERDICT-ERE: the tool's output; rc 0 and its verdict line, once
    printf '%s\n' "$3"
    [ "$2" -eq 0 ] && [ "$(grep -cE "$4" <<< "$3")" -eq 1 ] || fails="$fails $1(rc=$2)"
}
out=$(bash tools/phase2_check.sh "${check_options[@]}" "${bins[0]}" "${bins[2]}" 2>&1); rc=$?
verdict phase2-check "$rc" "$out" '^phase2-check: PASS$'
out=$(bash tools/phase2_lib_diff.sh "${bins[1]}" "${bins[2]}" 2>&1); rc=$?
verdict phase2-lib-diff "$rc" "$out" '^phase2-lib-diff: listed_functions=[0-9]+ undeclared=0 stale=0 PASS$'
out=$(bash tools/phase2_builtins.sh "${bins[0]}" "${bins[2]}" 2>&1); rc=$?
verdict phase2-builtins "$rc" "$out" '^phase2-builtins: PASS rows=[1-9][0-9]* landed=[^ ]+ migrated=[0-9]+ unchanged=[0-9]+$'
for variant in release asan; do
    out=$(ASAN_OPTIONS=detect_leaks=1 bash tools/phase2_readers.sh "$variant" 2>&1); rc=$?
    verdict "phase2-readers-$variant" "$rc" "$out" "^phase2-readers: PASS variant=$variant checks=[1-9][0-9]*$"
done
if [ -n "$fails" ]; then
    echo "phase2-ci: FAIL:$fails"
    exit 1
fi
echo "phase2-ci: PASS (through=$through)"
