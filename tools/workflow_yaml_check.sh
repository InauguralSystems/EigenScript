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
# WHAT A LOAD PROVES, EXACTLY: that the bytes are well-formed YAML and carry a
# top-level `jobs:` mapping. It does NOT prove the file is a valid GitHub
# Actions workflow — GitHub's own schema (step keys, `uses:` shapes, expression
# syntax, `runs-on` labels) is not checked here and a file can load cleanly and
# still be rejected by GitHub. Loadability is the floor this gate owns.
#
# WHAT IT ENFORCES:
#   (a) TEXT — no `name:` value is an unquoted plain scalar containing `: `.
#       This is the exact defect, catchable with no dependencies at all, so
#       this arm NEVER skips.
#
#       ROUND 3 (blind critics Astra check 6 / Fable evidence 07): arm (a) as
#       shipped rejected LEGAL YAML, which is worse than missing a fault —
#       a gate that cries wolf on correct files gets disabled. All three of
#           name: safe # comment: detail
#           name:  "key: value"
#           run: |
#             echo "name: x: y"          <- inside a block scalar
#       load fine in PyYAML and were red. Arm (a) now tokenises the scalar the
#       way YAML does before looking for `: `: a ` #` comment is stripped
#       first, the value is trimmed, a quoted scalar is skipped whole, and any
#       line inside a `|`/`>` block scalar is skipped until the block dedents.
#
#   (b) PARSE — every workflow file round-trips through a real YAML loader.
#       Broader than (a): catches indentation and structure faults too. Needs
#       python3 with PyYAML; SKIPs BY NAME without it, never (a). The runner
#       images install it (.devcontainer/Dockerfile for the Linux/dev image,
#       a setup step on the macOS lane), because a gate whose second arm never
#       runs on the lane is the round-1 failure wearing a different hat.
#
#   The SELFTEST is skip-aware for the same reason (round 3, Fable): two of
#   its plants can only go red through arm (b), and on a runner with no PyYAML
#   they were scored "did NOT go red" — so the gate that exists because a lane
#   never ran took every suite leg red with it (CI run 35599371704). A plant
#   whose arm skipped by name is now scored SKIP, counted, and reported in the
#   pinned SELFTEST line, and the CALLER pins the skip count and allows it
#   only when PyYAML is genuinely absent (it probes for PyYAML itself).
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

# THE CONTRACT — printed by `--contract`. Every CALLER holds its OWN literal
# copy of both values and asserts the gate's output against ITS copy; a
# separate caller check asserts this contract EQUALS the caller's copy, so a
# drift is red by name and is never auto-adopted (round-3 rule: the caller is
# the independent witness, not a reader of the thing it polices).
POPULATION_RE='^workflow-yaml: OK \(examined=[1-9][0-9]* file\(s\), [1-9][0-9]* name\(s\), loader=(pyyaml|skipped:[a-z0-9-]+)\)$'
SELFTEST_CASES=8

RED=0
red() { echo "RED: $*"; RED=$((RED + 1)); }

FILES_N=0
NAMES_N=0
LOADER_SRC="unset"

# Leading-whitespace width of a line, tabs counted as one column each (YAML
# forbids tabs in indentation, so this only has to be monotone).
indent_of() {
    local s="$1" rest
    rest="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "$(( ${#s} - ${#rest} ))"
}

# The two [[ =~ ]] patterns below, held in VARIABLES.
#
# BOUGHT 2026-09-21 (round 4, #1207): bash 3.2 — the oldest shell
# tools/portability_parse_check.sh parses every tracked script under — CANNOT
# PARSE a literal `=~` regex containing `(`; it dies at parse time with
# "syntax error in conditional expression: unexpected token `('". The same
# regex held in a variable parses and matches identically on 3.2 and on 5.x.
# This file shipped with both patterns inline since round 1 and no CI lane ever
# noticed, because every runner in the matrix reports "NO OLD BASH ON THIS
# MACHINE" and [99zb] SKIPs — a gate that can only skip, which is the exact
# class this whole campaign is about.
RE_BLOCK_SCALAR='^[[:space:]]*(-[[:space:]]+)?[^:#]*:[[:space:]]*[|>][0-9]*[+-]?[[:space:]]*$'
RE_NAME_KEY='^[[:space:]]*(-[[:space:]]+)?name:[[:space:]](.*)$'

# Trim leading and trailing spaces/tabs.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# (a) TEXT — a `name:` whose PLAIN value contains `: ` is not loadable YAML.
#     Tokenised per YAML: comments stripped, quoted scalars skipped, block
#     scalars skipped whole.
# ---------------------------------------------------------------------------
check_text() {
    local f line lineno value in_block blk_indent ind
    for f in "$WF_DIR"/*.yml "$WF_DIR"/*.yaml; do
        [ -f "$f" ] || continue
        FILES_N=$((FILES_N + 1))
        lineno=0
        in_block=0
        blk_indent=0
        while IFS= read -r line; do
            lineno=$((lineno + 1))

            # --- inside a `|`/`>` block scalar? Its content is DATA, not YAML
            # structure: `name: x: y` in a `run:` script is legal and was red.
            if [ "$in_block" -eq 1 ]; then
                if [ -z "$(trim "$line")" ]; then
                    continue
                fi
                ind=$(indent_of "$line")
                if [ "$ind" -gt "$blk_indent" ]; then
                    continue
                fi
                in_block=0
            fi

            # --- does this line OPEN a block scalar (`key: |`, `- run: >-2`)?
            if [[ $line =~ $RE_BLOCK_SCALAR ]]; then
                in_block=1
                blk_indent=$(indent_of "$line")
                continue
            fi

            case "$line" in
                *"name:"*) ;;
                *) continue ;;
            esac
            # `name:` as a key: optional list dash, then name:, then the value.
            if ! [[ $line =~ $RE_NAME_KEY ]]; then
                continue
            fi
            NAMES_N=$((NAMES_N + 1))
            value=$(trim "${BASH_REMATCH[2]}")

            # A quoted scalar carries its colons legally; a block scalar header
            # was consumed above; an anchor/alias/empty value has no plain text.
            case "$value" in
                '"'*|"'"*|'>'*|'|'*|'#'*|'') continue ;;
            esac
            # A ` #` outside quotes starts a comment: everything after it is
            # not part of the scalar. `${value%% #*}` keeps the SHORTEST
            # prefix, i.e. it cuts at the FIRST ` #`.
            case "$value" in
                *' #'*) value=$(trim "${value%% #*}") ;;
            esac
            [ -n "$value" ] || continue

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
        LOADER_SRC="skipped:no-python3"
        echo "      (b) SKIPPED BY NAME: python3 is not on PATH, so the files cannot be loaded. Arm (a) still ran."
        return
    fi
    if ! python3 -c "import yaml" >/dev/null 2>&1; then
        LOADER_SRC="skipped:no-pyyaml"
        echo "      (b) SKIPPED BY NAME: PyYAML is not installed, so the files cannot be loaded. Arm (a) still ran."
        return
    fi
    LOADER_SRC="pyyaml"
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
    echo "      (b) loader: examined=${parsed:-0} workflow file(s) (a load proves the bytes parse and carry jobs:, NOT that GitHub's workflow schema accepts them)"
}

run_live() {
    echo "workflow-yaml env: dir=$WF_DIR"
    check_text
    check_parse
    if [ "$RED" -ne 0 ]; then
        echo "workflow-yaml: $RED problem(s)"
        return 1
    fi
    local ok_line="workflow-yaml: OK (examined=$FILES_N file(s), $NAMES_N name(s), loader=$LOADER_SRC)"
    echo "$ok_line"
    if ! [[ $ok_line =~ $POPULATION_RE ]]; then
        echo "RED: (a) the population line does not match this gate's own published contract"
        echo "      line:     $ok_line"
        echo "      contract: $POPULATION_RE"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# --selftest — every plant names the ARM it must turn red. A plant whose arm
# SKIPPED BY NAME on this runner is scored SKIP, not FAIL: the plant proves
# nothing about an arm that did not execute, and calling that a failure is how
# this gate took three CI legs red on 538288c.
# ---------------------------------------------------------------------------
ST_RUN=0
ST_FAIL=0
ST_SKIP=0
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
        elif [[ "$out" == *"      ($arm) SKIPPED BY NAME"* ]]; then
            ST_SKIP=$((ST_SKIP + 1))
            echo "  selftest SKIPPED BY NAME: $name — arm ($arm) did not run on this host"
            printf '%s\n' "$out" | grep "($arm) SKIPPED BY NAME" | head -1 | sed 's/^/      /'
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

    # --- CONTROLS for the three legal-YAML shapes arm (a) used to reject.
    # A gate that fails correct input is a gate somebody turns off; each of
    # these loads cleanly in PyYAML and must be GREEN here (round 3).

    # CONTROL 5 (arm a): a trailing ` #` comment whose text contains `: `.
    mkdir -p "$work/comment"
    cat > "$work/comment/w.yml" <<'EOF'
name: a lane
on:
  workflow_dispatch:
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - name: safe # comment: detail
        run: echo hi
EOF
    st_case "control: a name with a trailing '# comment: detail'" "-" green "$work/comment"

    # CONTROL 6 (arm a): a quoted scalar after EXTRA spaces.
    mkdir -p "$work/quoted"
    cat > "$work/quoted/w.yml" <<'EOF'
name: a lane
on:
  workflow_dispatch:
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - name:  "key: value"
        run: echo hi
EOF
    st_case "control: a quoted name after two spaces" "-" green "$work/quoted"

    # CONTROL 7 (arm a): `name:` TEXT inside a `run: |` block scalar. This is
    # script data, not a YAML key, and loads fine.
    mkdir -p "$work/block"
    cat > "$work/block/w.yml" <<'EOF'
name: a lane
on:
  workflow_dispatch:
jobs:
  one:
    runs-on: ubuntu-latest
    steps:
      - name: prints a colon
        run: |
          echo "name: x: y"
          echo "- name: Every open issue carries an area: label and a kind"
EOF
    st_case "control: 'name: x: y' inside a run block scalar" "-" green "$work/block"

    echo ""
    echo "SELFTEST: $ST_RUN case(s) run, $((ST_RUN - ST_FAIL - ST_SKIP)) passed, $ST_FAIL failed, $ST_SKIP skipped"
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
