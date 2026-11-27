echo "[99zg] GAP_ANALYSIS header releases agree with CHANGELOG (#2360)"
# Each header line of docs/GAP_ANALYSIS.md names the release a feature
# arrived in. The release is derived here from CHANGELOG.md: the section
# holding the entry that introduced the feature. The hashing line said 0.9.2
# while CHANGELOG lists sha256/md5 under 0.9.1.
_2360_release_of() {   # anchor regex -> release of its FIRST match from the bottom (oldest)
    _2360_pat="$1" awk '
        BEGIN { pat = ENVIRON["_2360_pat"] }
        /^## \[[0-9]/ { rel = $2; gsub(/[][]/, "", rel) }
        $0 ~ pat { hit = rel }
        END { print hit }' ../CHANGELOG.md
}
_2360_bad=""
while IFS='|' read -r _2360_topic _2360_anchor; do
    _2360_rel=$(_2360_release_of "$_2360_anchor")
    _2360_line=$(grep -m1 -- "^- \*\*${_2360_topic}\*\*:" ../docs/GAP_ANALYSIS.md)
    if [ -z "$_2360_rel" ] || [ -z "$_2360_line" ] ||
       ! printf '%s\n' "$_2360_line" | grep -qF "in ${_2360_rel}"; then
        _2360_bad="$_2360_bad ${_2360_topic}(CHANGELOG ${_2360_rel:-none})"
    fi
done <<'ROWS'
Concurrency|^- \*\*`spawn\(fn\)`\*\*
Pattern matching / lambdas / regex / imports|^- \*\*Pattern matching\*\*:
Hashing|^- \*\*`sha256`\*\* / \*\*`md5`\*\*
LSP|^- \*\*`eigenlsp`\*\*: standalone LSP server
Debugger|^### Graphical Debugger
UI|^### UI Toolkit
STEM|^### STEM Standard Library
Bytecode VM|^### Architecture — Bytecode VM
JIT|^A JIT performance release
ROWS
TOTAL=$((TOTAL + 1))
if [ -z "$_2360_bad" ]; then
    PASS=$((PASS + 1)); echo "  PASS: every GAP_ANALYSIS header release matches CHANGELOG"
else
    FAIL=$((FAIL + 1)); echo "  FAIL: GAP_ANALYSIS header disagrees with CHANGELOG:$_2360_bad"
fi
unset -f _2360_release_of
unset _2360_bad _2360_topic _2360_anchor _2360_rel _2360_line
