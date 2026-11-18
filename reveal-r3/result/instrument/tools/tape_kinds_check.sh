#!/usr/bin/env bash
# tape_kinds_check.sh -- #1637: every taped builtin declares its return kinds.
#
# Replay refuses a recorded N value whose kind its builtin cannot return
# (src/trace.c, k_tape_kinds) -- and refuses a name that is in no table. A
# builtin that starts recording without a row would therefore fail only at
# replay, on a user's tape. This gate fails first, at build review:
#   taped    = every name src/*.c records or takes: TRACE_NONDET_TAKE/RET/
#              RECORD("x"), ARG_GUARD_TAPED/PRETAKE(..., "x", ...),
#              trace_replay_take("x"), trace_nondet_value("x"),
#              file_io_error("x", ...) (all filesystem errors are taped), and
#              trace_source_record/replay("x") (which also emits `x_chunk`)
#   declared = every {"x", ...} row of k_tape_kinds
#   documented = every backticked name in the second column of the table
#              under docs/TRACE.md's `## Recorded Builtins` (#2200: #2178
#              deleted that catalogue and every gate stayed green)
# and requires taped == declared == documented, all non-empty. The
# smoke/embedding test programs (embed_*.c, jit_smoke.c) record host names
# and declare them through eigs_trace_declare_kind, so they are not part of
# the core set.
# Prints `tape-kinds: taped=N declared=K documented=D missing=0 stale=0
# undocumented=0 unrecorded=0` and PASS/FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC_DIR="${TAPE_KINDS_SRC:-$ROOT/src}"
DOC="${TAPE_KINDS_DOC:-$ROOT/docs/TRACE.md}"
[ "${1:-}" != "--selftest" ] || {
    work=$(mktemp -d "${TMPDIR:-/tmp}/tape_kinds_selftest.XXXXXX") || exit 2
    trap 'rm -rf "$work"' EXIT
    # fixture <name>: a source tree recording `a` and `b`, both declared, and
    # a catalogue naming both. Each plant then breaks exactly one population.
    fixture() {
        rm -rf "${work:?}/$1"; mkdir -p "$work/$1"
        printf '%s\n' 'static const int k_tape_kinds[] = {' '    {"a", 1},' '    {"b", 1},' '};' \
            'void g(void) { TRACE_NONDET_RECORD("a", v); TRACE_NONDET_RET("b", v); }' > "$work/$1/trace.c"
        printf '%s\n' '# Trace' '' '## Recorded Builtins' '' 'The `prose_only` name is not an entry.' '' \
            '| Family | `N` record names |' '|---|---|' '| One | `a` (#1) |' '| Two | `b` |' '' '## Next' '' '| X | `after_section` |' > "$work/$1/TRACE.md"
    }
    run() { out=$(TAPE_KINDS_SRC="$work/$1" TAPE_KINDS_DOC="$work/$1/TRACE.md" bash "$0" 2>&1); }
    # plant <name> <violation line> <summary>: must FAIL with exactly that one violation.
    plant() {
        if run "$1"; then echo "SELFTEST FAILED: plant '$1' was accepted"; printf '%s\n' "$out"; exit 1; fi
        if [ "$(printf '%s\n' "$out" | grep -c '^  [A-Z][A-Z ]*:')" -ne 1 ] ||
           [ "$(printf '%s\n' "$out" | grep -cF "$2")" -ne 1 ] ||
           ! printf '%s\n' "$out" | grep -qxF "$3"; then
            echo "SELFTEST FAILED: plant '$1' did not produce exactly one '$2'"; printf '%s\n' "$out"; exit 1
        fi
        echo "  caught: $1"
    }
    fixture clean
    if ! run clean; then
        echo "SELFTEST FAILED: clean tape-kind control was rejected"; printf '%s\n' "$out"; exit 1
    elif ! printf '%s\n' "$out" | grep -qxF 'tape-kinds: taped=2 declared=2 documented=2 missing=0 stale=0 undocumented=0 unrecorded=0'; then
        echo "SELFTEST FAILED: clean tape-kind control did not examine two matched kinds"; printf '%s\n' "$out"; exit 1
    fi
    fixture missing_row
    printf '%s\n' 'void f(void) { TRACE_NONDET_RECORD("planted_missing", v); }' > "$work/missing_row/plant.c"
    sed -i.bak 's/^| Two | `b` |$/| Two | `b`, `planted_missing` |/' "$work/missing_row/TRACE.md" && rm -f "$work/missing_row/TRACE.md.bak"
    plant missing_row "MISSING: 'planted_missing' records an N value but has no k_tape_kinds row" \
        'tape-kinds: taped=3 declared=2 documented=3 missing=1 stale=0 undocumented=0 unrecorded=0'
    fixture deleted_entry
    sed -i.bak 's/^| Two | `b` |$/| Two | |/' "$work/deleted_entry/TRACE.md" && rm -f "$work/deleted_entry/TRACE.md.bak"
    plant deleted_entry "UNDOCUMENTED: 'b' records an N value but docs/TRACE.md's catalogue does not name it" \
        'tape-kinds: taped=2 declared=2 documented=1 missing=0 stale=0 undocumented=1 unrecorded=0'
    fixture fake_entry
    sed -i.bak 's/^| Two | `b` |$/| Two | `b`, `planted_fake` |/' "$work/fake_entry/TRACE.md" && rm -f "$work/fake_entry/TRACE.md.bak"
    plant fake_entry "UNRECORDED: docs/TRACE.md's catalogue names 'planted_fake' but nothing records it" \
        'tape-kinds: taped=2 declared=2 documented=3 missing=0 stale=0 undocumented=0 unrecorded=1'
    fixture no_catalogue
    printf '%s\n' '# Trace' '' 'The catalogue was deleted (#2178).' > "$work/no_catalogue/TRACE.md"
    plant no_catalogue "NO CATALOGUE: docs/TRACE.md has no table under '## Recorded Builtins'" \
        'tape-kinds: taped=2 declared=2 documented=0 missing=0 stale=0 undocumented=0 unrecorded=0'
    echo "SELFTEST OK: clean control passed; 4 plants (missing kind row, deleted catalogue entry, fake catalogue entry, deleted catalogue) each caught exactly once"
    exit 0
}
TMP=$(mktemp "${TMPDIR:-/tmp}/tape_kinds.XXXXXX") || exit 2
trap 'rm -f "$TMP" "$TMP.d" "$TMP.doc"' EXIT

for f in "$SRC_DIR"/*.c; do
    case "$(basename "$f")" in embed_*.c|jit_smoke.c) continue ;; esac
    awk '
    # A macro invocation may span lines; join it up to its closing ");".
    function emit(s,    m) {
        while (match(s, /(TRACE_NONDET_(TAKE|RET|RECORD)|trace_replay_take|trace_nondet_value)[(]"[a-z_0-9]+"/)) {
            m = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
            print m
            s = substr(s, RSTART + RLENGTH)
        }
        while (match(s, /file_io_error[(]"[a-z_0-9]+"/)) {
            m = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
            print m
            s = substr(s, RSTART + RLENGTH)
        }
        while (match(s, /trace_source_(record|replay)[(]"[a-z_0-9]+"/)) {
            m = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", m); sub(/"$/, "", m)
            print m; print m "_chunk"
            s = substr(s, RSTART + RLENGTH)
        }
    }
    /ARG_GUARD_(TAPED|PRETAKE)[(]/ && !/#define/ { acc = $0; inm = 1 }
    inm && acc != $0 { acc = acc " " $0 }
    inm && /[)];/ {
        # the first string literal in the invocation is `who`
        if (match(acc, /"[a-z_0-9]+"/)) print substr(acc, RSTART + 1, RLENGTH - 2)
        inm = 0
    }
    { emit($0) }
    ' "$f"
done | sort -u > "$TMP"

awk '/k_tape_kinds\[\] = [{]/ { on = 1; next }
     on && /^[}];/ { on = 0 }
     on && match($0, /[{]"[a-z_0-9]+"/) { print substr($0, RSTART + 2, RLENGTH - 3) }' \
    "$SRC_DIR/trace.c" | sort -u > "$TMP.d"

# The catalogue: the table rows of the `## Recorded Builtins` section, second
# column only, so names the prose mentions (untraced siblings, refused calls)
# are never entries.
awk '/^## Recorded Builtins[[:space:]]*$/ { on = 1; next }
     on && /^## / { on = 0 }
     on && /^[|]/ {
         split($0, col, "|"); cell = col[3]
         while (match(cell, /`[a-z_0-9]+`/)) {
             print substr(cell, RSTART + 1, RLENGTH - 2)
             cell = substr(cell, RSTART + RLENGTH)
         }
     }' "$DOC" 2>/dev/null | sort -u > "$TMP.doc"

taped=$(grep -c . "$TMP")
declared=$(grep -c . "$TMP.d")
documented=$(grep -c . "$TMP.doc")
missing=0; stale=0; undocumented=0; unrecorded=0
# No catalogue at all is one fault, not one per taped name.
[ "$documented" -gt 0 ] || echo "  NO CATALOGUE: docs/TRACE.md has no table under '## Recorded Builtins'"
while IFS= read -r n; do
    grep -qx -- "$n" "$TMP.d" || { echo "  MISSING: '$n' records an N value but has no k_tape_kinds row"; missing=$((missing + 1)); }
done < "$TMP"
while IFS= read -r n; do
    grep -qx -- "$n" "$TMP" || { echo "  STALE: k_tape_kinds row '$n' names nothing taped"; stale=$((stale + 1)); }
done < "$TMP.d"
[ "$documented" -eq 0 ] || while IFS= read -r n; do
    grep -qx -- "$n" "$TMP.doc" || { echo "  UNDOCUMENTED: '$n' records an N value but docs/TRACE.md's catalogue does not name it"; undocumented=$((undocumented + 1)); }
done < "$TMP"
while IFS= read -r n; do
    grep -qx -- "$n" "$TMP" || { echo "  UNRECORDED: docs/TRACE.md's catalogue names '$n' but nothing records it"; unrecorded=$((unrecorded + 1)); }
done < "$TMP.doc"
echo "tape-kinds: taped=$taped declared=$declared documented=$documented missing=$missing stale=$stale undocumented=$undocumented unrecorded=$unrecorded"
if [ "$taped" -gt 0 ] && [ "$declared" -gt 0 ] && [ "$documented" -gt 0 ] && [ "$missing" -eq 0 ] && [ "$stale" -eq 0 ] &&
   [ "$undocumented" -eq 0 ] && [ "$unrecorded" -eq 0 ]; then
    echo "tape-kinds: PASS"; exit 0
fi
echo "tape-kinds: FAIL"; exit 1
