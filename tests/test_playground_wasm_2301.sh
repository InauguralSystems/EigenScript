#!/usr/bin/env bash
# #2301: the built playground must link every C symbol it can reach, and an
# `import` must report an EigenScript error instead of killing the module.
#
# The deployed playground (web/build.sh with -sERROR_ON_UNDEFINED_SYMBOLS=0 and
# a hand-written source list that had lost src/eigs_embed.c) linked with
# eigs_source_lookup undefined; emcc planted abort("missing function: ...")
# and every program containing `import` threw RuntimeError: Aborted(...),
# leaving the page's runtime dead. tools/playground_smoke.cjs runs no import,
# so it stayed green. This runs in pages.yml after the build, before the
# receipt, so the required `playground` check needs it.
#
# Two witnesses, independent of each other:
#   1. static:  eigs.js holds no `missing function:` stub. Catches ANY
#               undefined symbol, including one no program below reaches,
#               even if the link flag is flipped back to =0.
#   2. dynamic: import programs return rc 1 with the import error on stderr
#               and no Aborted(, and the SAME module then still runs a plain
#               program with exact output (the module was not killed, and
#               the error did not latch). Same for `exit of N`: web/eigs_wasm.c
#               reset no per-run state, so after one runtime error every later
#               run in the page returned 1 with no output until a reload.
#
# Usage: bash tests/test_playground_wasm_2301.sh [dist-dir]  (default web/dist)
# Needs node. Exit 0 pass, 1 fail.
set -u
DIST=$(cd "${1:-web/dist}" 2>/dev/null && pwd) || { echo "FAIL: dist dir '${1:-web/dist}' not found"; exit 1; }
for f in eigs.js eigs.wasm; do
    [ -s "$DIST/$f" ] || { echo "FAIL: $DIST/$f missing or empty"; exit 1; }
done
command -v node >/dev/null || { echo "FAIL: node not found"; exit 1; }

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# 1. static witness
stubs=$(grep -o 'missing function: [A-Za-z0-9_$]*' "$DIST/eigs.js" | sort -u)
if [ -z "$stubs" ]; then
    ok "eigs.js has no 'missing function:' stub (every reachable C symbol is linked)"
else
    bad "eigs.js links undefined symbols as abort stubs: $(printf '%s' "$stubs" | tr '\n' ' ')"
fi

# 2. dynamic witness
WORK=$(mktemp -d "${TMPDIR:-/tmp}/eigs-pg2301.XXXXXX") || exit 1
trap 'rm -rf "$WORK"' EXIT
cp "$DIST/eigs.js" "$WORK/eigs.cjs"
cat > "$WORK/run.cjs" <<'EOF'
'use strict';
const path = require('path');
const [, , work, dist] = process.argv;
const EigsModule = require(path.join(work, 'eigs.cjs'));
// [source, want rc (null: any), want stdout, want first stderr line prefix (null: no stderr)]
// Each state-setting run is followed by a plain run in the SAME module: a run
// is a fresh session, so an error or an `exit of N` must not carry over.
const cases = [
  ['import math\nprint of 1', 1, '', "Error <playground>:1: import: cannot read 'math.eigs"],
  ['print of (6 * 7)', 0, '42', null],
  ['import no_such_module_2301\nprint of 1', 1, '', "Error <playground>:1: import: cannot read 'no_such_module_2301.eigs"],
  ['print of "after an error"', 0, 'after an error', null],
  ['exit of 3', null, '', null],
  ['print of "after exit"', 0, 'after exit', null],
];
let out = [], err = [];
EigsModule({
  print: (t) => out.push(t),
  printErr: (t) => err.push(t),
  locateFile: (f) => path.join(dist, f),
}).then((M) => {
  const run = M.cwrap('eigs_run_source', 'number', ['string']);
  for (const [src, wantRc, wantOut, wantErr] of cases) {
    out = []; err = [];
    let rc;
    try { rc = run(src); } catch (e) { rc = 'threw ' + String(e).slice(0, 200); }
    const got = out.join('\n');
    const first = err.length ? err[0] : null;
    const aborted = err.some((l) => l.includes('Aborted('));
    const errOk = wantErr === null ? err.length === 0 : (first !== null && first.startsWith(wantErr));
    const tag = JSON.stringify(src);
    if ((wantRc === null ? typeof rc === 'number' : rc === wantRc) && got === wantOut && errOk && !aborted) {
      console.log(`PASS: ${tag} -> rc=${rc} out=${JSON.stringify(got)}${first ? ' err=' + JSON.stringify(first.slice(0, 90)) : ''}`);
    } else {
      console.log(`FAIL: ${tag}: rc=${rc} out=${JSON.stringify(got)} err=${JSON.stringify(err.slice(0, 3))} ` +
                  `want rc=${wantRc} out=${JSON.stringify(wantOut)} err^=${JSON.stringify(wantErr)}`);
    }
  }
  process.exit(0);
}).catch((e) => { console.log('FAIL: runtime did not initialise: ' + e); process.exit(0); });
EOF
dyn=$(node "$WORK/run.cjs" "$WORK" "$DIST" 2>&1); nrc=$?
[ "$nrc" -eq 0 ] || bad "node driver exited $nrc"
while IFS= read -r line; do
    case "$line" in
        PASS:*) ok "${line#PASS: }" ;;
        FAIL:*) bad "${line#FAIL: }" ;;
        *) [ -n "$line" ] && echo "  $line" ;;
    esac
done <<< "$dyn"

# 1 static + 6 dynamic. A driver that died early prints fewer rows: red.
PLAN=7
echo "PLAN: $PLAN"
echo "test_playground_wasm_2301: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$PASS" -eq "$PLAN" ] || exit 1
exit 0
