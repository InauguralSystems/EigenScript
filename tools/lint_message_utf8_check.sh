#!/bin/bash
# lint_message_utf8_check.sh — no lint diagnostic may be malformed UTF-8.
#
# WHY THIS EXISTS (#1048). A lint message is assembled into a fixed 256-byte
# buffer (`LintWarning.message`) and shipped two ways: the human line on
# stderr and `--lint --json`, which `eigenlsp` mirrors into JSON-RPC. W024 was
# the first rule to interpolate an unbounded identifier more than once, and at
# a ~37-character name its message truncated INSIDE an em dash, emitting a
# lone 0xE2. Python's decoder rejects that payload; `jq` hides it by
# substituting U+FFFD. The bug is a property of the CLASS (any rule, any long
# name), so this gate polices the class rather than that one rule:
#
#   1. every registered diagnostic code is driven by a fixture built around a
#      200-character identifier, and every fixture's `--lint --json` output is
#      decoded STRICTLY (`bytes.decode('utf-8')` + `json.loads`) — no jq, which
#      is lenient exactly where this bug lives;
#   2. each fixture must actually PRODUCE its code, so the corpus cannot rot
#      into a set of files that lint clean and pass vacuously;
#   3. the registry is checked in BOTH directions — a code in docs/DIAGNOSTICS.md
#      with no fixture and no pinned exemption fails, and so does a fixture for
#      a code the docs do not list;
#   4. each pinned exemption must still be TRUE: the codes marked unreachable
#      are re-driven and must still come back as a parse error (E002). If a
#      future parser accepts an empty block, this goes red and asks for the
#      real fixture instead of quietly waiving it.
#
# WHAT IT DOES NOT COVER (residuals, stated so the green means something):
#   - It exercises each code ONCE, with one pathological shape. A rule whose
#     message interpolates something else unbounded (a string literal, a path)
#     can still be long in a way no fixture here reaches. The structural half
#     below is what backs that up: every diagnostic in the tree is assembled by
#     lint_vdiag, which truncates through lint_utf8_prefix, so a message can be
#     clipped but never halved mid-character. This script asserts that the
#     chokepoint is still the only writer.
#   - It says nothing about whether a truncated message is still USEFUL. That
#     is the rule author's job (W024 shrinks its identifiers instead, so its
#     remedy clause always survives); tests/test_lint.sh pins it for W024.
#   - The identifier is ASCII because the lexer admits no other kind (isalpha,
#     C locale — verified: a UTF-8 identifier is a syntax error). The multi-byte
#     bytes in play are the ones the MESSAGES themselves carry (em dash,
#     arrows), which is exactly where the bug was.
#
# Cost: ~35 binary invocations for the per-code half plus the sweep's 2000
# (four shapes x 250 lengths x 2 channels) — about 20s on the dev box under
# load, which is the price of a length band one or two values wide.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EIGS="${EIGENSCRIPT_BIN:-$ROOT/src/eigenscript}"
FIXDIR="$ROOT/tests/lint_utf8"
DOCS="$ROOT/docs/DIAGNOSTICS.md"

# Pinned exemptions: code -> reason. Each is re-verified below.
EXEMPT_CODES="E001 W004 W005 W006 W007 W008 W009 W011"
exempt_reason() {
    case "$1" in
    E001) echo "reserved and never emitted (docs/DIAGNOSTICS.md says so); lexer failures surface as E002" ;;
    W004|W005|W006|W007|W008|W009)
          echo "empty block: the parser requires at least one statement, so no source reaches it (re-verified: fixture is E002)" ;;
    W011) echo "'is' in a condition: the parser now rejects it before the linter sees it (re-verified: fixture is E002)" ;;
    *)    echo "" ;;
    esac
}

fail=0
checked=0
note() { printf '%s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; fail=$((fail + 1)); }

if [ ! -x "$EIGS" ]; then echo "FAIL: no binary at $EIGS"; exit 1; fi
if [ ! -d "$FIXDIR" ]; then echo "FAIL: no fixture dir $FIXDIR"; exit 1; fi

# --- the strict decoder (python3, never jq) --------------------------------
decode() {   # $1 = file of raw --lint --json bytes; $2 = code that must appear
    python3 - "$1" "$2" <<'PY'
import json, sys
raw = open(sys.argv[1], 'rb').read()
want = sys.argv[2]
try:
    text = raw.decode('utf-8')
except UnicodeDecodeError as e:
    print("NOT-UTF8 %s" % e); sys.exit(2)
try:
    diags = json.loads(text)
except Exception as e:
    print("NOT-JSON %s: %s" % (type(e).__name__, e)); sys.exit(3)
codes = [d.get('code') for d in diags]
if want and want not in codes:
    print("MISSING %s (got %s)" % (want, ','.join(c or '?' for c in codes) or 'none')); sys.exit(4)
for d in diags:
    m = d.get('message', '')
    if not isinstance(m, str):
        print("NON-STRING message"); sys.exit(5)
    # A message that ends inside a word is allowed (lint_copy_utf8 marks it
    # "..."); one that is not valid UTF-8 is what this gate forbids, and
    # json.loads above already proved that for the whole payload.
    if len(m.encode('utf-8')) > 255:
        print("OVERLONG %d bytes" % len(m.encode('utf-8'))); sys.exit(6)
print("OK %d diagnostic(s)" % len(diags))
PY
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- --selftest: prove each half FAILS on a planted fault ------------------
# A gate that only ever passes is indistinguishable from one that measures
# nothing, and three of the four checks here are cheap to neuter by accident.
if [ "${1:-}" = "--selftest" ]; then
    st_fail=0
    st() {  # $1 = what, $2 = expected-nonzero command output/rc
        if [ "$2" = "0" ]; then echo "SELFTEST-FAIL: $1 did not fire"; st_fail=1
        else echo "  selftest ok: $1 fires"; fi
    }
    # 1. a payload cut mid-UTF-8 (the #1048 byte) must be rejected
    printf '[{"code":"W024","severity":"warning","line":1,"file":"f","message":"x \xe2"}]\n' > "$TMP/st1.json"
    decode "$TMP/st1.json" W024 >/dev/null 2>&1; st "mid-UTF-8 payload" $?
    # 2. a valid payload that lacks the expected code (a fixture gone vacuous)
    printf '[{"code":"W001","severity":"warning","line":1,"file":"f","message":"ok"}]\n' > "$TMP/st2.json"
    decode "$TMP/st2.json" W024 >/dev/null 2>&1; st "fixture that stopped firing its code" $?
    # 3. an over-long message (a rule that outgrew the buffer)
    python3 -c "
import json,sys
json.dump([{'code':'W024','severity':'warning','line':1,'file':'f','message':'x'*300}], open('$TMP/st3.json','w'))
"
    decode "$TMP/st3.json" W024 >/dev/null 2>&1; st "message longer than the 255-byte buffer" $?
    # 4. the structural check: a lint.c whose chokepoint copy is gone
    sed 's/lint_copy_utf8(w->message, sizeof(w->message), rendered);/vsnprintf(w->message, sizeof(w->message), fmt, ap);/' \
        "$ROOT/src/lint.c" > "$TMP/lint_planted.c"
    grep -q 'lint_copy_utf8(w->message, sizeof(w->message), rendered);' "$TMP/lint_planted.c"; st "chokepoint removed from lint_vdiag" $?
    # 5. a NEW rule added to a lint TU with no row in docs/DIAGNOSTICS.md —
    #    the direction that makes this gate cover rules that do not exist yet.
    printf 'lint_warn(ctx, 1, "W099", "a new rule");\n' > "$TMP/newrule.c"
    st_probe="$(grep -ohE '"[WE]0[0-9][0-9]"' "$TMP/newrule.c" | tr -d '"')"
    st_docs="$(grep -oE '^\| *`[WE]0[0-9][0-9]`' "$DOCS" | grep -oE '[WE]0[0-9][0-9]' | sort -u | tr '\n' ' ')"
    case " $st_docs " in
        *" $st_probe "*) st "undocumented new lint code" 0 ;;
        *) st "undocumented new lint code" 1 ;;
    esac
    # 6. an empty fixture dir (the whole corpus deleted) must not read as clean
    mkdir -p "$TMP/emptyfix"
    ls "$TMP/emptyfix"/*.eigs >/dev/null 2>&1; st "empty fixture directory" $?
    [ "$st_fail" -eq 0 ] && { echo "OK: gate self-test — planted faults all caught"; exit 0; }
    echo "FAILED: the gate no longer catches a planted fault"; exit 1
fi

# --- 1/2. every fixture fires its code and decodes strictly ----------------
fixture_codes=""
for f in "$FIXDIR"/*.eigs; do
    [ -e "$f" ] || { bad "no fixtures in $FIXDIR"; break; }
    code="$(basename "$f" .eigs)"
    fixture_codes="$fixture_codes $code"
    "$EIGS" --lint --json "$f" > "$TMP/out.json" 2>/dev/null
    out="$(decode "$TMP/out.json" "$code")"
    rc=$?
    checked=$((checked + 1))
    if [ $rc -ne 0 ]; then bad "$code: $out"; else note "  ok   $code  ($out)"; fi
done

# --- E000: the unreadable-file path, which has no fixture file -------------
"$EIGS" --lint --json "$TMP/no-such-$(printf 'z%.0s' $(seq 1 200)).eigs" > "$TMP/e000.json" 2>/dev/null
out="$(decode "$TMP/e000.json" E000)"; rc=$?
checked=$((checked + 1))
if [ $rc -ne 0 ]; then bad "E000: $out"; else note "  ok   E000 ($out)"; fi
fixture_codes="$fixture_codes E000"

# --- 3. registry, both directions ------------------------------------------
doc_codes="$(grep -oE '^\| *`[WE]0[0-9][0-9]`' "$DOCS" | grep -oE '[WE]0[0-9][0-9]' | sort -u | tr '\n' ' ')"
[ -n "$doc_codes" ] || bad "docs/DIAGNOSTICS.md yielded no codes (matcher broke)"
used_exempt=""
for c in $doc_codes; do
    case " $fixture_codes " in *" $c "*) continue ;; esac
    case " $EXEMPT_CODES " in
        *" $c "*) used_exempt="$used_exempt $c"; note "  wvr  $c  ($(exempt_reason "$c"))" ;;
        *) bad "$c is documented but has neither a fixture nor a pinned exemption" ;;
    esac
done
for c in $fixture_codes; do
    case " $doc_codes " in
        *" $c "*) ;;
        *) bad "fixture $c.eigs has no row in docs/DIAGNOSTICS.md" ;;
    esac
done
# ...and the third direction, which is what makes this cover rules that do not
# exist yet: a code emitted by the lint TUs must be DOCUMENTED, so a new rule
# lands with a row here and then with a fixture. (Residual: it scans the two
# lint TUs for code literals; codes recorded by the parser through
# eigs_record_first_error_code_at — E001/E002/E005 — are covered by the
# docs->fixture direction above, not by this scan.)
src_codes="$(grep -ohE '"[WE]0[0-9][0-9]"' "$ROOT/src/lint.c" "$ROOT/src/lint_host.c" | tr -d '"' | sort -u)"
[ -n "$src_codes" ] || bad "no diagnostic codes found in the lint TUs (matcher broke)"
for c in $src_codes; do
    case " $doc_codes " in
        *" $c "*) ;;
        *) bad "$c is emitted by src/lint*.c but has no row in docs/DIAGNOSTICS.md" ;;
    esac
done

# --- 4. every exemption is still true --------------------------------------
for c in $EXEMPT_CODES; do
    case " $used_exempt " in *" $c "*) ;; *)
        case " $fixture_codes " in
            *" $c "*) bad "$c is exempt AND has a fixture — drop the exemption" ;;
            *) bad "$c is exempt but not in docs/DIAGNOSTICS.md — stale waiver" ;;
        esac ;;
    esac
done
# The unreachable ones must STILL be unreachable: drive the shape and require
# a parse error. If the parser ever accepts it, this fails and asks for a
# real fixture rather than waiving a code that now has a source form.
unreachable_probe() {   # $1 = code, $2 = source
    printf '%s' "$2" > "$TMP/probe.eigs"
    "$EIGS" --lint --json "$TMP/probe.eigs" > "$TMP/probe.json" 2>/dev/null
    if ! grep -q '"code":"E002"' "$TMP/probe.json"; then
        bad "$1: the shape its exemption calls unparseable now parses — write a fixture"
    else
        checked=$((checked + 1))
    fi
}
unreachable_probe W004 'x is 1
if x == 1:
    # empty
print of x
'
unreachable_probe W005 'x is 0
loop while x > 0:
    # empty
print of x
'
unreachable_probe W006 'for k in range of 2:
    # empty
print of 1
'
unreachable_probe W007 'define f() as:
    # empty
print of 1
'
unreachable_probe W008 'try:
    # empty
catch e:
    print of 1
'
unreachable_probe W009 'try:
    print of 1
catch e:
    # empty
print of 2
'
unreachable_probe W011 'x is 1
if x is 1:
    print of 1
'

# --- boundary sweep: no IDENTIFIER LENGTH may break the message ------------
# The single-fixture checks above test one length each, and the defect is
# length-sensitive: the cut walks through the message as the name grows, and
# only the lengths that land it inside a multi-byte character are malformed.
# Measured against v0.43.0, the release before the fix: W015 breaks at a
# 74-character name, W023 at 161-162, W018 at 198-199 — and W024, the one a
# consumer reported, at 56. Each band is one or two lengths wide out of 250, so
# a corpus of hand-picked lengths misses them; this is also why "no
# pre-existing rule is long enough" was wrong as an argument. Both channels are
# decoded: the human line and the JSON payload hold separate copies of the
# bytes and are repaired at different chokepoints.
sweep_out="$(python3 "$ROOT/tools/lint_message_sweep.py" "$EIGS")"
if [ $? -ne 0 ]; then bad "identifier-length sweep: $sweep_out"; else note "  ok   sweep ($sweep_out)"; checked=$((checked + 1)); fi

# --- structural half: the chokepoint is still the only writer --------------
# Every diagnostic is assembled by lint_vdiag, which renders into a scratch
# and copies through lint_copy_utf8/lint_utf8_prefix. A rule that formats
# straight into a message buffer would bypass the boundary check, so no other
# writer may exist. (Matcher residual: it looks for the assembly spellings
# below, not for aliasing through a pointer.)
LINTC="$ROOT/src/lint.c"
if ! grep -q 'lint_copy_utf8(w->message, sizeof(w->message), rendered);' "$LINTC"; then
    bad "lint_vdiag no longer copies the message through lint_copy_utf8"
else
    checked=$((checked + 1))
fi
strays="$(grep -nE '(vs|s)?n?printf\([^)]*->message' "$LINTC" "$ROOT/src/lint_host.c" | grep -v 'lint_copy_utf8' || true)"
if [ -n "$strays" ]; then
    bad "a diagnostic message is formatted outside lint_vdiag: $strays"
else
    checked=$((checked + 1))
fi
if ! grep -q 'lint_utf8_prefix(out, o)' "$ROOT/src/lint_host.c"; then
    bad "lint_json_escape no longer clips on a UTF-8 boundary"
else
    checked=$((checked + 1))
fi

# --- verdict ---------------------------------------------------------------
# Floor, not an exact count: adding a rule (and its fixture) raises it, and
# only REMOVING coverage needs an edit here.
FLOOR=33
if [ "$checked" -lt "$FLOOR" ]; then
    bad "only $checked checks ran, floor is $FLOOR — coverage was removed"
fi
if [ "$fail" -eq 0 ]; then
    echo "OK: lint message UTF-8 gate — $checked checks, $(echo $doc_codes | wc -w) documented codes, $(echo $used_exempt | wc -w) pinned exemptions"
    exit 0
fi
echo "FAILED: $fail problem(s)"
exit 1
