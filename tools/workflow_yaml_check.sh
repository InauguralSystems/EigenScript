#!/usr/bin/env bash
# workflow_yaml_check.sh — every workflow under .github/workflows/ LOADS.
#
# WHY THIS EXISTS (2026-09-21, round 2 of #1207/#1155):
# round 1 shipped `.github/workflows/issue-triage.yml` — the daily lane that
# makes issue labelling mechanical — with two step names of the shape
#
#     - name: Every open issue carries an area: label and a kind
#
# A plain YAML scalar may not contain `: `. The file is therefore not loadable
# YAML: GitHub rejects the workflow, the daily audit never runs, and nothing
# in the repository said so. TWO blind critics read that file closely — one
# quoted its permissions, timeouts and concurrency key back verbatim — and
# neither PARSED it. Reading a config is not loading it; this gate loads it.
# (Every other workflow in the tree parsed, so the gate was red exactly once,
# on the file that bought it.)
#
# WHAT IT ENFORCES:
#   (a) TEXT — no `name:` value is an unquoted plain scalar containing `: `.
#       This is the exact defect, catchable with no dependencies at all, so
#       this arm NEVER skips.
#   (b) PARSE — every workflow file round-trips through a real YAML loader.
#       Broader than (a): catches indentation and structure faults too. Needs
#       python3 with PyYAML; SKIPs BY NAME without it, never (a).
#
# Enumeration discipline (mechanical-gates §121): both arms print `examined=N`
# over a population that must be non-empty. A workflow directory that matched
# nothing is a failure, not a pass.
#
# Usage:
#   bash tools/workflow_yaml_check.sh              # .github/workflows
#   bash tools/workflow_yaml_check.sh --selftest   # planted faults, each red
#   bash tools/workflow_yaml_check.sh --contract   # the population regex and
#                                                  # the pinned case count
#   WORKFLOW_CHECK_DIR=/path/to/dir bash tools/workflow_yaml_check.sh
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WF_DIR="${WORKFLOW_CHECK_DIR:-$ROOT/.github/workflows}"

# Nothing on stdin, for the reason docs_claims_check.sh records: a counting
# pipeline that inherits an open stdin hangs; one that inherits /dev/null
# counts 0 and passes the guard built on that count.
exec 0</dev/null

# THE CONTRACT — printed by `--contract`, asserted by the caller, defined once.
POPULATION_RE='^workflow-yaml: OK \(examined=[1-9][0-9]* file\(s\), [1-9][0-9]* name\(s\)\)$'
SELFTEST_CASES=5

RED=0
red() { echo "RED: $*"; RED=$((RED + 1)); }

FILES_N=0
NAMES_N=0

# ---------------------------------------------------------------------------
# (a) TEXT — a `name:` whose plain value contains `: ` is not loadable YAML.
# ---------------------------------------------------------------------------
check_text() {
    local f line lineno value
    for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        FILES_N=$((FILES_N + 1))
        lineno=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))
            case "$line" in
                *"name:"*) ;;
                *) continue ;;
            esac
            # `name:` as a key: optional list dash, then name:, then the value.
            if ! [[ $line =~ ^[[:space:]]*(-[[:space:]]+)?name:[[:space:]](.*)$ ]]; then
                continue
            fi
            value="${BASH_REMATCH[2]}"
            NAMES_N=$((NAMES_N + 1))
            case "$value" in
                '"'*|"'"*|'>'*|'|'*|'') continue ;;
            esac
            case "$value" in
                *': '*)
                    red "(a) $f:$lineno — the plain scalar after \`name:\` contains \`: \`, which no YAML loader accepts; quote it: $line" ;;
            esac
        done < "$f"
    done
    if [ "$FILES_N" -eq 0 ]; then
        red "(a) $WF_DIR holds no workflow file — an empty population passes every check without loading anything (mechanical-gates §121)"
        return
    fi
    if [ "$NAMES_N" -eq 0 ]; then
        red "(a) examined $FILES_N workflow file(s) and found 0 \`name:\` key(s) — the scan matched nothing"
        return
    fi
    echo "      (a) plain-scalar names: examined=$FILES_N file(s), $NAMES_N name(s)"
}

# ---------------------------------------------------------------------------
# (b) PARSE — a real loader, when one is available.
# ---------------------------------------------------------------------------
check_parse() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "      (b) SKIPPED BY NAME: python3 is not on PATH, so the files cannot be loaded. Arm (a) still ran."
        return
    fi
    if ! python3 -c "import yaml" >/dev/null 2>&1; then
        echo "      (b) SKIPPED BY NAME: PyYAML is not installed, so the files cannot be loaded. Arm (a) still ran."
        return
    fi
    local out
    if ! out=$(WF_DIR="$WF_DIR" python3 -c '
import glob, os, sys, yaml
d = os.environ["WF_DIR"]
files = sorted(glob.glob(os.path.join(d, "*.yml")) + glob.glob(os.path.join(d, "*.yaml")))
bad = 0
for f in files:
    try:
        doc = yaml.safe_load(open(f, encoding="utf-8"))
    except Exception as exc:
        print("BAD %s: %s" % (f, str(exc).replace("\n", " ")[:200]))
        bad += 1
        continue
    if not isinstance(doc, dict) or "jobs" not in doc:
        print("BAD %s: loaded, but it is not a workflow (no top-level jobs: mapping)" % f)
        bad += 1
print("PARSED %d" % len(files))
'); then
        red "(b) the YAML loader itself failed on $WF_DIR"
        return
    fi
    local line parsed
    while IFS= read -r line; do
        case "$line" in
            BAD\ *) red "(b) ${line#BAD }" ;;
        esac
    done <<< "$out"
    parsed=$(printf '%s\n' "$out" | sed -n 's/^PARSED //p' | tail -1)
    if [ "${parsed:-0}" -ne "$FILES_N" ]; then
        red "(b) the loader saw ${parsed:-0} file(s) but the text arm saw $FILES_N — the two arms are not looking at the same population"
        return
    fi
    echo "      (b) loader: examined=${parsed:-0} workflow file(s)"
}

run_live() {
    echo "workflow-yaml env: dir=$WF_DIR"
    check_text
    check_parse
    if [ "$RED" -ne 0 ]; then
        echo "workflow-yaml: $RED problem(s)"
        return 1
    fi
    local ok_line="workflow-yaml: OK (examined=$FILES_N file(s), $NAMES_N name(s))"
    echo "$ok_line"
    if ! [[ $ok_line =~ $POPULATION_RE ]]; then
        echo "RED: (a) the population line does not match this gate's own published contract"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# --selftest — every plant names the ARM it must turn red.
# ---------------------------------------------------------------------------
ST_RUN=0
ST_FAIL=0
st_case() {
    local name="$1" arm="$2" expect="$3" dir="$4"
    ST_RUN=$((ST_RUN + 1))
    local out rc
    out=$(WORKFLOW_CHECK_DIR="$dir" "$SELF" 2>&1)
    rc=$?
    if [ "$expect" = "red" ]; then
        if [ "$rc" -ne 0 ] && [[ $'\n'"$out" == *$'\n'"RED: ($arm)"* ]]; then
            echo "  selftest ok: $name — arm ($arm) went red"
            printf '%s\n' "$out" | grep "^RED: ($arm)" | head -1 | sed 's/^/      /'
        else
            ST_FAIL=$((ST_FAIL + 1))
            echo "  SELFTEST FAIL: $name — expected arm ($arm) red, got rc=$rc"
            printf '%s\n' "$out" | head -8 | sed 's/^/      /'
        fi
    else
        if [ "$rc" -eq 0 ]; then
            echo "  selftest ok: $name — green as designed"
        else
            ST_FAIL=$((ST_FAIL + 1))
            echo "  SELFTEST FAIL: $name — expected green, got rc=$rc"
            printf '%s\n' "$out" | head -8 | sed 's/^/      /'
        fi
    fi
}

selftest() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/workflow_yaml.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT

    mkdir -p "$work/good"
    cat > "$work/good/w.yml" <<'EOF'
name: a lane
on:
  workflow_dispatch:
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - name: "Every open issue carries an area: label and a kind"
        run: echo hi
EOF
    st_case "control: a quoted step name with a colon loads" "-" green "$work/good"

    # PLANT 1 (arm a): the exact defect round 1 shipped.
    mkdir -p "$work/plain"
    sed 's%- name: "Every open issue carries an area: label and a kind"%- name: Every open issue carries an area: label and a kind%' \
        "$work/good/w.yml" > "$work/plain/w.yml"
    st_case "plant: an unquoted step name containing ': '" "a" red "$work/plain"

    # PLANT 2 (arm b): the same file, seen by the loader rather than the text
    # scan — proof the two arms are independent and not one arm twice.
    mkdir -p "$work/parse"
    cp "$work/good/w.yml" "$work/parse/w.yml"
    printf '  two:\n   runs-on: [\n' >> "$work/parse/w.yml"
    st_case "plant: a file the loader cannot parse at all" "b" red "$work/parse"

    # PLANT 3 (arm b): loadable YAML that is not a workflow.
    mkdir -p "$work/nojobs"
    printf 'name: a lane\non:\n  workflow_dispatch:\n' > "$work/nojobs/w.yml"
    st_case "plant: loadable YAML with no jobs: mapping" "b" red "$work/nojobs"

    # PLANT 4 (arm a): the empty population.
    mkdir -p "$work/empty"
    st_case "plant: a workflow directory with no workflows (vacuity)" "a" red "$work/empty"

    echo ""
    echo "SELFTEST: $ST_RUN case(s) run, $((ST_RUN - ST_FAIL)) passed, $ST_FAIL failed"
    [ "$ST_FAIL" -eq 0 ]
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
    --contract) printf 'POPULATION_RE=%s\n' "$POPULATION_RE"
                printf 'SELFTEST_CASES=%s\n' "$SELFTEST_CASES"
                exit 0 ;;
    "") run_live; exit $? ;;
    *) echo "usage: $0 [--selftest|--contract]" >&2; exit 2 ;;
esac
