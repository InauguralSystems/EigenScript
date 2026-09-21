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
# WHAT A CALLER OF THIS GATE CAN AND CANNOT PROVE. A caller ([99zd] in
# tests/run_all_tests.sh, the audit in .github/workflows/issue-triage.yml)
# verifies that this gate printed a population line it could only have produced
# by running its live arm ON THAT LANE — the source token is pinned to
# `gh-api:` and `skipped=0` whenever the CALLER'S OWN probe (tools/gh_probe.sh)
# can reach GitHub — and that this gate's selftest ran with the pinned case
# count. A gate that FABRICATES its own output — printing the population line
# and the selftest line without doing the work — is outside any caller's power
# to detect: a forged receipt reads exactly like a true one. That is what the
# blind-critic rounds and this selftest's transverse mutations are for, and it
# is stated here so nobody mistakes a pinned regex for a proof of work.
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

# The `gh` reachability probe lives in ONE file, sourced by this gate AND by
# its callers ([99zd] in tests/run_all_tests.sh, the daily audit in
# .github/workflows/issue-triage.yml). Round 3 let this gate decide alone
# whether GitHub was reachable, and the callers believed the answer: a gate
# whose probe always said "no" passed on an authenticated box (round-4 blind
# critic, Fable). Two readers of one probe cannot disagree.
# shellcheck source=gh_probe.sh
. "$ROOT/tools/gh_probe.sh"

# This gate never reads stdin: a `grep -c` whose stdin is an open pipe hangs
# the whole check, and one whose stdin is /dev/null counts 0 and passes a
# vacuity guard built on it (the failure tools/docs_claims_check.sh bought on
# 2026-09-18). There is nothing here to block on.
exec 0</dev/null

RC_FILE="${ROADMAP_CHECK_FILE:-$ROOT/ROADMAP.md}"
REPO="${ROADMAP_CHECK_REPO:-InauguralSystems/EigenScript}"
OWNER="${REPO%%/*}"

# The ecosystem repositories a reference may name AS EVIDENCE. A qualified
# reference to anything NOT on this list (or PRIVATE_REPOS below) is red rather
# than silently skipped: an unknown repository name is how "Tidepool PR #375"
# survived review.
#
# THE LIST IS DATA, AND DATA GOES STALE. Bought 2026-09-21 (round-5 blind
# critic, Fable): `EigenKB` was on this list and NO SUCH REPOSITORY EXISTS.
# `repos/InauguralSystems/EigenKB` is a 404 for every token including the
# org's most privileged one, and the walk below mapped a repository-level 404
# to "this token cannot read the repository at all" — a statement about the
# run — so `EigenKB#1` in the roadmap SKIPPED BY NAME and the gate printed OK.
# A membership list nothing verifies certifies whatever is typed into it. So
# the list is now VERIFIED ONCE PER RUN against the org's own repository
# listing (verify_known_repos below), and `EigenKB` is gone.
#
# EigenOS, eigen-site, DeslanStudio and iLambdaAi are gone from this list too,
# for a different reason: they are PRIVATE (measured 2026-09-21, `.private` is
# true on all four). ROADMAP.md is a PUBLIC document, and a public document
# cannot cite a repository its readers cannot open — "see EigenOS#42" is not
# evidence, it is a note to the four people with access. They keep their names
# in PRIVATE_REPOS so that citing one is red BY ITS REAL REASON rather than
# red as an unrecognised name.
KNOWN_REPOS="${ROADMAP_CHECK_REPOS:-EigenScript ouroboros Tidepool EigenMiniSat EigenRegex EigenGauntlet liferaft tidelog dynamics phugoid polymethod eigen-sheet eigen-edit}"

# Repositories of this organisation that EXIST and are PRIVATE. They are
# "known" to the extractor — a reference naming one is recognised — and then
# refused by name at resolution time. Verified once per run in the other
# direction: an entry that has become PUBLIC is red, because the list would
# then be refusing a citation that is now perfectly good evidence.
PRIVATE_REPOS="${ROADMAP_CHECK_PRIVATE_REPOS:-EigenOS eigen-site DeslanStudio iLambdaAi}"

# The OWNERS a reference may name. An explicit owner is part of the identity of
# a reference (`cli/Tidepool#59` is not `InauguralSystems/Tidepool#59`), so one
# outside this set is red by name rather than replaced by the default — which
# is how a reference to a repository that does not exist was certified by
# resolving a different organisation's (round-4 blind critic, Astra).
KNOWN_OWNERS="${ROADMAP_CHECK_OWNERS:-$OWNER}"

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
#
# ROUND 3 (blind critic Fable): the callers also accepted a FIXTURE-sourced
# "live" run — `examined=1 missing=0 (source: fixture ...)` passed, because the
# caller's regex stopped before `(source:`. The OK line therefore NAMES its
# sources in machine-readable tokens (`gh-api:`, `fixture:`, `skipped:`) and
# the contract requires a non-fixture one, so a run driven by the selftest seam
# is red at the caller by name.
#
# ROUND 4 (blind critics Fable and Astra): `refs=gh-api:…` named the ENDPOINT
# the arm intended to call, not work done — with every per-reference call
# answering HTTP 403 the arm reported `refs=0 resolved, skipped=7` and the OK
# line was byte-identical to a run that resolved all seven. The line now
# carries the walk's OWN counts, `resolved=N skipped=M`, so a caller that can
# reach GitHub can require `skipped=0` (a 403 storm on an authenticated lane is
# red, not a pass). The contract still ADMITS a named skip, because a lane with
# no credentials legitimately prints one; it is the CALLER that refuses a skip
# on a lane where it has established for itself that GitHub is reachable.
POPULATION_RE='^roadmap-check: OK \(examined=[1-9][0-9]* row\(s\), open=[1-9][0-9]*\) \(source: milestones=(gh-api|skipped):[^ ]+ refs=(gh-api|skipped):[^ ]+ resolved=[0-9]+ skipped=[0-9]+\)$'
SELFTEST_CASES=21

# What arms (b) and (c) actually used this run. One of
#   gh-api:<endpoint>   fixture:<path>   skipped:<reason>
SRC_MILESTONES="skipped:not-reached"
SRC_REFS="skipped:not-reached"
# What arm (c) actually DID: how many references it resolved and how many it
# had to skip by name (401/403/429, a transport error, or a repository this
# token cannot read). Printed on the OK line, because the source token alone
# says nothing about work done.
REF_RESOLVED=0
REF_SKIPPED=0

RED=0
red() { echo "RED: $*"; RED=$((RED + 1)); }
note() { echo "      $*"; }

# Trim leading/trailing spaces and tabs.
trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# Split a markdown table row into ROW_CELLS.
#
# BOUGHT 2026-09-21 (round-3 blind critic, Astra check 3): the first cut split
# with `awk -F'|'`, so a cell containing a LEGAL escaped pipe (`\|`, the only
# way to put a pipe inside a markdown cell) was counted as two cells and the
# row was red for having 6. An escaped pipe is CONTENT. It is swapped for a
# control character before the split and swapped back inside each cell, with
# bash parameter expansion rather than sed: `\x01` in a sed replacement is a
# GNU extension the macOS lane does not have.
ROW_CELLS=()
split_row() {
    local line="$1" esc field
    ROW_CELLS=()
    esc="${line//\\|/$'\001'}"
    esc="${esc#|}"
    esc="${esc%|}"
    esc="$esc|"
    while [ -n "$esc" ]; do
        field="${esc%%|*}"
        esc="${esc#*|}"
        field="${field//$'\001'/|}"
        field=$(trim_ws "$field")
        ROW_CELLS[${#ROW_CELLS[@]}]="$field"
    done
}

# A status word that is NOT compared against GitHub. Everything else is an
# "open row" and must have a milestone number.
is_closed_status() {
    case "$1" in
        retired|completed) return 0 ;;
        *) return 1 ;;
    esac
}
# AUTHENTICATED, not merely installed — see tools/gh_probe.sh for why
# `gh auth status` alone is not the probe. Both arms use this, AND so does
# every caller, so a gate and its caller cannot disagree about which of the
# three states — no gh, gh without credentials, gh with working credentials —
# this runner is in.
gh_authenticated() {
    gh_probe_authenticated
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
        # Split on UNESCAPED '|' — `\|` is a legal escaped pipe inside a cell.
        split_row "$line"
        num="${ROW_CELLS[0]:-}"
        title="${ROW_CELLS[1]:-}"
        status="${ROW_CELLS[2]:-}"
        url="${ROW_CELLS[3]:-}"
        done_when="${ROW_CELLS[4]:-}"
        local ncells
        ncells=${#ROW_CELLS[@]}
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
        SRC_MILESTONES="skipped:no-python3"
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
        SRC_MILESTONES="fixture:$ROADMAP_CHECK_MILESTONES_JSON"
    else
        if ! command -v gh >/dev/null 2>&1; then
            SRC_MILESTONES="skipped:no-gh"
            echo "      (b) SKIPPED BY NAME: gh is not on PATH, so the table cannot be compared with the GitHub milestone set. Arm (a) still ran."
            return
        fi
        # AUTHENTICATION IS A DISTINCT STATE FROM `gh` BEING INSTALLED.
        # Bought 2026-09-21 (round-3 blind critic, Fable; CI run 35599371704):
        # the macOS runner HAS `gh` and no credentials, so every call failed —
        # arm (b) skipped but arm (c) called all seven failures "404s" and took
        # the whole macOS leg red. Auth is checked ONCE, by name, up front.
        if ! gh_authenticated; then
            SRC_MILESTONES="skipped:gh-unauthenticated"
            echo "      (b) SKIPPED BY NAME: gh is on PATH but has no working credentials (gh auth status fails, or an authenticated probe call does), so the milestone set cannot be read. Arm (a) still ran."
            return
        fi
        if ! json=$(gh api "repos/$REPO/milestones?state=open&per_page=100" 2>/dev/null); then
            SRC_MILESTONES="skipped:gh-api-failed"
            echo "      (b) SKIPPED BY NAME: gh is authenticated but the milestone API call failed (offline, rate-limited, or the repository is unreadable). Arm (a) still ran."
            return
        fi
        src="gh api repos/$REPO/milestones"
        SRC_MILESTONES="gh-api:repos/$REPO/milestones"
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
# ---------------------------------------------------------------------------
# KNOWN_REPOS IS DATA, AND IT IS VERIFIED ONCE PER RUN.
#
# BOUGHT 2026-09-21 (round-5 blind critic, Fable). `EigenKB` sat in
# KNOWN_REPOS and no such repository exists. Arm (c) probed
# `repos/<owner>/<repo>` per referenced repository and mapped the 404 to "this
# token cannot read the repository at all" — a fact about the RUN — so a
# roadmap citing `EigenKB#1` printed `OK … skipped=1`. The mapping was written
# for a private repository and could not tell one from a repository that is
# not there, on the org's most privileged token.
#
# THE DISCRIMINATOR IS THE ORGANISATION LISTING. One call (`gh api
# orgs/<owner>/repos`, ~31 rows here, one page) answers existence AND privacy
# for every name at once, and its success is what makes a 404 meaningful:
#   * listing succeeds, name absent      -> the repository DOES NOT EXIST
#   * listing succeeds, name present     -> exists; `.private` says which list
#                                           it belongs on
#   * listing fails or comes back empty  -> this token cannot see the org, so
#                                           nothing here is decidable: SKIP BY
#                                           NAME (never a silent pass)
# A repo-scoped `${{ github.token }}` sees only the org's PUBLIC repositories,
# so for a PRIVATE_REPOS entry "absent" and "private" are the same answer and
# both are fine; a PRIVATE_REPOS entry that shows up PUBLIC is the stale
# direction and is red.
#
# ROADMAP.md IS A PUBLIC DOCUMENT. A citation its readers cannot open is not
# evidence, so a reference into a private repository is red BY NAME rather
# than skipped — which is what round 4 did with `EigenOS#N` and
# `eigen-site#N`, both of which resolve on the maintainer's token and would
# have been `skipped=1` (and therefore RED at the token-holding caller, for
# the wrong reason) under `${{ github.token }}`.
# ---------------------------------------------------------------------------
REPO_STATE_PUBLIC=" "
REPO_STATE_PRIVATE=" "
REPO_STATE_MISSING=" "
REPOS_VERIFIED=0

# The organisation's repositories, one `<name> <private-bool>` per line on
# stdout. rc 1 when the org cannot be listed at all. The fixture seam keeps the
# selftest offline; a fixture holding the single word UNLISTABLE is how the
# selftest drives the "cannot see the org" branch.
org_listing() {
    local fx="${ROADMAP_CHECK_ORG_FIXTURE:-}"
    if [ -n "$fx" ]; then
        [ -f "$fx" ] || return 1
        if grep -qx 'UNLISTABLE' "$fx"; then
            return 1
        fi
        grep -v '^UNLISTABLE$' "$fx"
        return 0
    fi
    gh api "orgs/$OWNER/repos?per_page=100" --paginate \
           --jq '.[] | .name + " " + (.private|tostring)' 2>/dev/null
}

verify_known_repos() {
    local listing rc entry name priv
    local org_public=" " org_private=" "
    local listed=0 pub=0 prv=0
    listing=$(org_listing)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$listing" ]; then
        echo "      (c) SKIPPED BY NAME: KNOWN_REPOS could not be verified — the $OWNER repository listing (${ROADMAP_CHECK_ORG_FIXTURE:-gh api orgs/$OWNER/repos}) failed or came back empty on this lane, so a 404 on a repository is a fact about this token and not about the repository. The reference walk below still runs."
        return 0
    fi
    # A here-string, never a pipe: under bash 3.2 a `printf | reader` that
    # exits early makes the shell's own printf take SIGPIPE and print
    # `write error: Broken pipe` (the failure tools/docs_claims_check.sh
    # bought on macOS).
    while read -r name priv; do
        [ -n "${name:-}" ] || continue
        listed=$((listed + 1))
        if [ "${priv:-}" = "true" ]; then
            org_private="$org_private$name "
        else
            org_public="$org_public$name "
        fi
    done <<< "$listing"

    for entry in $KNOWN_REPOS; do
        case "$org_public" in
            *" $entry "*)
                REPO_STATE_PUBLIC="$REPO_STATE_PUBLIC$OWNER/$entry "
                pub=$((pub + 1))
                continue ;;
        esac
        case "$org_private" in
            *" $entry "*)
                REPO_STATE_PRIVATE="$REPO_STATE_PRIVATE$OWNER/$entry "
                red "(c) KNOWN_REPOS names $OWNER/$entry and the organisation listing says it is PRIVATE — a private repository is not evidence in a public roadmap; move it to PRIVATE_REPOS"
                continue ;;
        esac
        REPO_STATE_MISSING="$REPO_STATE_MISSING$OWNER/$entry "
        red "(c) repository $OWNER/$entry does not exist (KNOWN_REPOS is stale) — the $OWNER listing succeeded with $listed repositories and does not contain it, so this is a fact about the repository and not about the token. A membership list nothing verifies certifies whatever is typed into it"
    done

    for entry in $PRIVATE_REPOS; do
        case "$org_public" in
            *" $entry "*)
                REPO_STATE_PUBLIC="$REPO_STATE_PUBLIC$OWNER/$entry "
                pub=$((pub + 1))
                red "(c) PRIVATE_REPOS names $OWNER/$entry and the organisation listing says it is PUBLIC — move it to KNOWN_REPOS; this gate is refusing a citation that is now perfectly good evidence"
                continue ;;
        esac
        # Absent is indistinguishable from private under a repo-scoped token,
        # and both mean the same thing here: not citable in a public document.
        REPO_STATE_PRIVATE="$REPO_STATE_PRIVATE$OWNER/$entry "
        prv=$((prv + 1))
    done
    REPOS_VERIFIED=1
    echo "      (c) KNOWN_REPOS verified against the $OWNER listing ($listed repositories): $pub public citable, $prv private and not citable in a public document"
}

check_references() {
    if ! command -v python3 >/dev/null 2>&1; then
        SRC_REFS="skipped:no-python3"
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
        SRC_REFS="fixture:$fixture"
    else
        if ! command -v gh >/dev/null 2>&1; then
            SRC_REFS="skipped:no-gh"
            echo "      (c) SKIPPED BY NAME: gh is not on PATH, so the table's references cannot be resolved. Arm (a) still ran."
            return
        fi
        # `gh` INSTALLED IS NOT `gh` AUTHENTICATED. Bought 2026-09-21 (round-3
        # blind critic, Fable; CI run 35599371704): the macOS runner has `gh`
        # and no credentials, so every `gh api` failed and this arm reported
        # all seven references as "does not resolve — the endpoint 404s",
        # taking the macOS leg red on a tree whose references are all fine.
        # An unauthenticated 404 is not evidence about the reference.
        if ! gh_authenticated; then
            SRC_REFS="skipped:gh-unauthenticated"
            echo "      (c) SKIPPED BY NAME: gh is on PATH but has no working credentials, so nothing can be resolved — an unauthenticated 404 says nothing about whether the reference exists. Arm (a) still ran."
            return
        fi
        src="gh api repos/<owner>/<repo>/issues/<n>"
        SRC_REFS="gh-api:repos/<owner>/*/issues"
    fi

    # ONCE PER RUN, before a single reference is resolved: is the list this
    # arm measures against still true? Live, or driven by the org fixture in
    # the selftest; a pure refs-fixture run has no organisation to ask.
    if [ -z "$fixture" ] || [ -n "${ROADMAP_CHECK_ORG_FIXTURE:-}" ]; then
        verify_known_repos
    fi

    local out
    if ! out=$(RC_KNOWN_REPOS="$KNOWN_REPOS $PRIVATE_REPOS" RC_DEFAULT_REPO="${REPO##*/}" \
               RC_KNOWN_OWNERS="$KNOWN_OWNERS" RC_DEFAULT_OWNER="$OWNER" \
               python3 -c '
import os, re, sys

path = sys.argv[1]
try:
    text = open(path, encoding="utf-8").read()
except Exception as exc:
    sys.stderr.write("refs: cannot read %s: %s\n" % (path, exc))
    sys.exit(2)

known = set(os.environ.get("RC_KNOWN_REPOS", "").split())
owners = set(os.environ.get("RC_KNOWN_OWNERS", "").split())
default = os.environ.get("RC_DEFAULT_REPO", "")
default_owner = os.environ.get("RC_DEFAULT_OWNER", "")

# AN EXPLICIT OWNER IS PART OF THE IDENTITY.
# BOUGHT 2026-09-21 (round-4 blind critic, Astra): this pattern used to be
# `([A-Za-z][A-Za-z0-9_.-]*)?#([0-9]+)`, which captured only the REPOSITORY
# half. `cli/Tidepool#59` therefore extracted as `Tidepool#59`, deduplicated
# against the `InauguralSystems/Tidepool#59` already in the population, and the
# owner was reconstructed from this gate default at lookup time — so a
# reference to a repository that does not exist was certified by resolving a
# DIFFERENT one. The owner is now captured, carried through deduplication, and
# an owner outside the known set is red BY NAME rather than replaced.
REF = re.compile(r"(?:([A-Za-z0-9][A-Za-z0-9-]*)/)?([A-Za-z][A-Za-z0-9_.-]*)?#([0-9]+)")
PROSE = re.compile(r"(?:([A-Za-z0-9][A-Za-z0-9-]*)/)?([A-Za-z][A-Za-z0-9_.-]*) +(?:PR|pull request|issue|issues) +#([0-9]+)")

seen = []
def add(owner, repo, num, why):
    # The key is the FULL TRIPLE. Two owners of the same repo#N are two
    # different references and must both be resolved.
    for o, r, n, w in seen:
        if o == owner and r == repo and n == num:
            return
    seen.append((owner, repo, num, why))

unknown = []
def unknown_add(msg):
    if msg not in unknown:
        unknown.append(msg)

bad_owner = []
def bad_owner_add(msg):
    if msg not in bad_owner:
        bad_owner.append(msg)

ambiguous = []
def ambiguous_add(msg):
    if msg not in ambiguous:
        ambiguous.append(msg)

def classify(owner, repo, num, why):
    # An owner with no repository half (`.../#5`) is punctuation, not an
    # owner: fall back to the bare-reference rule rather than accusing.
    if repo is None:
        return ("bare", None)
    if owner is not None and owner not in owners:
        bad_owner_add("%s/%s#%s (%s)" % (owner, repo, num, why))
        return ("bad-owner", None)
    if repo not in known:
        unknown_add("%s#%s (%s)" % (repo, num, why))
        return ("unknown-repo", None)
    add(owner or default_owner, repo, num, why)
    return ("ok", None)

def cells_of(line):
    # the SAME split rule the structure arm uses: `\|` is content.
    body = line.replace("\\|", "\x01").strip()
    body = body[1:] if body.startswith("|") else body
    body = body[:-1] if body.endswith("|") else body
    return [c.replace("\x01", "|") for c in body.split("|")]

# 1. every reference in a TABLE cell (the evidence cells of the milestone set)
for ln in text.split("\n"):
    if not ln.startswith("|"):
        continue
    if re.match(r"^\|[\s:|-]+\|[\s:|-]*$", ln):
        continue
    for cell in cells_of(ln):
        qualified = [m for m in REF.finditer(cell)
                     if m.group(2) is not None and m.group(2) in known]
        for m in REF.finditer(cell):
            owner, repo, num = m.group(1), m.group(2), m.group(3)
            if repo is None:
                if qualified:
                    # BOUGHT 2026-09-21 (round-3 blind critic, Fable): M9 read
                    # "Tidepool#43 and #59 closed". The bare #59 silently became
                    # EigenScript#59 (a closed 2026 PR about the self-hosted
                    # parser) and RESOLVED, so the row was green for a reference
                    # it does not mean. A bare number beside a qualified one is
                    # ambiguous; the gate refuses it instead of guessing.
                    ambiguous_add("bare #%s beside %s#%s — a bare number defaults to %s, and this cell names another repository; qualify it"
                                  % (num, qualified[0].group(2), qualified[0].group(3), default))
                    continue
                add(default_owner, default, num, "table")
                continue
            classify(owner, repo, num, "table")

# 2. every REPO-QUALIFIED reference anywhere in the file, attached or in prose.
#    Whitespace is normalised first: the reference this arm was bought for
#    (Tidepool PR #375) straddled a line break. A qualifier that names NO known
#    repository is red wherever it appears — round 2 ignored it in prose and
#    only caught it in a table, which is how a wrong-repo credit survives in
#    the sentence that explains the row.
norm = re.sub(r"\s+", " ", text)
for m in REF.finditer(norm):
    owner, repo, num = m.group(1), m.group(2), m.group(3)
    if repo is None:
        continue
    classify(owner, repo, num, "qualified")
# The SPACED prose form (`Tidepool PR #375`) is only RESOLVED, never accused
# for its REPOSITORY half: that left word is an ordinary English word most of
# the time ("whose PR #375"), so an unknown one there is not evidence of
# anything. An explicit OWNER is different — nobody writes `word/word PR #12`
# by accident — so `cli/Tidepool PR #59` is accused like the attached form.
for m in PROSE.finditer(norm):
    owner, repo, num = m.group(1), m.group(2), m.group(3)
    if owner is not None and owner not in owners:
        bad_owner_add("%s/%s#%s (prose)" % (owner, repo, num))
        continue
    if repo in known:
        add(owner or default_owner, repo, num, "prose")

for msg in ambiguous:
    print("AMBIGUOUS %s" % msg)
for msg in bad_owner:
    print("BADOWNER %s" % msg)
for msg in unknown:
    print("UNKNOWN %s" % msg)
for o, r, n, w in seen:
    print("REF %s %s %s %s" % (o, r, n, w))
print("TOTAL %d" % len(seen))
' "$RC_FILE"); then
        red "(c) could not extract the references from $RC_FILE"
        return
    fi

    local line unknown_n=0 ambiguous_n=0 badowner_n=0
    while IFS= read -r line; do
        case "$line" in
            AMBIGUOUS\ *) red "(c) ${line#AMBIGUOUS } — $RC_FILE"; ambiguous_n=$((ambiguous_n + 1)) ;;
            BADOWNER\ *) red "(c) ${line#BADOWNER } names an owner this gate does not know — owner '$(o="${line#BADOWNER }"; o="${o%%/*}"; printf '%s' "$o")' is not this gate's organisation (KNOWN_OWNERS: $KNOWN_OWNERS). An explicit owner is part of the reference's identity and is never replaced by the default"; badowner_n=$((badowner_n + 1)) ;;
            UNKNOWN\ *) red "(c) ${line#UNKNOWN } names no repository this gate knows (KNOWN_REPOS or PRIVATE_REPOS) — a qualified reference must name one, and both lists are verified against the $OWNER listing once per run"; unknown_n=$((unknown_n + 1)) ;;
        esac
    done <<< "$out"

    local total resolved=0 examined=0 skipped=0 owner repo num why full err rc status
    total=$(printf '%s\n' "$out" | sed -n 's/^TOTAL //p' | tail -1)
    if [ "${total:-0}" -eq 0 ]; then
        red "(c) the milestone table offers ZERO references as evidence — an empty reference set resolves trivially (mechanical-gates §121)"
        return
    fi

    # A 404 on an issue in a repository this token CANNOT READ AT ALL is a fact
    # about the token, not about the reference — and reporting it as "the
    # reference does not exist" is the same false accusation arm (c) exists to
    # prevent, pointed the other way. The repository itself is probed once per
    # distinct owner/repo; a repository that cannot be read makes its references
    # SKIP BY NAME and lands in `skipped=`, which an authenticated caller
    # refuses. Never a silent pass.
    local readable_ok=" " readable_bad=" "
    repo_readable() { # <owner>/<repo>
        case "$readable_ok" in *" $1 "*) return 0 ;; esac
        case "$readable_bad" in *" $1 "*) return 1 ;; esac
        if gh api "repos/$1" --jq .full_name >/dev/null 2>&1; then
            readable_ok="$readable_ok$1 "
            return 0
        fi
        readable_bad="$readable_bad$1 "
        return 1
    }

    while IFS= read -r line; do
        case "$line" in
            REF\ *) ;;
            *) continue ;;
        esac
        set -- $line
        owner="$2"; repo="$3"; num="$4"; why="$5"
        examined=$((examined + 1))
        full="$owner/$repo"
        # THE VERIFIED STATE COMES FIRST. A repository-level 404 is only
        # "this token cannot read it" once the organisation listing has been
        # asked; when it HAS been asked, "does not exist" and "private" are
        # separate, named verdicts and neither is a skip.
        if [ "$REPOS_VERIFIED" -eq 1 ]; then
            case "$REPO_STATE_PRIVATE" in
                *" $full "*)
                    red "(c) $full#$num ($why) cites a PRIVATE repository — a private repository is not evidence in a public roadmap: $RC_FILE is public and its readers cannot open $full"
                    continue ;;
            esac
            case "$REPO_STATE_MISSING" in
                *" $full "*)
                    red "(c) $full#$num ($why) names a repository that DOES NOT EXIST — the $OWNER listing succeeded and does not contain $full, so this is not a fact about the token"
                    continue ;;
            esac
        fi
        if [ -n "$fixture" ]; then
            # An exact-line fixture: anything not listed does not exist.
            if [[ $'\n'"$(cat "$fixture")"$'\n' == *$'\n'"$full#$num"$'\n'* ]]; then
                resolved=$((resolved + 1))
            else
                red "(c) $full#$num ($why) does not exist — the reference is evidence for a claim in $RC_FILE"
            fi
            continue
        fi
        if ! repo_readable "$full"; then
            skipped=$((skipped + 1))
            note "(c) SKIPPED BY NAME: $full#$num ($why) — this token cannot read the repository $full at all, so a 404 on an issue inside it is a fact about this run, not about the reference"
            continue
        fi
        # stdout discarded, stderr captured: `gh` prints the HTTP status there,
        # and the STATUS is the whole point — a 404 is a verdict about the
        # reference, a 401/403/429 is a verdict about this run.
        err=$(gh api "repos/$full/issues/$num" --jq .number 2>&1 >/dev/null)
        rc=$?
        if [ "$rc" -eq 0 ]; then
            resolved=$((resolved + 1))
            continue
        fi
        status=$(printf '%s\n' "$err" | sed -n 's/.*(HTTP \([0-9][0-9]*\)).*/\1/p' | head -1)
        case "${status:-none}" in
            404)
                red "(c) $full#$num ($why) does not resolve — $RC_FILE offers it as evidence, this token can read $full, and the endpoint answers HTTP 404" ;;
            401|403|429)
                skipped=$((skipped + 1))
                note "(c) SKIPPED BY NAME: $full#$num ($why) — the API answered HTTP $status (unauthorised, forbidden, or rate-limited); that is a fact about this run, not about the reference" ;;
            *)
                skipped=$((skipped + 1))
                note "(c) SKIPPED BY NAME: $full#$num ($why) — the API call failed with no HTTP status (network or transport error): $(printf '%s\n' "$err" | head -1)" ;;
        esac
    done <<< "$out"

    REF_RESOLVED=$resolved
    REF_SKIPPED=$skipped
    if [ "$examined" -ne "${total:-0}" ]; then
        red "(c) extracted ${total:-0} reference(s) but walked $examined — the reference walk lost rows"
        return
    fi
    if [ $((resolved + skipped)) -ne "$examined" ] || [ "$unknown_n" -ne 0 ] || [ "$ambiguous_n" -ne 0 ] || [ "$badowner_n" -ne 0 ]; then
        return
    fi
    echo "      (c) references: examined=$examined, refs=$resolved resolved, skipped=$skipped (source: $src); bare #N outside the table is NOT resolved, by design"
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
    local ok_line="roadmap-check: OK (examined=$TABLE_ROWS row(s), open=$TABLE_OPEN_ROWS) (source: milestones=$SRC_MILESTONES refs=$SRC_REFS resolved=$REF_RESOLVED skipped=$REF_SKIPPED)"
    echo "$ok_line"
    # The gate proves its OWN output satisfies the contract it publishes, so
    # that rewording this line without updating POPULATION_RE goes red here
    # rather than leaving every caller asserting a regex nothing can match.
    #
    # A FIXTURE-driven run is exempt, and only a fixture-driven run: the
    # contract deliberately admits no `fixture:` source (round 3, fix 7 — the
    # callers used to accept `(source: fixture ...)` as a live measurement), so
    # the selftest's own seam could never satisfy it. The exemption is keyed to
    # the source token the line itself carries, so it cannot be claimed by a
    # live run.
    case "$SRC_MILESTONES $SRC_REFS" in
        *fixture:*)
            echo "      (self) contract check skipped: this run is fixture-driven ($SRC_MILESTONES $SRC_REFS); the published contract admits only live or named-skip sources" ;;
        *)
            if ! [[ $ok_line =~ $POPULATION_RE ]]; then
                echo "RED: (a) the population line does not match this gate's own published contract"
                echo "      line:     $ok_line"
                echo "      contract: $POPULATION_RE"
                return 1
            fi ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# --selftest — every plant names the ARM it must turn red, and is run through
# the REAL entry point (mechanical-gates §99), never against a re-implementation
# of the logic here.
# ---------------------------------------------------------------------------
ST_RUN=0
ST_FAIL=0
ST_SKIP=0
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
        elif [[ "$out" == *"      ($arm) SKIPPED BY NAME"* ]]; then
            # A plant proves nothing about an arm that did not run on this
            # host. Scoring that as a FAILURE is what took three CI legs red
            # on 538288c (round-3 blind critic, Fable).
            ST_SKIP=$((ST_SKIP + 1))
            echo "  selftest SKIPPED BY NAME: $name — arm ($arm) did not run on this host"
            printf '%s\n' "$out" | grep "($arm) SKIPPED BY NAME" | head -1 | sed 's/^/      /'
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
InauguralSystems/Tidepool#43
EOF
    export ROADMAP_CHECK_REFS_FIXTURE="$work/refs.txt"
    # THE ORG-LISTING SEAM. `verify_known_repos` asks the organisation which
    # repositories exist and which are private; here it asks this file, so the
    # existence and privacy plants below are deterministic and network-free.
    # The lists are narrowed to match, because a two-line listing against the
    # real 13-entry KNOWN_REPOS would red every case for the wrong reason
    # (mechanical-gates §41 — a row must go red for ITS reason).
    export ROADMAP_CHECK_REPOS="EigenScript Tidepool"
    export ROADMAP_CHECK_PRIVATE_REPOS="SecretThing"
    cat > "$work/org.txt" <<'EOF'
EigenScript false
Tidepool false
EOF
    # The three mutations of that listing, one per branch of the classifier.
    #   gone.txt        Tidepool is not in the org at all  -> does not exist
    #   private.txt     Tidepool is in the org, private    -> not citable
    #   unlistable.txt  the org cannot be listed at all    -> SKIP BY NAME
    cat > "$work/org-gone.txt" <<'EOF'
EigenScript false
EOF
    cat > "$work/org-private.txt" <<'EOF'
EigenScript false
Tidepool true
EOF
    printf 'UNLISTABLE\n' > "$work/org-unlistable.txt"
    export ROADMAP_CHECK_ORG_FIXTURE="$work/org.txt"
    # A SECOND known owner, so the owner-identity plants below can put the SAME
    # repo#N under two owners that the gate both accepts as organisations. With
    # one known owner the only reachable plant is "unknown owner", which cannot
    # show that deduplication keys on the full triple.
    export ROADMAP_CHECK_OWNERS="InauguralSystems SecondOrg"
    # The same reference set, plus the second owner's copy — the CONTROL for
    # plant 14 below: when both owners really have the issue, both resolve.
    cat > "$work/refs2.txt" <<'EOF'
InauguralSystems/EigenScript#375
InauguralSystems/EigenScript#419
InauguralSystems/Tidepool#43
SecondOrg/Tidepool#43
EOF

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

    # CONTROL 10 (arm a): a LEGAL escaped pipe inside a cell. `\|` is the only
    # way to put a pipe in a markdown cell, and round 2 counted it as a cell
    # separator, so a correct row was red for having 6 cells (round-3 blind
    # critic, Astra check 3). A gate that fails correct input gets disabled.
    sed 's%| M1 — A thing |%| M1 — A thing \\| with a pipe |%' \
        "$work/good.md" > "$work/escpipe.md"
    st_case "control: a cell containing a legal escaped pipe" "-" green \
            "$work/escpipe.md" "$work/ms.json"

    # PLANT 11 (arm c): a BARE #N in a cell that also carries a qualified
    # reference. This is M9's own row: "Tidepool#43 and #59" silently resolved
    # #59 against EigenScript (a real, closed PR) and was green for a reference
    # the row does not mean (round-3 blind critic, Fable).
    sed 's%| — | A vetoed thing | retired | #419 | never |%| — | A vetoed thing | retired | see Tidepool#43 and #59 | never |%' \
        "$work/good.md" > "$work/ambiguous.md"
    st_case "plant: a bare #N beside a qualified Repo#M in one cell" "c" red \
            "$work/ambiguous.md" "$work/ms.json"

    # PLANT 12 (arm c): an unknown repo-qualified reference in PROSE. Round 2
    # only caught this shape inside a table and ignored it everywhere else
    # (round-3 blind critic, Astra check 4) — which is exactly the sentence
    # that EXPLAINS a row, where a wrong-repo credit does its damage.
    cp "$work/good.md" "$work/unknownprose.md"
    printf '\nThe finding was filed as PrivateRepo#999999 and never seen again.\n' \
        >> "$work/unknownprose.md"
    st_case "plant: an unknown repo-qualified reference in prose" "c" red \
            "$work/unknownprose.md" "$work/ms.json"

    # PLANT 13 (arm c): an EXPLICIT OWNER outside the known set. Round 3
    # captured only the repository half, so `cli/Tidepool#43` deduplicated
    # against `InauguralSystems/Tidepool#43` and the owner was rebuilt from the
    # default at lookup time — a nonexistent fully qualified reference passed by
    # having a DIFFERENT organisation's repository resolved for it (round-4
    # blind critic, Astra).
    cp "$work/good.md" "$work/badowner.md"
    printf '\nEvidence: cli/Tidepool#43.\n' >> "$work/badowner.md"
    st_case "plant: a reference whose owner is not this gate's organisation" "c" red \
            "$work/badowner.md" "$work/ms.json"

    # PLANT 14 (arm c) — THE REGRESSION FIXTURE: the SAME repo#N under two
    # owners, one real and one not. Deduplication must key on the full triple,
    # so the fake one is walked and goes red on its own account while the real
    # one resolves. Under round 3's extractor this file produced ONE reference.
    cp "$work/good.md" "$work/twoowners.md"
    printf '\nEvidence: InauguralSystems/Tidepool#43 and SecondOrg/Tidepool#43.\n' \
        >> "$work/twoowners.md"
    st_case "plant: the same repo#N under two owners, only one of which has it" "c" red \
            "$work/twoowners.md" "$work/ms.json"

    # CONTROL 15 (arm c): the same file against a fixture where BOTH owners
    # have the issue — green. Without this, plant 14 would also pass against an
    # extractor that simply refused every second owner (mechanical-gates §19).
    # (An assignment PREFIXED to a shell-function call persists after the call
    # in bash, so the fixture is swapped and swapped back explicitly.)
    export ROADMAP_CHECK_REFS_FIXTURE="$work/refs2.txt"
    st_case "control: the same repo#N under two owners that both have it" "-" green \
            "$work/twoowners.md" "$work/ms.json"
    export ROADMAP_CHECK_REFS_FIXTURE="$work/refs.txt"

    # PLANT 16 (arm c) — KNOWN_REPOS IS STALE. The round-5 defect itself:
    # `EigenKB` was on the list, no such repository exists, and the
    # repository-level 404 was reported as "this token cannot read the
    # repository" — a skip, and `OK … skipped=1` (round-5 blind critic,
    # Fable). The organisation listing is what makes the 404 decidable.
    export ROADMAP_CHECK_ORG_FIXTURE="$work/org-gone.txt"
    st_case "plant: a KNOWN_REPOS entry that does not exist in the organisation" "c" red \
            "$work/good.md" "$work/ms.json"

    # PLANT 17 (arm c): the same entry, PRIVATE. A public roadmap cannot cite
    # a repository its readers cannot open, so this is red by name rather
    # than resolved on whichever maintainer token happens to run the gate.
    export ROADMAP_CHECK_ORG_FIXTURE="$work/org-private.txt"
    st_case "plant: a KNOWN_REPOS entry the organisation lists as private" "c" red \
            "$work/good.md" "$work/ms.json"

    # CONTROL 18 (arm c) — THE DISCRIMINATOR. Same missing repository, but the
    # organisation CANNOT BE LISTED: nothing here is decidable, so the
    # verification SKIPS BY NAME and the run is green. Without this control,
    # plant 16 would also pass a gate that simply called every repository
    # missing; with it, gutting the discriminator in EITHER direction is red
    # (always-listable turns this green case red, always-unlistable turns
    # plant 16 silent).
    export ROADMAP_CHECK_ORG_FIXTURE="$work/org-unlistable.txt"
    st_case "control: the org listing fails, so existence is undecidable" "-" green \
            "$work/good.md" "$work/ms.json"
    export ROADMAP_CHECK_ORG_FIXTURE="$work/org.txt"

    # PLANT 19 (arm c): the roadmap CITES a private repository by name. The
    # reference is recognised (PRIVATE_REPOS is in the extractor's known set,
    # so this is not an "unknown repository" red) and refused for its real
    # reason. Round 4 had EigenOS and eigen-site in KNOWN_REPOS: on the
    # maintainer's token such a citation RESOLVED and was counted as evidence.
    cp "$work/good.md" "$work/privateref.md"
    printf '\nThe rest of the work is tracked in SecretThing#7.\n' >> "$work/privateref.md"
    st_case "plant: the roadmap cites an issue in a private repository" "c" red \
            "$work/privateref.md" "$work/ms.json"

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
