#!/usr/bin/env bash
# roadmap_check.sh — ROADMAP.md is a MILESTONE SET, not a checkbox pile.
#
# WHY THIS EXISTS (measured on main b91768e, 2026-09-21, issue #1207, and
# confirmed by two independent critics before it was written):
# ROADMAP.md was a checkbox pile, most of it HISTORICAL HIGHLIGHTS under
# `## Completed`. The counts are NOT retyped here — ROADMAP.md's own header
# carries them once, each beside the command that derives it from the pre-PR
# file; this comment carrying a second copy is how the first round shipped
# "112" for a file the gate itself counts at 113. Anything counting
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
#       number, AND each open row's DONE cell is the milestone's own DONE
#       text. Runs when `gh` is on PATH and authenticated, or when
#       ROADMAP_CHECK_MILESTONES_JSON names a JSON file (the selftest's seam,
#       and an offline escape hatch). Otherwise it SKIPs BY NAME — never (a).
#
#       The DONE comparison is EQUALITY after whitespace normalisation and a
#       trailing full stop, which is strictly stronger than "the cell is a
#       prefix of the milestone text": a truncation IS a prefix, and a
#       truncation is exactly what happened — round 1 shipped M7's row with
#       "Misleading diagnostics fixed or removed in the same change." missing
#       off the end, and a prefix rule would have called that green.
#
#   (c) every issue/PR reference in the table's cells, plus every
#       repo-qualified reference anywhere in the file (`Tidepool#43`,
#       `ouroboros#231`, `<Repo> PR #N`), RESOLVES to a real issue or PR in
#       the repository it names. Bought the same round: the file credited
#       "Tidepool PR #375" for a change that is EigenScript PR #375, and the
#       Tidepool endpoint 404s. Bare `#N` outside the table is NOT resolved —
#       that is ~50 API calls for the file's prose history — and the arm says
#       so in its own output rather than implying it checked them.
#
# Enumeration discipline (mechanical-gates §121): both arms print
# `examined=N` and refuse when N is 0 or when N != the table size. "Some rows
# were checked" is what a gutted walk also prints.
#
# Usage:
#   bash tools/roadmap_check.sh              # the real ROADMAP.md
#   bash tools/roadmap_check.sh --selftest   # planted faults, each must go red
#   bash tools/roadmap_check.sh --contract   # the population regex and the
#                                            # pinned selftest case count that
#                                            # every CALLER asserts
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
OWNER="${REPO%%/*}"

# The ecosystem repositories a reference may name. A qualified reference to
# anything NOT on this list is red rather than silently skipped: an unknown
# repository name is how "Tidepool PR #375" survived review.
KNOWN_REPOS="${ROADMAP_CHECK_REPOS:-EigenScript ouroboros Tidepool EigenMiniSat EigenOS EigenRegex EigenGauntlet DeslanStudio liferaft tidelog dynamics phugoid polymethod iLambdaAi eigen-sheet eigen-edit eigen-site EigenKB}"

# ---------------------------------------------------------------------------
# THE CONTRACT — the population line this gate promises to print, and how many
# planted faults its selftest runs. Defined ONCE, here, and printed by
# `--contract`, so that every caller (the `[99zd]` suite section) asserts the
# SAME regex this gate prints and the two cannot drift apart.
#
# BOUGHT 2026-09-21 (round-2 blind critic, Astra): removing ONLY the live-data
# walk from this script — leaving its fixture selftest fully intact — was
# accepted by `[99zd]`, which read `TOTAL=4 PASS=4`. A successful exit is not a
# measurement (mechanical-gates §121): the caller must require the POSITIVE
# POPULATION LINE, by regex, and fail by name when it is absent.
POPULATION_RE='^roadmap-check: OK \(examined=[1-9][0-9]* row\(s\), open=[1-9][0-9]*\)$'
SELFTEST_CASES=11

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
TABLE_DONE=""         # "<number><TAB><DONE cell>" per OPEN row, one per line
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
        TABLE_DONE="$TABLE_DONE$num	$done_when
"
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

    local report
    if ! report=$(printf '%s' "$json" | TABLE_DONE="$TABLE_DONE" python3 -c '
import json, os, re, sys
try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("parse: %s\n" % exc)
    sys.exit(2)
if not isinstance(data, list):
    sys.stderr.write("parse: expected a JSON array of milestones\n")
    sys.exit(2)

def norm(s):
    return re.sub(r"\s+", " ", s).strip().rstrip(".").strip()

def done_of(desc):
    out = []
    grab = False
    for ln in (desc or "").replace("\r\n", "\n").split("\n"):
        if ln.startswith("DONE:"):
            grab = True
            out.append(ln[5:])
            continue
        if grab:
            if re.match(r"^[A-Z]{2,}[A-Za-z ]*:", ln):
                break
            out.append(ln)
    return norm(" ".join(out))

rows = {}
for rec in os.environ.get("TABLE_DONE", "").split("\n"):
    if not rec.strip():
        continue
    num, _, cell = rec.partition("\t")
    rows[num.strip()] = norm(cell)

checked = 0
for m in data:
    if m.get("state", "open") != "open":
        continue
    n = str(m["number"])
    print("NUM %s" % n)
    if n not in rows:
        continue
    api = done_of(m.get("description", ""))
    if not api:
        print("BAD %s: the GitHub milestone description carries no DONE: clause for the row to mirror" % n)
        continue
    checked += 1
    row = rows[n]
    if row == api:
        continue
    if api.startswith(row):
        print("BAD %s: the DONE cell TRUNCATES the milestone - the row stops at ...%s | the milestone continues: %s" % (n, row[-50:], api[len(row):][:160]))
    else:
        print("BAD %s: the DONE cell is not the milestone DONE text | row: %s | milestone: %s" % (n, row[:140], api[:140]))
print("CHECKED %d" % checked)
'); then
        red "(b) could not read the milestone list from $src"
        return
    fi

    local gh_numbers done_checked
    gh_numbers=$(printf '%s\n' "$report" | sed -n 's/^NUM //p')
    done_checked=$(printf '%s\n' "$report" | sed -n 's/^CHECKED //p' | tail -1)

    # The DONE clause of every open row, compared with the milestone's own
    # DONE text. Round 1 shipped M7 with half its clause missing; the table is
    # a MIRROR, so a row that paraphrases or truncates is a drifted mirror.
    local bad
    while IFS= read -r bad; do
        [ -z "$bad" ] && continue
        red "(b) milestone $bad"
    done <<< "$(printf '%s\n' "$report" | sed -n 's/^BAD //p')"

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
    if [ -z "$(printf '%s%s' "$missing" "$extra" | tr -d ' ')" ] && [ "${done_checked:-0}" -ne "$TABLE_OPEN_ROWS" ]; then
        red "(b) the DONE comparison examined ${done_checked:-0} of $TABLE_OPEN_ROWS open row(s) — a comparison that skips rows is not a comparison (mechanical-gates §121)"
    fi
    echo "      (b) milestones: examined=$TABLE_OPEN_ROWS open row(s) vs $gh_count open milestone(s) from $src, done_clauses=${done_checked:-0}"
}

# ---------------------------------------------------------------------------
# (c) Every reference the table offers as EVIDENCE resolves.
# ---------------------------------------------------------------------------
# Bought 2026-09-21 (round 1, both critics): the file credited
# "Tidepool PR #375" for a change that is EigenScript PR #375 — the Tidepool
# endpoint 404s. A correction whose evidence does not exist is not a
# correction. Resolved here: every `#N` in a table cell (default repository
# `$REPO`), plus every repo-qualified reference anywhere in the file, attached
# (`Tidepool#43`) or in prose (`<Repo> PR #N`). NOT resolved: bare `#N` in the
# file`s prose history — roughly fifty API calls for the same answer — and
# this arm prints that limit rather than implying it checked them.
check_references() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "      (c) SKIPPED BY NAME: python3 is not on PATH, so references cannot be extracted. Arm (a) still ran."
        return
    fi
    local fixture="${ROADMAP_CHECK_REFS_FIXTURE:-}" src
    if [ -n "$fixture" ]; then
        if [ ! -f "$fixture" ]; then
            red "(c) ROADMAP_CHECK_REFS_FIXTURE names no file: $fixture"
            return
        fi
        src="fixture $fixture"
    else
        if ! command -v gh >/dev/null 2>&1; then
            echo "      (c) SKIPPED BY NAME: gh is not on PATH, so the table's references cannot be resolved. Arm (a) still ran."
            return
        fi
        src="gh api repos/<repo>/issues/<n>"
    fi

    local out
    if ! out=$(RC_KNOWN_REPOS="$KNOWN_REPOS" RC_DEFAULT_REPO="${REPO##*/}" \
               python3 -c '
import os, re, sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except Exception as exc:
    sys.stderr.write("refs: cannot read %s: %s\n" % (path, exc))
    sys.exit(2)

known = set(os.environ.get("RC_KNOWN_REPOS", "").split())
default = os.environ.get("RC_DEFAULT_REPO", "")
REF = re.compile(r"([A-Za-z][A-Za-z0-9_.-]*)?#([0-9]+)")
PROSE = re.compile(r"([A-Za-z][A-Za-z0-9_.-]*) +(?:PR|pull request|issue|issues) +#([0-9]+)")

seen = []
def add(repo, num, why):
    for r, n, w in seen:
        if r == repo and n == num:
            return
    seen.append((repo, num, why))

# 1. every reference in a TABLE cell (the evidence cells of the milestone set)
for ln in text.split("\n"):
    if not ln.startswith("|"):
        continue
    if re.match(r"^\|[\s:|-]+\|[\s:|-]*$", ln):
        continue
    for m in REF.finditer(ln):
        q = m.group(1)
        if q is None:
            add(default, m.group(2), "table")
        elif q in known:
            add(q, m.group(2), "table")
        else:
            print("UNKNOWN %s#%s names no known repository" % (q, m.group(2)))

# 2. every REPO-QUALIFIED reference anywhere in the file, attached or in prose.
#    Whitespace is normalised first: the reference this arm was bought for
#    (Tidepool PR #375) straddled a line break.
norm = re.sub(r"\s+", " ", text)
for m in REF.finditer(norm):
    q = m.group(1)
    if q is not None and q in known:
        add(q, m.group(2), "qualified")
for m in PROSE.finditer(norm):
    if m.group(1) in known:
        add(m.group(1), m.group(2), "prose")

for r, n, w in seen:
    print("REF %s %s %s" % (r, n, w))
print("TOTAL %d" % len(seen))
' "$RC_FILE"); then
        red "(c) could not extract the references from $RC_FILE"
        return
    fi

    local line unknown_n=0
    while IFS= read -r line; do
        case "$line" in
            UNKNOWN\ *) red "(c) ${line#UNKNOWN } — a qualified reference must name a repository this gate knows (KNOWN_REPOS)"; unknown_n=$((unknown_n + 1)) ;;
        esac
    done <<< "$out"

    local total resolved=0 examined=0 repo num why full
    total=$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p' | tail -1)
    if [ "${total:-0}" -eq 0 ]; then
        red "(c) the milestone table offers ZERO references as evidence — an empty reference set resolves trivially (mechanical-gates §121)"
        return
    fi

    while IFS= read -r line; do
        case "$line" in
            REF\ *) ;;
            *) continue ;;
        esac
        set -- $line
        repo="$2"; num="$3"; why="$4"
        examined=$((examined + 1))
        full="$OWNER/$repo"
        if [ -n "$fixture" ]; then
            # An exact-line fixture: anything not listed does not exist.
            if [[ $'\n'"$(cat "$fixture")"$'\n' == *$'\n'"$full#$num"$'\n'* ]]; then
                resolved=$((resolved + 1))
            else
                red "(c) $full#$num ($why) does not exist — the reference is evidence for a claim in $RC_FILE"
            fi
            continue
        fi
        if gh api "repos/$full/issues/$num" --jq .number >/dev/null 2>&1; then
            resolved=$((resolved + 1))
        else
            red "(c) $full#$num ($why) does not resolve — $RC_FILE offers it as evidence, and the endpoint 404s"
        fi
    done <<< "$out"

    if [ "$examined" -ne "${total:-0}" ]; then
        red "(c) extracted ${total:-0} reference(s) but walked $examined — the reference walk lost rows"
        return
    fi
    if [ "$resolved" -ne "$examined" ] || [ "$unknown_n" -ne 0 ]; then
        return
    fi
    echo "      (c) references: examined=$examined, refs=$resolved resolved (source: $src); bare #N outside the table is NOT resolved, by design"
}

run_live() {
    echo "roadmap-check env: file=$RC_FILE repo=$REPO gh=$(command -v gh >/dev/null 2>&1 && echo present || echo absent)"
    check_structure
    check_milestones
    check_references
    if [ "$RED" -ne 0 ]; then
        echo "roadmap-check: $RED problem(s)"
        return 1
    fi
    local ok_line="roadmap-check: OK (examined=$TABLE_ROWS row(s), open=$TABLE_OPEN_ROWS)"
    echo "$ok_line"
    # The gate proves its OWN output satisfies the contract it publishes, so
    # that rewording this line without updating POPULATION_RE goes red here
    # rather than leaving every caller asserting a regex nothing can match.
    if ! [[ $ok_line =~ $POPULATION_RE ]]; then
        echo "RED: (a) the population line does not match this gate's own published contract"
        echo "      line:     $ok_line"
        echo "      contract: $POPULATION_RE"
        return 1
    fi
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

The gap this file used to call open is closed — EigenScript PR #375.

## Milestones

| # | Milestone | Status | GitHub | DONE when |
| --- | --- | --- | --- | --- |
| 2 | M1 — A thing | active | https://example.invalid/milestone/2 | the thing is done and EigenScript PR #375 is merged |
| 3 | M2 — Another thing | declared-not-started | https://example.invalid/milestone/3 | the other thing is done. And the second sentence is half the clause |
| — | A vetoed thing | retired | #419 | never |

## Completed

- something that shipped
EOF
    cat > "$work/ms.json" <<'EOF'
[{"number": 2, "state": "open", "title": "M1",
  "description": "BAR: something\nDONE: the thing is done and EigenScript PR #375 is merged.\n"},
 {"number": 3, "state": "open", "title": "M2",
  "description": "DONE: the other thing is done. And the second sentence is half the clause.\nSTATUS: deliberately open and not yet started.\n"}]
EOF
    # Arm (c)'s offline seam: the references that EXIST. Anything a fixture run
    # asks about and does not find here does not exist, which is what makes the
    # 404 plants below deterministic and network-free.
    cat > "$work/refs.txt" <<'EOF'
InauguralSystems/EigenScript#375
InauguralSystems/EigenScript#419
EOF
    export ROADMAP_CHECK_REFS_FIXTURE="$work/refs.txt"

    st_case "control: a well-formed table matches its milestones" "-" green \
            "$work/good.md" "$work/ms.json"

    # PLANT 1 (arm a): a stray checkbox line, the exact shape #1207 measured.
    cp "$work/good.md" "$work/checkbox.md"
    printf -- '- [ ] one more thing somebody will count\n' >> "$work/checkbox.md"
    st_case "plant: a stray '- [ ]' line anywhere in the file" "a" red \
            "$work/checkbox.md" "$work/ms.json"

    # PLANT 1b (arm a): the same shape under `## Completed`, indented and with
    # an `[x]` — the shape of the historical rows that used to be counted.
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

    # PLANT 7 (arm b): the DONE cell keeps its first sentence and drops the
    # rest — exactly what round 1 shipped for M7, and exactly what a
    # "the cell is a PREFIX of the milestone text" rule would have called
    # green. The comparison is equality, so a truncation is red.
    sed 's%| the other thing is done. And the second sentence is half the clause |%| the other thing is done |%' \
        "$work/good.md" > "$work/truncated.md"
    st_case "plant: a DONE cell truncated to its first sentence" "b" red \
            "$work/truncated.md" "$work/ms.json"

    # PLANT 8 (arm c): a row citing a PR that does not exist.
    sed 's%| retired | #419 |%| retired | PR #999999 |%' \
        "$work/good.md" > "$work/badref.md"
    st_case "plant: a table row citing PR #999999" "c" red \
            "$work/badref.md" "$work/ms.json"

    # PLANT 9 (arm c): the reference resolves — in the WRONG repository. This
    # is the 2026-09-21 defect itself: "Tidepool PR #375" for a change that is
    # EigenScript PR #375, straddling a line break in the prose.
    sed 's%closed — EigenScript PR #375.%closed — Tidepool PR #375.%' \
        "$work/good.md" > "$work/wrongrepo.md"
    st_case "plant: a prose reference attributed to the wrong repository" "c" red \
            "$work/wrongrepo.md" "$work/ms.json"

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
