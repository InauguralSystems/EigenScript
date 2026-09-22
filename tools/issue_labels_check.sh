#!/usr/bin/env bash
# issue_labels_check.sh — every OPEN issue carries an `area:` label and a kind.
#
# WHY THIS EXISTS (maintainer, 2026-09-21: "we aren't labeling issues"):
# the open backlog was essentially unlabelled that day. The "33 of 36" census
# that first circulated is NOT reproducible from the API — the open set was 35
# at the sweep (#1123 closed 2026-09-20, #1217 opened 2026-09-21) and never 36
# — so it is not restated here. The figure this gate stands on is its own
# first real run after the hand sweep: `examined=35 missing=0`. Triage
# by memory does not survive a week, and an unlabelled backlog cannot be
# ranked, split across a fleet, or reported on. The scheme now exists on the
# repository — `area:<subsystem>`, `kind:*` (plus the stock `bug` and
# `enhancement`), `found-by:*`, `blocks-release` — every open issue was
# labelled by hand once, and from here the rule is MECHANICAL: this check runs
# daily and on demand, and `.github/workflows/issue-triage.yml` puts
# `needs-triage` on anything new that arrives without an `area:`.
#
# THE RULE, exactly: an open ISSUE (never a pull request) must carry
#   * at least one label whose name starts with `area:`, AND
#   * at least one KIND — a label starting with `kind:`, or the stock `bug`,
#     or the stock `enhancement`.
# Anything else is missing, and missing > 0 is a failure. So is examining ZERO
# issues: an empty enumeration satisfies "nothing is missing" and is the
# vacuity mechanical-gates §121 exists to stop, so it fails too.
#
# WHAT A CALLER OF THIS GATE CAN AND CANNOT PROVE. A caller ([99zd] in
# tests/run_all_tests.sh, the audit in .github/workflows/issue-triage.yml)
# verifies that this gate printed a population line it could only have produced
# by running its live arm ON THAT LANE — the source token is pinned to
# `gh-api:` with no `SKIPPED BY NAME` alternative whenever the CALLER'S OWN
# probe (tools/gh_probe.sh) can reach GitHub — and that this gate's selftest
# ran with the pinned case count. A gate that FABRICATES its own output —
# printing the population line and the selftest line without doing the work —
# is outside any caller's power to detect: a forged receipt reads exactly like
# a true one. That is what the blind-critic rounds and this selftest's
# transverse mutations are for.
#
# Usage:
#   bash tools/issue_labels_check.sh              # the live repository
#   bash tools/issue_labels_check.sh --selftest   # planted faults, no network
#   bash tools/issue_labels_check.sh --ensure-labels
#                                                 # create `needs-triage` if absent
#   bash tools/issue_labels_check.sh --contract   # the population regex and the
#                                                 # pinned selftest case count
#                                                 # that every CALLER asserts
#   ISSUE_LABELS_JSON=/path/to/issues.json bash tools/issue_labels_check.sh
#                                                 # the selftest's seam; also an
#                                                 # offline escape hatch
set -u

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO="${ISSUE_LABELS_REPO:-InauguralSystems/EigenScript}"

# The `gh` reachability probe lives in ONE file, sourced by this gate AND by
# its callers ([99zd] in tests/run_all_tests.sh and the audit step in
# .github/workflows/issue-triage.yml). Round 3 let each gate decide alone
# whether GitHub was reachable and had the callers believe the answer, so a
# gate whose probe always said "no" passed on an authenticated box (round-4
# blind critic, Fable). Two readers of one probe cannot disagree.
# shellcheck source=gh_probe.sh
. "$(cd "$(dirname "$0")" && pwd)/gh_probe.sh"

# ---------------------------------------------------------------------------
# THE CONTRACT — the population line this gate promises to print, and how many
# planted faults its selftest runs. Defined ONCE, here, and printed by
# `--contract`, so that every caller (the `[99zd]` suite section and
# `.github/workflows/issue-triage.yml`) asserts the SAME regex this gate
# prints and the two cannot drift apart.
#
# BOUGHT 2026-09-21 (round-2 blind critic, Astra): with this script gutted to
# `exit 0`, BOTH callers passed — `exit=0 output=''` satisfied the daily audit
# `run:` block under `bash -e` and the suite section alike. A successful exit
# is not a measurement (mechanical-gates §121): the caller must require the
# POSITIVE POPULATION LINE, by regex, and fail by name when it is absent.
#
# ROUND 3 (blind critic, Fable): the callers also accepted a FIXTURE-sourced
# "live" run — `examined=1 missing=0 (source: fixture ...)` passed, because the
# caller's regex stopped before `(source:`. The source is now a machine-readable
# token (`gh-api:` / `fixture:`) and the contract admits only the live one, so a
# run driven by the selftest seam is red at the caller by name.
POPULATION_RE='^issue-labels: examined=[1-9][0-9]* missing=[0-9][0-9]* \(source: gh-api:[^ )]+\)$'
SELFTEST_CASES=7

# Nothing on this gate's stdin, for the reason docs_claims_check.sh records:
# a counting pipeline that inherits an open stdin hangs, and one that inherits
# /dev/null counts 0 and passes the guard built on that count.
exec 0</dev/null

# ---------------------------------------------------------------------------
# The classifier. Kept in one place so the workflow, the selftest and the live
# run cannot disagree about what "labelled" means.
# ---------------------------------------------------------------------------
classify() {
    # reads the issue JSON array on stdin; prints
    #   examined=<n> missing=<n>
    #   MISSING <number> <what-is-missing> <title>
    python3 -c '
import json, sys

try:
    data = json.load(sys.stdin)
except Exception as exc:
    sys.stderr.write("issue-labels: cannot parse the issue list: %s\n" % exc)
    sys.exit(2)
if not isinstance(data, list):
    sys.stderr.write("issue-labels: expected a JSON array of issues\n")
    sys.exit(2)
# ONE LEVEL OF PAGES, FLATTENED HERE. `gh api --paginate` hands us one merged
# array; `gh api --paginate --slurp` (and any fixture shaped like it) hands us
# an array OF PAGES. Both are accepted; anything else is named rather than
# silently walked, because a list of strings would examine zero issues and
# "examined 0" is the vacuity this gate refuses anyway.
if data and all(isinstance(x, list) for x in data):
    data = [it for page in data for it in page]
if any(not isinstance(it, dict) for it in data):
    sys.stderr.write("issue-labels: the list is neither an array of issues nor an array of pages of issues\n")
    sys.exit(2)

KIND_EXACT = {"bug", "enhancement"}
examined = 0
missing = []
for it in data:
    # A pull request is not an issue. The REST list endpoint returns both and
    # marks PRs with a "pull_request" key; gh issue list does not, so both
    # shapes are handled rather than one being assumed.
    if it.get("pull_request"):
        continue
    if it.get("state", "open") != "open":
        continue
    examined += 1
    names = []
    for lab in it.get("labels", []) or []:
        names.append(lab["name"] if isinstance(lab, dict) else str(lab))
    has_area = any(n.startswith("area:") for n in names)
    has_kind = any(n.startswith("kind:") or n in KIND_EXACT for n in names)
    if has_area and has_kind:
        continue
    want = []
    if not has_area:
        want.append("area:")
    if not has_kind:
        want.append("kind")
    missing.append((it.get("number"), "+".join(want), it.get("title", "")))

print("examined=%d missing=%d" % (examined, len(missing)))
for num, want, title in missing:
    print("MISSING %s %s %s" % (num, want, title[:70]))
'
}

run_live() {
    local json src out rc examined missing numbers
    if [ -n "${ISSUE_LABELS_JSON:-}" ]; then
        if [ ! -f "$ISSUE_LABELS_JSON" ]; then
            echo "RED: ISSUE_LABELS_JSON names no file: $ISSUE_LABELS_JSON"
            return 1
        fi
        json=$(cat "$ISSUE_LABELS_JSON")
        src="fixture:$ISSUE_LABELS_JSON"
    else
        if ! command -v gh >/dev/null 2>&1; then
            echo "issue-labels: SKIPPED BY NAME: gh is not on PATH, so the open-issue set cannot be read"
            return 0
        fi
        if ! command -v python3 >/dev/null 2>&1; then
            echo "issue-labels: SKIPPED BY NAME: python3 is not on PATH, so the issue list cannot be classified"
            return 0
        fi
        # `gh` INSTALLED IS NOT `gh` AUTHENTICATED — the macOS runner has one
        # and not the other (CI run 35599371704), and the two states must be
        # distinguishable by name rather than collapsed into one failure. The
        # probe itself is tools/gh_probe.sh, which is also what this gate's
        # CALLERS run, so "the gate says it could not reach GitHub" is a claim
        # the caller can check rather than one it has to believe.
        if ! gh_probe_authenticated; then
            echo "issue-labels: SKIPPED BY NAME: gh is on PATH but has no working credentials, so the open-issue set cannot be read"
            return 0
        fi
        if ! json=$(gh api "repos/$REPO/issues?state=open&per_page=100" --paginate 2>/dev/null); then
            echo "issue-labels: SKIPPED BY NAME: gh is authenticated but the issues API call failed (offline, rate-limited, or the repository is unreadable)"
            return 0
        fi
        # ONE ARRAY, NOT A SPLICE. Bought 2026-09-21 (third critic,
        # `/code-review 1226 medium`, finding 8): this line used to be
        # `sed 's/^\]\[/,/' | tr -d '\n'`, and it was dead twice over.
        # `gh api --paginate` MERGES REST pages into a single JSON array —
        # measured on this repository with `per_page=3` over 4 pages: zero
        # `][` seams — and on a `gh` that DID concatenate raw bodies the seam
        # would sit mid-line, where a `^`-anchored sed cannot reach it. A
        # dead repair that reads as a live one is worse than none, because it
        # retires the question.
        #
        # `--slurp` states the shape explicitly and is deliberately NOT used:
        # measured 2026-09-21, `gh` 2.45.0 (Ubuntu's package, the dev box)
        # answers `unknown flag: --slurp`, so the API call would fail and this
        # gate would take its named SKIP — which at a live caller is RED — on
        # every lane whose `gh` predates the flag. The classifier accepts
        # EITHER shape instead (one array of issues, or an array of pages) and
        # refuses anything else BY NAME, so a `gh` that ever does emit pages
        # is parsed rather than spliced.
        src="gh-api:repos/$REPO/issues"
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        echo "issue-labels: SKIPPED BY NAME: python3 is not on PATH, so the issue list cannot be classified"
        return 0
    fi

    if ! out=$(printf '%s' "$json" | classify); then
        echo "RED: issue-labels: could not classify the issue list from $src"
        return 1
    fi

    examined=$(printf '%s\n' "$out" | sed -n 's/^examined=\([0-9]*\) .*/\1/p')
    missing=$(printf '%s\n' "$out" | sed -n 's/^examined=[0-9]* missing=\([0-9]*\)$/\1/p')
    numbers=$(printf '%s\n' "$out" | sed -n 's/^MISSING \([0-9]*\) .*/#\1/p' | tr '\n' ' ')

    local pop_line="issue-labels: examined=${examined:-0} missing=${missing:-0} (source: $src)"
    echo "$pop_line"
    # The gate proves its OWN output satisfies the contract it publishes. If
    # someone rewords this line without updating POPULATION_RE, the gate goes
    # red here rather than leaving every caller asserting a regex that can no
    # longer match anything. A FIXTURE-driven run is exempt, and only a
    # fixture-driven one: the contract admits no `fixture:` source by design
    # (round 3, fix 7), so the selftest's own seam could never satisfy it.
    case "$src" in
        fixture:*) : ;;
        *)
            if [ -n "${examined:-}" ] && [ "${examined:-0}" -gt 0 ] && ! [[ $pop_line =~ $POPULATION_RE ]]; then
                echo "RED: issue-labels: the population line does not match this gate's own published contract"
                echo "      line:     $pop_line"
                echo "      contract: $POPULATION_RE"
                return 1
            fi ;;
    esac
    if [ -z "${examined:-}" ] || [ -z "${missing:-}" ]; then
        echo "RED: issue-labels: the classifier did not report its counts"
        printf '%s\n' "$out" | head -5 | sed 's/^/      /'
        return 1
    fi
    if [ "$examined" -eq 0 ]; then
        echo "RED: issue-labels: examined 0 open issue(s) — an empty population satisfies 'nothing is missing' without checking anything (mechanical-gates §121)"
        return 1
    fi
    if [ "$missing" -gt 0 ]; then
        echo "RED: issue-labels: $missing of $examined open issue(s) lack an area: label, a kind label, or both: $numbers"
        printf '%s\n' "$out" | grep '^MISSING ' | sed 's/^/      /'
        echo "      Every open issue carries an area: label and a kind (kind:*, bug, or enhancement). See docs/CI.md."
        return 1
    fi
    echo "issue-labels: OK — all $examined open issue(s) carry an area: label and a kind"
    return 0
}

ensure_labels() {
    if ! command -v gh >/dev/null 2>&1; then
        echo "issue-labels: SKIPPED BY NAME: gh is not on PATH, so needs-triage cannot be created"
        return 0
    fi
    local existing
    existing=$(gh label list --repo "$REPO" --limit 200 2>/dev/null | cut -f1)
    # Bash's own matcher, not `| grep -qx`: an early-exiting reader at the end
    # of a pipe is the banned verdict shape (tools/pipefail_verdict_check.sh).
    if [[ $'\n'"$existing"$'\n' == *$'\n'"needs-triage"$'\n'* ]]; then
        echo "issue-labels: needs-triage already exists on $REPO"
        return 0
    fi
    gh label create needs-triage --repo "$REPO" --color ededed \
       --description "Filed without an area: label; triage and label it" 2>&1
    local rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "issue-labels: could not create needs-triage (rc=$rc)"
        return "$rc"
    fi
    echo "issue-labels: created needs-triage on $REPO"
    return 0
}

# ---------------------------------------------------------------------------
# --selftest: fixtures only, no network. Each case names what must happen.
# ---------------------------------------------------------------------------
ST_RUN=0
ST_FAIL=0
st_case() {
    local name="$1" expect="$2" fixture="$3" want="$4"
    ST_RUN=$((ST_RUN + 1))
    local out rc
    out=$(ISSUE_LABELS_JSON="$fixture" "$SELF" 2>&1)
    rc=$?
    local ok=0
    if [ "$expect" = "red" ] && [ "$rc" -ne 0 ]; then ok=1; fi
    if [ "$expect" = "green" ] && [ "$rc" -eq 0 ]; then ok=1; fi
    if [ "$ok" -eq 1 ] && [ -n "$want" ]; then
        [[ "$out" == *"$want"* ]] || ok=0
    fi
    if [ "$ok" -eq 1 ]; then
        echo "  selftest ok: $name"
        printf '%s\n' "$out" | grep -E '^(RED|issue-labels): ' | head -2 | sed 's/^/      /'
    else
        ST_FAIL=$((ST_FAIL + 1))
        echo "  SELFTEST FAIL: $name — expected $expect (and ${want:-any output}), got rc=$rc"
        printf '%s\n' "$out" | head -10 | sed 's/^/      /'
    fi
}

selftest() {
    WORK=$(mktemp -d "${TMPDIR:-/tmp}/issue_labels.XXXXXX") || exit 2
    trap 'rm -rf "$WORK"' EXIT

    cat > "$WORK/all_labelled.json" <<'EOF'
[{"number": 1, "state": "open", "title": "a runtime bug",
  "labels": [{"name": "area:runtime-vm"}, {"name": "kind:silent-wrong"}]},
 {"number": 2, "state": "open", "title": "a docs ask",
  "labels": [{"name": "area:docs"}, {"name": "enhancement"}]},
 {"number": 3, "state": "open", "title": "a pull request, not an issue",
  "pull_request": {"url": "https://example.invalid/pull/3"}, "labels": []}]
EOF
    st_case "control: every open issue labelled (and a PR ignored)" green \
            "$WORK/all_labelled.json" "examined=2 missing=0"

    cat > "$WORK/one_unlabelled.json" <<'EOF'
[{"number": 1, "state": "open", "title": "a runtime bug",
  "labels": [{"name": "area:runtime-vm"}, {"name": "kind:silent-wrong"}]},
 {"number": 2, "state": "open", "title": "filed and forgotten", "labels": []}]
EOF
    st_case "plant: one unlabelled open issue" red \
            "$WORK/one_unlabelled.json" "#2"

    cat > "$WORK/area_only.json" <<'EOF'
[{"number": 7, "state": "open", "title": "has an area but no kind",
  "labels": [{"name": "area:jit"}, {"name": "found-by:critic"}]}]
EOF
    st_case "plant: an area: label with no kind (found-by is not a kind)" red \
            "$WORK/area_only.json" "#7"

    cat > "$WORK/kind_only.json" <<'EOF'
[{"number": 8, "state": "open", "title": "has a kind but no area",
  "labels": [{"name": "bug"}]}]
EOF
    st_case "plant: a kind with no area: label" red \
            "$WORK/kind_only.json" "#8"

    printf '[]\n' > "$WORK/empty.json"
    st_case "plant: zero issues examined (vacuity)" red \
            "$WORK/empty.json" "examined 0 open issue"

    cat > "$WORK/prs_only.json" <<'EOF'
[{"number": 9, "state": "open", "title": "only a PR is open",
  "pull_request": {"url": "https://example.invalid/pull/9"}, "labels": []}]
EOF
    st_case "plant: the list holds only pull requests, so nothing is examined" red \
            "$WORK/prs_only.json" "examined 0 open issue"

    # THE PAGED SHAPE. An array OF PAGES is what `gh api --paginate --slurp`
    # produces, and until round 7 the only thing that ever touched a page
    # boundary was a `^]\[`-anchored sed that could not fire (third critic,
    # `/code-review 1226 medium`, finding 8). Two pages, one unlabelled issue
    # on the SECOND one: a walk that reads only the first page, or that treats
    # the pages as issues, examines the wrong population and cannot see it.
    cat > "$WORK/two_pages.json" <<'EOF'
[[{"number": 1, "state": "open", "title": "page one, labelled",
   "labels": [{"name": "area:runtime-vm"}, {"name": "kind:silent-wrong"}]}],
 [{"number": 42, "state": "open", "title": "page two, filed and forgotten",
   "labels": []}]]
EOF
    st_case "plant: an unlabelled issue on the SECOND page of a paged listing" red \
            "$WORK/two_pages.json" "#42"

    echo ""
    # The `skipped` field is always present so every caller parses ONE line
    # shape across the three gates; this gate's fixtures never skip, so it is
    # always 0 here, and a nonzero value would be a defect.
    echo "SELFTEST: $ST_RUN case(s) run, $((ST_RUN - ST_FAIL)) passed, $ST_FAIL failed, 0 skipped"
    [ "$ST_FAIL" -eq 0 ]
}

case "${1:-}" in
    --selftest)      selftest; exit $? ;;
    --ensure-labels) ensure_labels; exit $? ;;
    --contract)      printf 'POPULATION_RE=%s\n' "$POPULATION_RE"
                     printf 'SELFTEST_CASES=%s\n' "$SELFTEST_CASES"
                     exit 0 ;;
    "")              run_live; exit $? ;;
    *) echo "usage: $0 [--selftest|--ensure-labels|--contract]" >&2; exit 2 ;;
esac
