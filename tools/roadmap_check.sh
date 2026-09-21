#!/usr/bin/env bash
# roadmap_check.sh — ROADMAP.md is a MILESTONE SET, not a checkbox pile.
#
# WHY THIS EXISTS (measured on main b91768e, 2026-09-21, issue #1207, and
# confirmed by two independent critics before it was written):
# ROADMAP.md carried 112 checkboxes — 92 `[x]`, 20 `[ ]`, one `[~]` — of which
# 62 were HISTORICAL HIGHLIGHTS under `## Completed`. Anything counting
# "roadmap items done" was therefore counting the past. On top of that the
# population double-counted (#414 appeared at two lines; Windows appeared as an
# umbrella plus three tiers), contained items execution refutes (Public release
# — v0.43.0 shipped 2026-09-06; WASM — web/build.sh + pages.yml exist;
# `utf8_encode` — shipped in PR #450), contained items the file's own veto list
# contradicts (Windows Tier 2 JIT; the package registry/solver), and OMITTED
# the concurrency foundation #1153 entirely. MetaOrchestrator/GOALS.md reads
# this file, so the miscount left the repo.
#
# WHAT IT ENFORCES:
#   (a) the counted population is the table and NOTHING else —
#       * zero `- [ ]` / `- [x]` / `- [~]` lines anywhere in the file, and
#       * exactly ONE markdown table in the file, inside `## Milestones`,
#         every row 5 cells, every status a known word, rows > 0.
#       This arm never skips. It needs no network and no `gh`.
#   (b) the table's OPEN rows are exactly the open GitHub milestones, by
#       number. Runs when `gh` is on PATH and authenticated, or when
#       ROADMAP_CHECK_MILESTONES_JSON names a JSON file (the selftest's seam,
#       and an offline escape hatch). Otherwise it SKIPs BY NAME — never (a).
#
# Enumeration discipline (mechanical-gates §121): both arms print
# `examined=N` and refuse when N is 0 or when N != the table size. "Some rows
# were checked" is what a gutted walk also prints.
#
# Usage:
#   bash tools/roadmap_check.sh              # the real ROADMAP.md
#   bash tools/roadmap_check.sh --selftest   # planted faults, each must go red
#   ROADMAP_CHECK_FILE=/path/to/ROADMAP.md bash tools/roadmap_check.sh
#   ROADMAP_CHECK_MILESTONES_JSON=/path/to/milestones.json bash tools/roadmap_check.sh
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# This gate never reads stdin: a `grep -c` whose stdin is an open pipe hangs
# the whole check, and one whose stdin is /dev/null counts 0 and passes a
# vacuity guard built on it (the failure tools/docs_claims_check.sh bought on
# 2026-09-18). There is nothing here to block on.
exec 0</dev/null

RC_FILE="${ROADMAP_CHECK_FILE:-$ROOT/ROADMAP.md}"
REPO="${ROADMAP_CHECK_REPO:-InauguralSystems/EigenScript}"

RED=0
red() { echo "RED: $*"; RED=$((RED + 1)); }
note() { echo "      $*"; }

# A status word that is NOT compared against GitHub. Everything else is an
# "open row" and must have a milestone number.
is_closed_status() {
    case "$1" in
        retired|completed) return 0 ;;
        *) return 1 ;;
    esac
}
is_known_status() {
    case "$1" in
        active|declared-not-started|blocked|retired|completed) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# (a) STRUCTURE — no checkboxes anywhere, exactly one table, inside Milestones.
# ---------------------------------------------------------------------------
# The two rows the table must be able to hold are counted separately from the
# rows GitHub knows about, so a table that shrank to its retired rows still
# fails (b) rather than passing it vacuously.
TABLE_NUMBERS=""      # milestone numbers of OPEN rows
TABLE_ROWS=0
TABLE_OPEN_ROWS=0

check_structure() {
    if [ ! -f "$RC_FILE" ]; then
        red "no such file: $RC_FILE"
        return
    fi

    # Checkbox lines, anywhere in the file. Deliberately looser than the shape
    # the old file used (`- [x] `): any list bullet, any of the three marks,
    # any indentation (mechanical-gates §12 — the detector must be looser on
    # every axis it polices than the thing it is policing).
    local cb
    cb=$(grep -cE '^[[:space:]]*[-*+][[:space:]]*\[[ xX~][[:space:]]*\]' "$RC_FILE")
    if [ "$cb" -ne 0 ]; then
        red "(a) $RC_FILE has $cb checkbox line(s); the counted population is the milestone table, and a checkbox anywhere makes something else countable"
        grep -nE '^[[:space:]]*[-*+][[:space:]]*\[[ xX~][[:space:]]*\]' "$RC_FILE" | head -5 | sed 's/^/      /'
    fi

    # Exactly one table: count header-separator lines (`| --- | --- |`).
    local seps
    seps=$(grep -cE '^[[:space:]]*\|[[:space:]:-]+\|[[:space:]:|-]*$' "$RC_FILE")
    if [ "$seps" -ne 1 ]; then
        red "(a) $RC_FILE has $seps markdown table(s); exactly one is allowed, and it is the milestone table"
    fi

    # ...and it must live under `## Milestones`.
    local sep_line ms_line next_h
    sep_line=$(grep -nE '^[[:space:]]*\|[[:space:]:-]+\|[[:space:]:|-]*$' "$RC_FILE" | head -1 | cut -d: -f1)
    ms_line=$(grep -n '^## Milestones[[:space:]]*$' "$RC_FILE" | head -1 | cut -d: -f1)
    if [ -z "$ms_line" ]; then
        red "(a) $RC_FILE has no '## Milestones' heading — the table has no declared home"
        return
    fi
    next_h=$(awk -v start="$ms_line" 'NR > start && /^## / { print NR; exit }' "$RC_FILE")
    [ -n "$next_h" ] || next_h=$(wc -l < "$RC_FILE")
    if [ -z "$sep_line" ] || [ "$sep_line" -lt "$ms_line" ] || [ "$sep_line" -gt "$next_h" ]; then
        red "(a) the table is not inside the '## Milestones' section (table separator at line ${sep_line:-none}, section spans $ms_line..$next_h)"
        return
    fi

    # Walk the rows. Every data row: 5 cells, a known status, and a milestone
    # number iff the status is an open one.
    local row num title status url done_when bad_cells=0
    while IFS= read -r line; do
        case "$line" in
            '|'*) ;;
            *) continue ;;
        esac
        # skip the header row and the separator
        case "$line" in
            *'---'*) continue ;;
        esac
        # The header row. Matched with bash's own matcher rather than
        # `printf | grep -q`: an early-exiting reader at the end of a pipe is
        # the shape tools/pipefail_verdict_check.sh bans, and under bash 3.2 it
        # also prints a nondeterministic "write error: Broken pipe" (docs/CI.md).
        if [[ "$line" =~ ^\|[[:space:]]*#[[:space:]]*\| ]]; then
            continue
        fi
        TABLE_ROWS=$((TABLE_ROWS + 1))
        # split on '|' — leading and trailing empties dropped
        num=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
        title=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}')
        status=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
        url=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')
        done_when=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$6); print $6}')
        local ncells
        ncells=$(printf '%s' "$line" | awk -F'|' '{print NF-2}')
        if [ "$ncells" -ne 5 ]; then
            red "(a) table row has $ncells cell(s), 5 required (number, milestone, status, GitHub, DONE when): $line"
            bad_cells=$((bad_cells + 1))
            continue
        fi
        if ! is_known_status "$status"; then
            red "(a) unknown status '$status' in row: $title"
            continue
        fi
        if [ -z "$title" ] || [ -z "$url" ] || [ -z "$done_when" ]; then
            red "(a) row '$title' is missing a title, a GitHub reference or a DONE clause"
            continue
        fi
        if is_closed_status "$status"; then
            continue
        fi
        if ! [[ "$num" =~ ^[0-9]+$ ]]; then
            red "(a) open row '$title' (status $status) has no milestone number in its first cell (got '$num')"
            continue
        fi
        TABLE_OPEN_ROWS=$((TABLE_OPEN_ROWS + 1))
        TABLE_NUMBERS="$TABLE_NUMBERS $num"
    done < "$RC_FILE"

    if [ "$TABLE_ROWS" -eq 0 ]; then
        red "(a) the milestone table has 0 rows — a table that examines nothing is not a population (mechanical-gates §121)"
        return
    fi
    if [ "$TABLE_OPEN_ROWS" -eq 0 ]; then
        red "(a) the milestone table has $TABLE_ROWS row(s) but none of them is open — the roadmap would be entirely retired history"
        return
    fi
    echo "      (a) structure: examined=$TABLE_ROWS row(s), open=$TABLE_OPEN_ROWS, checkboxes=$cb, tables=$seps"
}

# ---------------------------------------------------------------------------
# (b) The open rows ARE the open GitHub milestones.
# ---------------------------------------------------------------------------
check_milestones() {
    local json src
    if ! command -v python3 >/dev/null 2>&1; then
        echo "      (b) SKIPPED BY NAME: python3 is not on PATH, so the milestone JSON cannot be parsed. Arm (a) still ran."
        return
    fi
    if [ -n "${ROADMAP_CHECK_MILESTONES_JSON:-}" ]; then
        if [ ! -f "$ROADMAP_CHECK_MILESTONES_JSON" ]; then
            red "(b) ROADMAP_CHECK_MILESTONES_JSON names no file: $ROADMAP_CHECK_MILESTONES_JSON"
            return
        fi
        json=$(cat "$ROADMAP_CHECK_MILESTONES_JSON")
        src="fixture $ROADMAP_CHECK_MILESTONES_JSON"
    else
        if ! command -v gh >/dev/null 2>&1; then
            echo "      (b) SKIPPED BY NAME: gh is not on PATH, so the table cannot be compared with the GitHub milestone set. Arm (a) still ran."
            return
        fi
        if ! json=$(gh api "repos/$REPO/milestones?state=open&per_page=100" 2>/dev/null); then
            echo "      (b) SKIPPED BY NAME: gh is present but the milestone API call failed (unauthenticated, offline, or rate-limited). Arm (a) still ran."
            return
        fi
        src="gh api repos/$REPO/milestones"
    fi

    local gh_numbers
    if ! gh_numbers=$(printf '%s' "$json" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("parse: %s\n" % exc)
    sys.exit(2)
if not isinstance(data, list):
    sys.stderr.write("parse: expected a JSON array of milestones\n")
    sys.exit(2)
for m in data:
    if m.get("state", "open") == "open":
        print(m["number"])
'); then
        red "(b) could not read the milestone list from $src"
        return
    fi

    local gh_count
    gh_count=$(printf '%s\n' "$gh_numbers" | grep -c '^[0-9][0-9]*$')
    if [ "$gh_count" -eq 0 ]; then
        red "(b) $src returned 0 open milestone(s) — an empty population passes every set comparison, so it is a failure, not a pass (mechanical-gates §121)"
        return
    fi

    # Set difference both ways, with plain loops: no process substitution and
    # no `comm`, so this behaves identically under the oldest bash the
    # portability audit runs ([99zb]).
    local missing="" extra="" g t found
    for g in $gh_numbers; do
        case "$g" in ''|*[!0-9]*) continue ;; esac
        found=0
        for t in $TABLE_NUMBERS; do
            [ "$t" = "$g" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || missing="$missing $g"
    done
    for t in $TABLE_NUMBERS; do
        found=0
        for g in $gh_numbers; do
            [ "$t" = "$g" ] && { found=1; break; }
        done
        [ "$found" -eq 1 ] || extra="$extra $t"
    done

    if [ -n "$(printf '%s' "$missing" | tr -d ' ')" ]; then
        red "(b) open GitHub milestone(s) with no row in the table:$missing (source: $src)"
    fi
    if [ -n "$(printf '%s' "$extra" | tr -d ' ')" ]; then
        red "(b) table row(s) claiming a milestone that is not open on GitHub:$extra (source: $src)"
    fi
    if [ "$TABLE_OPEN_ROWS" -ne "$gh_count" ]; then
        red "(b) examined=$TABLE_OPEN_ROWS open row(s) against $gh_count open milestone(s) — the counts must match"
    fi
    echo "      (b) milestones: examined=$TABLE_OPEN_ROWS open row(s) vs $gh_count open milestone(s) from $src"
}

run_live() {
    echo "roadmap-check env: file=$RC_FILE repo=$REPO gh=$(command -v gh >/dev/null 2>&1 && echo present || echo absent)"
    check_structure
    check_milestones
    if [ "$RED" -ne 0 ]; then
        echo "roadmap-check: $RED problem(s)"
        return 1
    fi
    echo "roadmap-check: OK (examined=$TABLE_ROWS row(s), open=$TABLE_OPEN_ROWS)"
    return 0
}

# ---------------------------------------------------------------------------
# --selftest — every plant names the ARM it must turn red, and is run through
# the REAL entry point (mechanical-gates §99), never against a re-implementation
# of the logic here.
# ---------------------------------------------------------------------------
ST_RUN=0
ST_FAIL=0
st_case() {
    # st_case <name> <arm> <expect red|green> <file> <json-or-->
    local name="$1" arm="$2" expect="$3" file="$4" js="$5"
    ST_RUN=$((ST_RUN + 1))
    local out rc
    if [ "$js" = "-" ]; then
        out=$(ROADMAP_CHECK_FILE="$file" ROADMAP_CHECK_MILESTONES_JSON="" "$SELF" 2>&1)
    else
        out=$(ROADMAP_CHECK_FILE="$file" ROADMAP_CHECK_MILESTONES_JSON="$js" "$SELF" 2>&1)
    fi
    rc=$?
    if [ "$expect" = "red" ]; then
        if [ "$rc" -ne 0 ] && [[ $'\n'"$out" == *$'\n'"RED: ($arm)"* ]]; then
            echo "  selftest ok: $name — arm ($arm) went red"
            printf '%s\n' "$out" | grep "^RED: ($arm)" | head -2 | sed 's/^/      /'
        else
            ST_FAIL=$((ST_FAIL + 1))
            echo "  SELFTEST FAIL: $name — expected arm ($arm) red, got rc=$rc"
            printf '%s\n' "$out" | head -12 | sed 's/^/      /'
        fi
    else
        if [ "$rc" -eq 0 ]; then
            echo "  selftest ok: $name — green as designed"
        else
            ST_FAIL=$((ST_FAIL + 1))
            echo "  SELFTEST FAIL: $name — expected green, got rc=$rc"
            printf '%s\n' "$out" | head -12 | sed 's/^/      /'
        fi
    fi
}

selftest() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/roadmap_check.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT

    # A minimal, WELL-FORMED roadmap: the control. If this is not green, every
    # red below proves nothing (mechanical-gates §19 — sanity-start the mutant).
    cat > "$work/good.md" <<'EOF'
# Roadmap

## Milestones

| # | Milestone | Status | GitHub | DONE when |
| --- | --- | --- | --- | --- |
| 2 | M1 — A thing | active | https://example.invalid/milestone/2 | the thing is done |
| 3 | M2 — Another thing | declared-not-started | https://example.invalid/milestone/3 | the other thing is done |
| — | A vetoed thing | retired | #419 | never |

## Completed

- something that shipped
EOF
    cat > "$work/ms.json" <<'EOF'
[{"number": 2, "state": "open", "title": "M1"},
 {"number": 3, "state": "open", "title": "M2"}]
EOF

    st_case "control: a well-formed table matches its milestones" "-" green \
            "$work/good.md" "$work/ms.json"

    # PLANT 1 (arm a): a stray checkbox line, the exact shape #1207 measured.
    cp "$work/good.md" "$work/checkbox.md"
    printf -- '- [ ] one more thing somebody will count\n' >> "$work/checkbox.md"
    st_case "plant: a stray '- [ ]' line anywhere in the file" "a" red \
            "$work/checkbox.md" "$work/ms.json"

    # PLANT 1b (arm a): the same shape under `## Completed`, indented and with
    # an `[x]` — the 62 rows that made the old count read 92 of 112.
    cp "$work/good.md" "$work/checkbox2.md"
    printf -- '  - [x] a historical highlight wearing a checkbox\n' >> "$work/checkbox2.md"
    st_case "plant: an indented '[x]' under Completed" "a" red \
            "$work/checkbox2.md" "$work/ms.json"

    # PLANT 2 (arm b): the table drops an OPEN milestone.
    grep -v '^| 3 |' "$work/good.md" > "$work/missing.md"
    st_case "plant: the table is missing an open milestone" "b" red \
            "$work/missing.md" "$work/ms.json"

    # PLANT 3 (arm b): the table claims a milestone GitHub does not have open.
    sed 's#^| 3 | M2 — Another thing#| 44 | M44 — A milestone nobody opened#' \
        "$work/good.md" > "$work/extra.md"
    st_case "plant: the table claims a milestone that is not open" "b" red \
            "$work/extra.md" "$work/ms.json"

    # PLANT 4 (arm b): the milestone source comes back EMPTY. Set equality
    # against an empty set is trivially satisfiable, so this must be red, not
    # green (mechanical-gates §121).
    printf '[]\n' > "$work/empty.json"
    st_case "plant: zero open milestones (vacuity)" "b" red \
            "$work/good.md" "$work/empty.json"

    # PLANT 5 (arm a): a SECOND table in the file — the population would stop
    # being "the table".
    cp "$work/good.md" "$work/twotables.md"
    cat >> "$work/twotables.md" <<'EOF'

| Thing | Other |
| --- | --- |
| a | b |
EOF
    st_case "plant: a second table in the file" "a" red \
            "$work/twotables.md" "$work/ms.json"

    # PLANT 6 (arm a): a retired row promoted to an open status keeps no
    # milestone number — an open row without a number must refuse rather than
    # silently leave the comparison set.
    sed 's#^| — | A vetoed thing | retired |#| — | A vetoed thing | active |#' \
        "$work/good.md" > "$work/nonum.md"
    st_case "plant: an open row with no milestone number" "a" red \
            "$work/nonum.md" "$work/ms.json"

    echo ""
    echo "SELFTEST: $ST_RUN case(s) run, $((ST_RUN - ST_FAIL)) passed, $ST_FAIL failed"
    [ "$ST_FAIL" -eq 0 ]
}

case "${1:-}" in
    --selftest) selftest; exit $? ;;
    "") run_live; exit $? ;;
    *) echo "usage: $0 [--selftest]" >&2; exit 2 ;;
esac
