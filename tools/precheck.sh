#!/usr/bin/env bash
# Contributor precheck (#1264) — the repo's STATIC gates, locally, in seconds.
#
# BOUGHT: PR #1260, a correct 5-line fix, surfaced four gate failures one at a
# time, each after a ~45-minute CI run: a pipefail verdict shape, a test that
# nothing ran, a pinned child-site count, and a section count stated in the
# docs. Every one of them is decidable from the source tree alone. This runs
# those gates — our `make patchcheck` — so they are seen before the push.
#
#   make precheck                   (same as: bash tools/precheck.sh)
#   bash tools/precheck.sh --list   the manifest, classified
#   bash tools/precheck.sh --check  the manifest vs what CI runs (both ways)
#   bash tools/precheck.sh --selftest
#
# One line per gate; exit 1 if any gate fails, 2 if the precheck itself could
# not run. Gates that need a built binary run only when one exists
# (src/eigenscript or build/release/eigenscript) and say SKIP otherwise —
# `make` first to include them. Gates CI runs that are NOT static (network,
# toolchains, compile-heavy, runtime tests) are listed with the reason, so
# "precheck is green" never reads as "CI will be green".
#
# DRIFT IS GATED, NOT HAND-SYNCED. `--check` derives the set of tools/ scripts
# CI invokes — from tests/run_all_tests.sh and .github/workflows/*.yml, with
# the SAME invocation matcher the test-enrolment gate uses
# (tools/enrolment_check.sh --invocations) — and fails if CI runs a tool
# this manifest does not classify, or the manifest names a tool CI no longer
# runs. The suite runs `--check` (section [99ab]), so a new gate added to CI
# without a precheck decision is red on the PR that adds it. `--check` runs
# inside every precheck as well.

set -u
ROOT="${PRECHECK_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$ROOT" || { echo "precheck: ABORTED: cannot cd to $ROOT" >&2; exit 2; }

# ASan shard count: DERIVED from ci.yml, so precheck checks the plan CI checks.
ASAN_SHARDS=$(sed -n 's/^[[:space:]]*ASAN_SHARDS:[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' .github/workflows/ci.yml 2>/dev/null | head -1)

# ---------------------------------------------------------------------------
# The manifest: `tool | class | args-or-reason | cost`, one row per invocation.
#   run  static; always runs
#   bin  needs a built eigenscript; runs when one exists, SKIP otherwise
#   ci   CI-only; the reason says why it is not in a local precheck
# `cost` (run/bin rows) is seconds measured serially on the 2-core dev box. It
# only SCHEDULES the two lanes (longest first, onto the lighter lane); a wrong
# cost makes the precheck slower, never greener.
# A tool may have several `run`/`bin` rows (audit + --selftest). Every tool CI
# invokes needs at least one row; `--check` enforces it. Self-tests are
# included only where a contributor's ordinary edit can break them: the
# child-exit self-test plants against runner text every new section touches.
# The rest run in CI (suite sections), where they belong.
# ---------------------------------------------------------------------------
MANIFEST='
tools/pipefail_verdict_check.sh   | run |                                  | 13
tools/suite_label_check.sh        | run |                                  | 1
tools/child_exit_check.sh         | run |                                  | 1
tools/child_exit_check.sh         | run | --selftest                       | 4
tools/section_plan.sh             | run | --shards @ASAN_SHARDS@ --check   | 11
tools/enrolment_check.sh          | run |                                  | 1
tools/doc_drift_check.sh          | run |                                  | 1
tools/core_ext_boundary_check.sh  | run |                                  | 17
tools/obs_marker_check.sh         | run |                                  | 1
tools/obs_reader_sync_check.sh    | run |                                  | 1
tools/vm_operand_width_check.sh   | run |                                  | 1
tools/fmt_operator_sync_check.sh  | run |                                  | 1
tools/failsoft_classify_check.sh  | run |                                  | 6
tools/stdlib_index_check.sh       | run |                                  | 1
tools/workflow_yaml_check.sh      | run |                                  | 5
tools/codspeed_targets_check.sh   | run |                                  | 1
tools/gfx_guard_order_check.sh    | run |                                  | 1
tools/docs_claims_check.sh        | bin |                                  | 10
tools/precheck.sh                 | ci  | itself: --check runs inside every precheck; --selftest (and enrolment_check.sh --selftest) run in suite [99ab]
tools/portability_parse_check.sh  | ci  | runs docs_claims and a runtime child under an old bash (3.2); needs a binary and a bash32 oracle, ~1 min
tools/consumer_acceptance.sh      | ci  | clones and runs sibling consumer repos
tools/embed_roads.py              | ci  | runtime differential; part of suite section [99z]
tools/embed_stack_soak.sh         | ci  | builds an embed binary and soaks it under a stack rlimit
tools/freestanding_smoke.sh       | ci  | builds the freestanding (EigenOS) profile
tools/gc_traversal_check.py       | ci  | inspects the GC traversal output of an ASan build lane
tools/gfx_pixel_differential.sh   | ci  | runtime gfx differential; needs a gfx build
tools/gfx_strict_sweep.sh         | ci  | runtime gfx sweep; needs a gfx build
tools/gh_probe.sh                 | ci  | GitHub API probe helper (network)
tools/ilp32_syntax_check.sh       | ci  | compiles every TU for a 32-bit target; needs clang -m32
tools/issue_labels_check.sh       | ci  | reads open issues over the GitHub API (network)
tools/jit_diff.sh                 | ci  | JIT-vs-interpreter differential over the corpus; runtime, minutes
tools/lint_message_utf8_check.sh  | ci  | runs the linter binary over generated identifiers; runtime
tools/observer_gate_diff.sh       | ci  | runtime observer-gate differential over the corpus
tools/replay_diff.sh              | ci  | runtime record/replay differential
tools/road_diff.sh                | ci  | runtime file-semantics differential (suite [99z])
tools/roadmap_check.sh            | ci  | reads milestones over the GitHub API (network)
tools/strict_differential.sh      | ci  | runtime strict-mode differential
tools/werror_cache_key.sh         | ci  | CI cache-key derivation for the werror job; not a verdict
tools/werror_switch_check.sh      | ci  | dry-runs every Makefile rule and plants faults; ~6 min audit + ~11 min self-test on the dev box
'

manifest_rows() {   # tool|class|args|cost  ("|", not a tab: IFS collapses empty tab fields)  (trimmed, @ASAN_SHARDS@ expanded)
    printf '%s\n' "$MANIFEST" | awk -F'|' -v shards="$ASAN_SHARDS" '
        NF >= 2 {
            for (i = 1; i <= 4; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
            if ($1 == "") next
            gsub(/@ASAN_SHARDS@/, shards, $3)
            c = ($4 ~ /^[0-9]+$/) ? $4 : 1
            print $1 "|" $2 "|" $3 "|" c
        }'
}

# ---------------------------------------------------------------------------
# --check: the manifest against what CI runs, both directions.
# ---------------------------------------------------------------------------
do_check() {
    local rc=0 ci_tools man_tools t n_ci n_man bad_class
    if [ -z "$ASAN_SHARDS" ]; then
        echo "precheck --check: FAIL: could not derive ASAN_SHARDS from .github/workflows/ci.yml"; return 1
    fi
    ci_tools=$(ENROL_ROOT="$ROOT" bash "$ROOT/tools/enrolment_check.sh" --invocations \
                   tests/run_all_tests.sh .github/workflows/*.yml | grep '^tools/' | sort -u)
    n_ci=$(printf '%s\n' "$ci_tools" | grep -c .)
    if [ "$n_ci" -eq 0 ]; then
        echo "precheck --check: ABORTED: derived ZERO tools/ invocations from CI — the matcher is broken, not the manifest (§121)"; return 2
    fi
    man_tools=$(manifest_rows | cut -d'|' -f1 | sort -u)
    n_man=$(printf '%s\n' "$man_tools" | grep -c .)
    bad_class=$(manifest_rows | awk -F'|' '$2 != "run" && $2 != "bin" && $2 != "ci" { print $1 " (class \"" $2 "\")" }
                                             $2 == "ci" && $3 == "" { print $1 " (ci row without a reason)" }')
    if [ -n "$bad_class" ]; then
        printf '%s\n' "$bad_class" | sed 's/^/  FAIL: manifest row malformed: /'; rc=1
    fi
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if ! printf '%s\n' "$man_tools" | grep -qxF "$t"; then
            echo "  FAIL: CI runs $t, and tools/precheck.sh neither runs it nor says why not — add a manifest row (run / bin / ci + reason)"; rc=1
        fi
    done <<< "$ci_tools"
    while IFS= read -r t; do
        [ -n "$t" ] || continue
        if ! printf '%s\n' "$ci_tools" | grep -qxF "$t"; then
            echo "  FAIL: the precheck manifest names $t, which CI no longer runs — a precheck gate CI does not enforce can red where CI is green; delete the row or enrol the gate"; rc=1
        fi
        [ -f "$t" ] || { echo "  FAIL: manifest names $t, which does not exist"; rc=1; }
    done <<< "$man_tools"
    if [ "$rc" -eq 0 ]; then
        echo "precheck --check: OK (CI invokes $n_ci tools/ scripts; manifest classifies $n_man: $(manifest_rows | awk -F'|' '$2=="run"{r++} $2=="bin"{b++} $2=="ci"{c++} END{printf "%d run rows, %d bin rows, %d ci-only", r, b, c}'); ASAN_SHARDS=$ASAN_SHARDS from ci.yml)"
    fi
    return "$rc"
}

if [ "${1:-}" = "--check" ]; then
    do_check; exit $?
fi

if [ "${1:-}" = "--list" ]; then
    manifest_rows | awk -F'|' '{ printf "%-4s %-34s %s\n", $2, $1, $3 }'
    exit 0
fi

# ---------------------------------------------------------------------------
# --selftest: plant drift in a copy and require --check to name it.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--selftest" ]; then
    ST=$(mktemp -d "${TMPDIR:-/tmp}/eigs_precheck_st.XXXXXX") || exit 2
    trap 'rm -rf "$ST"' EXIT
    st_rc=0; st_n=0
    fresh() {
        rm -rf "$ST/tree"; mkdir -p "$ST/tree/.github" "$ST/tree/tests" "$ST/tree/tools"
        cp tests/*.sh tests/*.py "$ST/tree/tests/"
        cp tools/*.sh tools/*.py "$ST/tree/tools/"
        cp -R .github/workflows "$ST/tree/.github/"
    }
    st_case() {   # name want-rc want-substring
        local out rc
        st_n=$((st_n + 1))
        out=$(PRECHECK_ROOT="$ST/tree" bash "$ST/tree/tools/precheck.sh" --check 2>&1); rc=$?
        if [ "$rc" -eq "$2" ] && grep -qF -- "$3" <<< "$out"; then
            echo "  selftest ok: $1"
        else
            echo "  SELFTEST FAIL: $1 -- rc=$rc (want $2), wanted '$3'"; printf '%s\n' "$out" | sed 's/^/      /'; st_rc=1
        fi
    }
    fresh
    st_case "control: the real manifest agrees with CI" 0 "precheck --check: OK"
    # A new gate added to CI without a precheck decision.
    fresh
    printf '#!/bin/bash\necho ok\n' > "$ST/tree/tools/zz_new_check.sh"
    printf '\nif bash "$TESTS_DIR/../tools/zz_new_check.sh"; then :; fi\n' >> "$ST/tree/tests/run_all_tests.sh"
    st_case "CI gains a tool the manifest does not classify: red, named" 1 "CI runs tools/zz_new_check.sh, and tools/precheck.sh neither runs it"
    # A gate CI stops running while the precheck still runs it.
    fresh
    sed 's|tools/suite_label_check[.]sh"|tools/suite_label_check_gone"|' tests/run_all_tests.sh > "$ST/tree/tests/run_all_tests.sh"
    if cmp -s tests/run_all_tests.sh "$ST/tree/tests/run_all_tests.sh"; then
        echo "  SELFTEST BROKEN: the de-enrolment plant changed nothing"; st_rc=1
    else
        st_case "CI stops running a precheck gate: red, named" 1 "names tools/suite_label_check.sh, which CI no longer runs"
    fi
    # The shard count follows ci.yml.
    fresh
    sed 's/^\([[:space:]]*ASAN_SHARDS:[[:space:]]*\)3[[:space:]]*$/\14/' .github/workflows/ci.yml > "$ST/tree/.github/workflows/ci.yml"
    st_n=$((st_n + 1))
    if PRECHECK_ROOT="$ST/tree" bash "$ST/tree/tools/precheck.sh" --list | grep -q -- '--shards 4 --check'; then
        echo "  selftest ok: the section-plan shard count is derived from ci.yml"
    else
        echo "  SELFTEST FAIL: changing ASAN_SHARDS in ci.yml did not change the precheck's --shards"; st_rc=1
    fi
    echo "  checks=$st_n"
    [ "$st_rc" -eq 0 ] && echo "SELFTEST: all $st_n cases behaved" || echo "SELFTEST: FAILED"
    exit "$st_rc"
fi

case "${1:-}" in
    '') ;;
    *) echo "usage: tools/precheck.sh [--check|--list|--selftest]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------
# The run. Two lanes (bash 3.2 has no `wait -n`), each sequential; rows are
# dealt so the slow gates land on different lanes. Each gate's output goes to
# its own file; the summary prints in manifest order.
# ---------------------------------------------------------------------------
T0=$(date +%s)
OUT=$(mktemp -d "${TMPDIR:-/tmp}/eigs_precheck.XXXXXX") || exit 2
trap 'rm -rf "$OUT"' EXIT

BIN=""
for b in src/eigenscript build/release/eigenscript; do
    [ -x "$b" ] && { BIN="$b"; break; }
done

manifest_rows | awk -F'|' '$2 == "run" || $2 == "bin"' > "$OUT/rows"
n_rows=$(grep -c . "$OUT/rows")
[ "$n_rows" -gt 0 ] || { echo "precheck: ABORTED: the manifest has no run rows"; exit 2; }

run_row() {   # run_row <index> <tool> <class> <args>
    local i="$1" tool="$2" class="$3" args="$4" s e rc
    if [ "$class" = "bin" ] && [ -z "$BIN" ]; then
        printf 'SKIP|0|no eigenscript binary (run make to include this gate)\n' > "$OUT/$i.status"
        return
    fi
    s=$(date +%s)
    case "$tool" in
        *.py) (cd "$ROOT" && python3 "$tool" $args) > "$OUT/$i.log" 2>&1 ;;
        *)    (cd "$ROOT" && bash "$tool" $args) > "$OUT/$i.log" 2>&1 ;;
    esac
    rc=$?
    e=$(date +%s)
    if [ "$rc" -eq 0 ]; then
        printf 'PASS|%s|%s\n' "$((e - s))" "$(grep -v '^[[:space:]]*$' "$OUT/$i.log" | tail -1 | cut -c1-140)" > "$OUT/$i.status"
    else
        printf 'FAIL|%s|exit %s\n' "$((e - s))" "$rc" > "$OUT/$i.status"
    fi
}

# Longest-processing-time assignment: rows by cost, descending, each onto the
# lane with less work so far, written to $OUT/lane0 and lane1 as row indices.
awk -F'|' '{ print NR - 1 "|" $4 }' "$OUT/rows" | sort -t'|' -k2,2nr \
    | awk -F'|' -v L0="$OUT/lane0" -v L1="$OUT/lane1" \
        '{ if (w0 <= w1) { print $1 > L0; w0 += $2 } else { print $1 > L1; w1 += $2 } }'
: >> "$OUT/lane0"; : >> "$OUT/lane1"

lane() {   # lane <0|1>
    local idx row tool class args cost
    while IFS= read -r idx; do
        row=$(sed -n "$((idx + 1))p" "$OUT/rows")
        IFS='|' read -r tool class args cost <<< "$row"
        run_row "$idx" "$tool" "$class" "$args"
    done < "$OUT/lane$1"
}

echo "precheck: $n_rows gate run(s), 2 lanes$( [ -n "$BIN" ] && echo ", binary $BIN" || echo ", no binary (bin rows SKIP)")"
lane 0 & p0=$!
lane 1 & p1=$!
check_out=$(do_check 2>&1); check_rc=$?
wait "$p0" "$p1"

n_pass=0; n_fail=0; n_skip=0; i=0
while IFS='|' read -r tool class args cost; do
    if [ ! -f "$OUT/$i.status" ]; then
        printf '  FAIL  %-44s (no status: the lane died)\n' "$tool $args"; n_fail=$((n_fail + 1))
    else
        IFS='|' read -r st secs msg < "$OUT/$i.status"
        printf '  %-4s  %-44s %3ss  %s\n' "$st" "$tool${args:+ $args}" "$secs" "$msg"
        case "$st" in
            PASS) n_pass=$((n_pass + 1)) ;;
            SKIP) n_skip=$((n_skip + 1)) ;;
            *)    n_fail=$((n_fail + 1))
                  grep -v '^[[:space:]]*$' "$OUT/$i.log" | grep -E 'FAIL|ERROR|RED|ABORT|BROKEN' | head -8 | sed 's/^/          /'
                  echo "          (full output: bash $tool${args:+ $args})" ;;
        esac
    fi
    i=$((i + 1))
done < "$OUT/rows"
if [ "$check_rc" -eq 0 ]; then
    printf '  PASS  %-44s        %s\n' "tools/precheck.sh --check" "$(printf '%s\n' "$check_out" | tail -1 | cut -c1-140)"
    n_pass=$((n_pass + 1))
else
    printf '  FAIL  %-44s\n' "tools/precheck.sh --check"
    printf '%s\n' "$check_out" | sed 's/^/          /'
    n_fail=$((n_fail + 1))
fi
examined=$((n_pass + n_fail + n_skip))
T1=$(date +%s)
if [ "$examined" -ne $((n_rows + 1)) ]; then
    echo "precheck: ABORTED: $examined results for $((n_rows + 1)) gates — a row fell through"; exit 2
fi
n_ci=$(manifest_rows | awk -F'|' '$2 == "ci"' | grep -c .)
echo "precheck: $n_pass passed, $n_fail failed, $n_skip skipped in $((T1 - T0))s ($n_ci CI-only gate(s) not run here: bash tools/precheck.sh --list)"
[ "$n_fail" -eq 0 ] || exit 1
exit 0
