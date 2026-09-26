#!/bin/bash
# Bundled editor grammars (#1233 numbers, #1234 report/report_value, #1241
# escaped f-string braces), checked by the REAL highlighting engines, not by
# reading the patterns: Vim's syntax engine (headless synID) and VS Code's
# TextMate engine (vscode-textmate + vscode-oniguruma, the libraries VS Code
# itself tokenizes with). Each row names a token by its line and text and
# requires EVERY character of it to carry the expected group/scope, so a
# partial match (`5` of `.5`) fails.
#
# Either half SKIPs by name when its engine is absent: vim not on PATH, or the
# two npm modules not resolvable (set EIGS_TM_NODE_MODULES to a node_modules
# directory that holds them). Cwd-independent. Prints PASS:/FAIL:/SKIP: lines;
# exit 0 iff no FAIL. The runner ([80b]) counts each SKIP line as a skip.
#
# CI coverage: the Vim half runs only on lanes with vim on PATH (the macOS
# lane); no CI lane installs the TextMate engine, so CI does NOT check the
# VS Code grammar. Run that half locally:
#   npm install --prefix DIR vscode-textmate vscode-oniguruma
#   EIGS_TM_NODE_MODULES=DIR/node_modules bash tests/test_editor_grammars.sh
#
# EIGS_GRAMMAR_ROOT overrides the directory holding vim/ and vscode/ (default:
# the repo's editors/), so the old grammars can be checked by the same rows.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${EIGS_GRAMMAR_ROOT:-$TESTS_DIR/../editors}"
VIM_SYN="$ROOT/vim/syntax/eigenscript.vim"
TM_JSON="$ROOT/vscode/syntaxes/eigenscript.tmLanguage.json"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs_grammar.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
FAIL=0

# The fixture. Tabs are not used, so a column is a byte offset.
cat > "$TMP/fixture.eigs" <<'EIGS'
a is 0xFF + 0X10 + .5 + 1. + 1.25 + 1e5 + 2.5E-3 + 3e+2
v2 is x1 + abc123
r is report of v2
q is report_value of v2
z is report_value_extra of v2
s is "report 0xFF .5 \{"
# report_value 0xFF .5
w is what is v2
f1 is f"lit \{name\} {report of v2} {0xFF} \\{v2}"
p is "a\"b" + f"q\"r"
EIGS

# Rows: line | token text | occurrence (1 = first on the line) | vim group
# (innermost synID name, "-" = none) | TextMate scope that must be present on
# every character ("!scope" = must be absent from every character).
cat > "$TMP/rows.txt" <<'ROWS'
1|0xFF|1|eigsNumber|constant.numeric.eigenscript
1|0X10|1|eigsNumber|constant.numeric.eigenscript
1|.5|1|eigsNumber|constant.numeric.eigenscript
1|1.|1|eigsNumber|constant.numeric.eigenscript
1|1.25|1|eigsNumber|constant.numeric.eigenscript
1|1e5|1|eigsNumber|constant.numeric.eigenscript
1|2.5E-3|1|eigsNumber|constant.numeric.eigenscript
1|3e+2|1|eigsNumber|constant.numeric.eigenscript
2|v2|1|-|!constant.numeric.eigenscript
2|x1|1|-|!constant.numeric.eigenscript
2|abc123|1|-|!constant.numeric.eigenscript
3|report|1|eigsInterrogative|support.function.interrogative.eigenscript
4|report_value|1|eigsInterrogative|support.function.interrogative.eigenscript
5|report_value_extra|1|-|!support.function.interrogative.eigenscript
6|report|1|eigsString|string.quoted.double.eigenscript
6|0xFF|1|eigsString|!constant.numeric.eigenscript
6|.5|1|eigsString|!constant.numeric.eigenscript
7|report_value|1|eigsComment|comment.line.number-sign.eigenscript
7|0xFF|1|eigsComment|!constant.numeric.eigenscript
8|what|1|eigsInterrogative|support.function.interrogative.eigenscript
9|\{|1|eigsFEscape|constant.character.escape.eigenscript
9|name|1|eigsFString|!meta.embedded.expression.eigenscript
9|\}|1|eigsFEscape|constant.character.escape.eigenscript
9|report|1|eigsInterrogative|support.function.interrogative.eigenscript
9|0xFF|1|eigsNumber|constant.numeric.eigenscript
9|\\|1|eigsFEscape|constant.character.escape.eigenscript
9|v2|2|eigsInterp|meta.embedded.expression.eigenscript
10|\"|1|eigsEscape|constant.character.escape.eigenscript
10|\"|2|eigsFEscape|constant.character.escape.eigenscript
ROWS

# Resolve every row to "line|startcol(1-based)|len|vimgroup|scope".
awk -F'|' -v fx="$TMP/fixture.eigs" '
    BEGIN { n = 0; while ((getline l < fx) > 0) src[++n] = l }
    {
        line = src[$1]; tok = $2; occ = $3; pos = 0; from = 1
        for (k = 0; k < occ; k++) {
            i = index(substr(line, from), tok)
            if (i == 0) { pos = 0; break }
            pos = from + i - 1; from = pos + 1
        }
        if (pos == 0) { print "UNRESOLVED|" $0; next }
        print $1 "|" pos "|" length(tok) "|" $4 "|" $5 "|" tok
    }' "$TMP/rows.txt" > "$TMP/resolved.txt"
if grep -q '^UNRESOLVED' "$TMP/resolved.txt"; then
    echo "  FAIL: fixture rows resolve ($(grep '^UNRESOLVED' "$TMP/resolved.txt" | head -1))"
    exit 1
fi
NROWS=$(wc -l < "$TMP/resolved.txt" | tr -d ' ')

# ---- Vim --------------------------------------------------------------
if ! command -v vim >/dev/null 2>&1; then
    echo "  SKIP: vim grammar (vim not on PATH)"
else
    cat > "$TMP/probe.vim" <<VIM
syntax on
source $VIM_SYN
let out = []
for row in readfile('$TMP/resolved.txt')
  let f = split(row, '|', 1)
  let names = {}
  for c in range(str2nr(f[1]), str2nr(f[1]) + str2nr(f[2]) - 1)
    let nm = synIDattr(synID(str2nr(f[0]), c, 1), 'name')
    let names[nm == '' ? '-' : nm] = 1
  endfor
  call add(out, join(sort(keys(names)), ','))
endfor
call writefile(out, '$TMP/vim_out.txt')
qa!
VIM
    vim -N -u NONE -i NONE -es -S "$TMP/probe.vim" "$TMP/fixture.eigs" </dev/null >/dev/null 2>&1
    if [ ! -s "$TMP/vim_out.txt" ]; then
        echo "  FAIL: vim grammar probe produced no output"; FAIL=$((FAIL + 1))
    else
        vfail=0; i=0
        while IFS='|' read -r ln col len vg scope tok; do
            i=$((i + 1)); got=$(sed -n "${i}p" "$TMP/vim_out.txt")
            if [ "$got" != "$vg" ]; then
                echo "  FAIL: vim line $ln '$tok': want $vg, got $got"; vfail=$((vfail + 1))
            fi
        done < "$TMP/resolved.txt"
        if [ "$vfail" -eq 0 ]; then
            echo "  PASS: vim grammar: all $NROWS token rows"
        else
            FAIL=$((FAIL + 1))
        fi
    fi
fi

# ---- VS Code (TextMate) -----------------------------------------------
if ! command -v node >/dev/null 2>&1; then
    echo "  SKIP: VS Code grammar (node not on PATH)"
else
    cat > "$TMP/probe.js" <<'JS'
const path = require('path'), fs = require('fs');
const [,, grammarPath, fixture, rowsPath, modDir] = process.argv;
const req = (m) => modDir ? require(path.join(modDir, m)) : require(m);
let vt, onig;
try { vt = req('vscode-textmate'); onig = req('vscode-oniguruma'); }
catch (e) { console.log('SKIPMOD'); process.exit(0); }
const wasm = fs.readFileSync(path.join(path.dirname(
    modDir ? require.resolve(path.join(modDir, 'vscode-oniguruma'))
           : require.resolve('vscode-oniguruma')), 'onig.wasm')).buffer;
onig.loadWASM(wasm).then(() => {
  const reg = new vt.Registry({
    onigLib: Promise.resolve({ createOnigScanner: p => new onig.OnigScanner(p),
                               createOnigString: s => new onig.OnigString(s) }),
    loadGrammar: async () => vt.parseRawGrammar(fs.readFileSync(grammarPath, 'utf8'), grammarPath),
  });
  return reg.loadGrammar('source.eigenscript');
}).then(g => {
  const lines = fs.readFileSync(fixture, 'utf8').split('\n');
  let st = vt.INITIAL; const perLine = [];
  for (const l of lines) { const r = g.tokenizeLine(l, st); perLine.push(r.tokens); st = r.ruleStack; }
  for (const row of fs.readFileSync(rowsPath, 'utf8').trim().split('\n')) {
    const [ln, col, len, , scope, tok] = row.split('|');
    const neg = scope.startsWith('!'), want = neg ? scope.slice(1) : scope;
    let ok = true;
    for (let c = +col - 1; c < +col - 1 + +len; c++) {
      const t = perLine[+ln - 1].find(t => c >= t.startIndex && c < t.endIndex);
      const has = t && t.scopes.includes(want);
      if (neg ? has : !has) ok = false;
    }
    console.log((ok ? 'OK ' : 'BAD ') + ln + ' ' + tok + ' ' + scope);
  }
});
JS
    tm_out=$(node "$TMP/probe.js" "$TM_JSON" "$TMP/fixture.eigs" "$TMP/resolved.txt" \
             "${EIGS_TM_NODE_MODULES:-}" 2>&1)
    if [ "$tm_out" = "SKIPMOD" ]; then
        echo "  SKIP: VS Code grammar (vscode-textmate/vscode-oniguruma not found; set EIGS_TM_NODE_MODULES)"
    else
        n_ok=$(grep -c '^OK ' <<< "$tm_out")
        if [ "$n_ok" -eq "$NROWS" ]; then
            echo "  PASS: VS Code grammar: all $NROWS token rows"
        else
            FAIL=$((FAIL + 1))
            echo "  FAIL: VS Code grammar: $n_ok/$NROWS token rows"
            grep -v '^OK ' <<< "$tm_out" | head -12 | sed 's/^/      /'
        fi
    fi
fi

[ "$FAIL" -eq 0 ]
