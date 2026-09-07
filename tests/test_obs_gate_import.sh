#!/usr/bin/env bash
# #1046 / #915 (the `import` half): the observer write-path gate no longer arms
# on the PRESENCE of an `import`, nor on string DATA that spells an observer
# builtin's name. A literal `import NAME` is resolved at the importer's compile
# time through eigs_import_resolve — the ONE resolver the OP_IMPORT handler
# calls — and the module is scanned (transitively) like a literal `load_file`
# target; the constant-pool string match became a match on NAME-LOAD operands.
#
# Every "closed" verdict here requires rc=0 AND the program's own stdout marker
# AND an `unobserved` stats line (the round-10 vacuity rule from [99u]); every
# answer-shaped verdict carries rc discipline (a crash is died-rcN, never a
# PASS). The invariant that must not break — #915's last comment, suite check
# 40 — is asserted on the VALUE: a host's pre-import history must stay
# visible to an imported reader (`diverging`, never `equilibrium`).
#
# Runs with cwd src/ (the runner's convention); every path below is absolute.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
EIGS="${EIGS:-$TESTS_DIR/../src/eigenscript}"
EIGS="$(cd "$(dirname "$EIGS")" && pwd)/$(basename "$EIGS")"   # fixtures cd; keep it absolute
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
check() { # name expected got
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "PASS: $1"
    else fail=$((fail+1)); echo "FAIL: $1 — expected '$2', got '$3'"; fi
}
# No bare `timeout` (macOS legs have none): the runner's own probe.
tmo() { if command -v timeout >/dev/null 2>&1; then timeout 60 "$@"
        elif command -v gtimeout >/dev/null 2>&1; then gtimeout 60 "$@"
        else "$@"; fi; }
# verdict DIR FILE MARKER -> closed | open | died-rcN | no-output | no-evidence
verdict() {
    local err out rc; err=$(mktemp)
    out=$(cd "$1" && EIGS_OBS_GATE_STATS=1 tmo "$EIGS" "$2" 2>"$err"); rc=$?
    if [ "$rc" -ne 0 ]; then rm -f "$err"; echo "died-rc$rc"; return; fi
    if ! printf '%s' "$out" | grep -q -- "$3"; then rm -f "$err"; echo no-output; return; fi
    if grep -q 'obs-gate: observed' "$err"; then rm -f "$err"; echo open; return; fi
    if grep -q 'obs-gate: unobserved' "$err"; then rm -f "$err"; echo closed; return; fi
    rm -f "$err"; echo no-evidence
}
# answer DIR FILE -> first stdout line, or died-rcN
answer() {
    local out rc
    out=$(cd "$1" && tmo "$EIGS" "$2" 2>/dev/null); rc=$?
    if [ "$rc" -ne 0 ]; then echo "died-rc$rc"; return; fi
    printf '%s\n' "$out" | head -1
}

WLOOP='define wloop(n) as:
    local u is 0.0
    local i is 0
    loop while i < n:
        u is 280.0 + (sin of (i * 0.01))
        i is i + 1
    print of f"w {i}"
wloop of (2000)
'
mkdir -p "$T/p/lib" "$T/p/sub" "$T/p/mid"
printf '%s' "$WLOOP" > "$T/p/w.eigs"
# 1. control: the write loop alone gates closed and runs.
check "control: a read-free write loop gates closed" closed "$(verdict "$T/p" w.eigs "w 2000")"
# 2. the issue's comment-3 row: + `import linalg`, never used. Was `observed`
#    (+49..84%) because OP_IMPORT sat in the reader set.
{ printf 'import linalg\n'; printf '%s' "$WLOOP"; } > "$T/p/w_imp.eigs"
check "an unused stdlib import no longer arms the gate" closed "$(verdict "$T/p" w_imp.eigs "w 2000")"
# 3. the issue's row D: `msg is "report"` — a string constant, pure data.
{ printf 'msg is "report"\n'; printf '%s' "$WLOOP"; } > "$T/p/w_str.eigs"
check "a string literal spelling 'report' no longer arms the gate" closed "$(verdict "$T/p" w_str.eigs "w 2000")"
# 4. the ouroboros frontend.eigs:56 shape: a keyword table naming EVERY observer
#    builtin and predicate as string data, plus a dict keyed by them.
{ printf '_keywords is ["is", "of", "observe", "report", "report_value", "trajectory", "classify", "state_at", "get_observer_thresholds", "eval", "record_history", "converged", "stable", "improving", "oscillating", "diverging", "equilibrium", "when", "where", "why", "how"]\n_tbl is {"observe": 1, "eval": 2, "report": 3}\nprint of f"{len of _keywords} {_tbl.eval}"\n'; printf '%s' "$WLOOP"; } > "$T/p/w_kw.eigs"
check "a keyword table of observer names (string data) gates closed" closed "$(verdict "$T/p" w_kw.eigs "w 2000")"
# 5-6. The ALIAS forms still arm: a name-load of the builtin, whatever it is
#    bound to. This is the population the string match was over-approximating.
{ printf 'local r is observe\n'; printf '%s' "$WLOOP"; } > "$T/p/w_alias.eigs"
check "a first-class load of 'observe' still arms (alias)" open "$(verdict "$T/p" w_alias.eigs "w 2000")"
{ printf 'local e is eval\n'; printf '%s' "$WLOOP"; } > "$T/p/w_eval.eigs"
check "a first-class load of 'eval' still arms" open "$(verdict "$T/p" w_eval.eigs "w 2000")"
# 7a. The population is the binding-LOAD opcode, not every name operand: a
#    user function NAMED observe is a SET_FN_NAME_LOCAL "observe" (a binder,
#    and it shadows the builtin), and a dict FIELD spelled eval is a DOT_GET
#    "eval" on a user value — neither loads the builtin, neither arms.
{ printf 'define observe(v) as:\n    return v\ntbl is {"eval": 1}\nprint of (tbl.eval)\n'; printf '%s' "$WLOOP"; } > "$T/p/w_def.eigs"
check "a user-defined observe plus a field named eval gate closed (no builtin load)" closed "$(verdict "$T/p" w_def.eigs "w 2000")"
# 7b. ...but the same program that ALSO loads the builtin by name arms.
{ printf 'define observe(v) as:\n    return v\nlocal f is classify\n'; printf '%s' "$WLOOP"; } > "$T/p/w_def2.eigs"
check "the same program with a builtin name-load (classify) arms" open "$(verdict "$T/p" w_def2.eigs "w 2000")"
# 8. --lint never resolves or reads modules; the keyword-table program lints
#    unobserved (the #1046 comment-5 bar), and lint touches nothing else.
LINT_OUT=$(cd "$T/p" && EIGS_OBS_GATE_STATS=1 tmo "$EIGS" --lint w_kw.eigs 2>&1); LINT_RC=$?
if [ "$LINT_RC" -ne 0 ]; then LINT_V="died-rc$LINT_RC"
elif printf '%s' "$LINT_OUT" | grep -q 'obs-gate: unobserved'; then LINT_V=unobserved
else LINT_V=other; fi
check "--lint reports the keyword-table program unobserved" unobserved "$LINT_V"
# 9. EIGS_OBS_FORCE=1 still reopens the gate on the import program (the
#    baseline arm for any measurement).
FORCE_OUT=$(cd "$T/p" && EIGS_OBS_FORCE=1 EIGS_OBS_GATE_STATS=1 tmo "$EIGS" w_imp.eigs 2>&1); FORCE_RC=$?
if [ "$FORCE_RC" -ne 0 ]; then FORCE_V="died-rc$FORCE_RC"
elif printf '%s' "$FORCE_OUT" | grep -q 'obs-gate: observed'; then FORCE_V=observed; else FORCE_V=other; fi
check "EIGS_OBS_FORCE=1 reopens the gate on the import program" observed "$FORCE_V"

# ---- the invariant: a host's pre-import history stays visible ----------
HOST='x is 1.0
for i in range of 40:
    x is x * 2.0
'
# 10. The check-40 shape: the imported module READS. Asserted on the VALUE.
printf 'print of (report of x)\nverdict is 1.0\n' > "$T/p/lib/probe.eigs"
{ printf '%s' "$HOST"; printf 'import probe\n'; } > "$T/p/host.eigs"
check "an imported reader sees the host's pre-import history (diverging)" diverging "$(answer "$T/p" host.eigs)"
# 11. ...and the gate's own verdict for that host is OPEN before line 1 ran
#     (the eager scan, not a late runtime flip — a late flip would have RAISED
#     through the import guard and check 10 would read died-rc1).
check "the host importing a reader compiles observed" open "$(verdict "$T/p" host.eigs diverging)"
# 12. TRANSITIVE: host -> mid (clean) -> inner (reads), through nested imports
#     anchored at the module's own directory.
printf 'print of (report of x)\n' > "$T/p/mid/inner.eigs"
printf 'import inner\n' > "$T/p/mid/mid.eigs"
{ printf '%s' "$HOST"; printf 'import mid\n'; } > "$T/p/host_deep.eigs"
# mid.eigs must resolve from host's dir: put a copy where `import mid` finds it.
cp "$T/p/mid/mid.eigs" "$T/p/mid.eigs"; cp "$T/p/mid/inner.eigs" "$T/p/inner.eigs"
check "a reader TWO imports down still sees the host's history" diverging "$(answer "$T/p" host_deep.eigs)"
# 13. RESOLVER PARITY, project-first: a project file named like a stdlib module
#     (`linalg.eigs`, which READS) must be the one the eager pass scans. A
#     stdlib-first pass would scan lib/linalg.eigs (read-free), close the gate,
#     and the import guard would raise (died-rc1) — never `diverging`.
printf 'print of (report of x)\n' > "$T/p/sub/linalg.eigs"
{ printf '%s' "$HOST"; printf 'import linalg\n'; } > "$T/p/sub/host_shadow.eigs"
check "project-first: a shadowing project module is what the pass scans" diverging "$(answer "$T/p/sub" host_shadow.eigs)"
# 14. RESOLVER PARITY, project root: eigs.json marks $T/p as the root, so a
#     host in a subdirectory resolves `import rootmod` to $T/p/rootmod.eigs.
printf '{"name": "obs-gate-import-fixture"}\n' > "$T/p/eigs.json"
printf 'print of (report of x)\n' > "$T/p/rootmod.eigs"
{ printf '%s' "$HOST"; printf 'import rootmod\n'; } > "$T/p/sub/host_root.eigs"
check "project-root (eigs.json) resolution: the pass finds the root module" diverging "$(answer "$T/p/sub" host_root.eigs)"
# 15. UNREACHABLE code still counts: an import inside a function nobody calls
#     is scanned (the pass walks chunk->functions), so the host arms.
{ printf 'define never() as:\n    import probe\n    return 0\n'; printf '%s' "$WLOOP"; } > "$T/p/w_dead.eigs"
check "an import of a reader inside an uncalled function still arms" open "$(verdict "$T/p" w_dead.eigs "w 2000")"
# 16. An UNRESOLVABLE import cannot be scanned, so it cannot be cleared: the
#     decision is `observed` (the import itself then fails at runtime, as
#     before — this asserts the DECISION, from the stats line).
{ printf 'import no_such_module_1046\n'; printf '%s' "$WLOOP"; } > "$T/p/w_missing.eigs"
MISS_ERR=$(cd "$T/p" && EIGS_OBS_GATE_STATS=1 tmo "$EIGS" w_missing.eigs 2>&1 >/dev/null)
check "an unresolvable import keeps the gate open (conservative)" 1 "$(printf '%s\n' "$MISS_ERR" | grep -c 'obs-gate: observed')"
# 17. STALE MODULE: the file scanned at compile time is rewritten before the
#     import runs. The gate closed on stale evidence and the history is gone;
#     OP_IMPORT must RAISE (the load_file guard, mirrored), never answer a
#     rest value. Without the guard this prints `equilibrium`, rc=0.
printf 'define helper(a) as:\n    return a\n' > "$T/p/lib/later.eigs"
{ printf '%s' "$HOST"; printf 'write_text of ["%s/lib/later.eigs", "print of (report of x)\\n"]\nimport later\nprint of "unreachable"\n' "$T/p"; } > "$T/p/host_stale.eigs"
STALE_OUT=$(cd "$T/p" && tmo "$EIGS" host_stale.eigs 2>&1); STALE_RC=$?
if [ "$STALE_RC" -ne 0 ] && printf '%s' "$STALE_OUT" | grep -q "import: 'later' reads observer state"; then STALE_V=raised
elif [ "$STALE_RC" -eq 0 ]; then STALE_V="silent:$(printf '%s\n' "$STALE_OUT" | head -1)"
else STALE_V="died-rc$STALE_RC"; fi
check "a module rewritten between scan and import RAISES (no silent rest value)" raised "$STALE_V"
# 18. Positive control for the shared resolver: an ordinary clean import still
#     resolves and runs through eigs_import_resolve, and the whole program
#     gates closed.
printf 'define twice(a) as:\n    return a * 2\nprint of "mod"\n' > "$T/p/mymod.eigs"
printf 'import mymod\nprint of (mymod.twice of 21)\n' > "$T/p/use_mymod.eigs"
check "a clean project import resolves, runs, and gates closed" closed "$(verdict "$T/p" use_mymod.eigs 42)"

echo "SUMMARY: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
