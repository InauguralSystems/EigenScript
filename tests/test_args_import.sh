#!/usr/bin/env bash
# Regression for #1236: import args must not shadow the CLI-args builtin
# used inside parse_args. Fresh processes for import vs load_file controls.
set -euo pipefail
EIGS="${EIGENSCRIPT:-./eigenscript}"
EIGS=$(realpath "$EIGS")
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/tests/lsan_classify.sh" || exit 1
cd "$ROOT"

pass=0
fail=0
ok() { echo "  PASS: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1 ($2)"; fail=$((fail+1)); }
# Verdicts come from shell matchers, not `printf | grep -q`: under pipefail an
# early-exiting grep can SIGPIPE the printf and flip a true match to false
# (#1122; tools/pipefail_verdict_check.sh pins these one-liners to the byte).
str_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1 ; }
str_has_line() { case $'\n'"$1"$'\n' in *$'\n'"$2"$'\n'*) return 0 ;; esac; return 1 ; }

# Keep the argv regression's program outside the checkout: tests must not
# create developer-visible files in the source tree.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/eigs-args-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PROBE="$TMP/args_probe.eigs"
cat > "$PROBE" <<'EOF'
import args
p is args.parse_args of null
print of (args.get_opt of [p, "--out", ""])
print of (args.get_positional of p)
print of p
EOF

# --- import path: positional + --key=value ---
set +e
OUT=$("$EIGS" -e 'import args
p is args.parse_args of null
print of (args.get_opt of [p, "--output", "default"])
print of (args.get_positional of p)' --output=a input.csv 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" 'a' && str_has_line "$OUT" '["input.csv"]'; then
  ok "import args: --key=value + positional"
else
  bad "import args: --key=value + positional" "rc=$RC out=$OUT"
fi

# --- import path: --key value and boolean flag ---
set +e
OUT=$("$EIGS" -e 'import args
p is args.parse_args of null
print of (args.get_opt of [p, "--output", "default"])
print of (args.get_flag of [p, "--verbose"])
print of (args.get_positional of p)' --output b --verbose 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" 'b' && str_has_line "$OUT" 'true' && str_has_line "$OUT" '[]'; then
  ok "import args: --key value + boolean flag"
else
  bad "import args: --key value + boolean flag" "rc=$RC out=$OUT"
fi

# --- import path: empty argv ---
set +e
OUT=$("$EIGS" -e 'import args
p is args.parse_args of null
print of (args.get_positional of p)' 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" '[]'; then
  ok "import args: empty arguments"
else
  bad "import args: empty arguments" "rc=$RC out=$OUT"
fi

# --- load_file control still works ---
set +e
OUT=$("$EIGS" -e 'load_file of "lib/args.eigs"
p is parse_args of null
print of (get_opt of [p, "--output", "default"])
print of (get_positional of p)' --output=a input.csv 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" 'a' && str_has_line "$OUT" '["input.csv"]'; then
  ok "load_file args: --key=value + positional"
else
  bad "load_file args: --key=value + positional" "rc=$RC out=$OUT"
fi

# --- private capture is not projected on import ---
set +e
OUT=$("$EIGS" -e 'import args
print of (keys of args)' 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && ! str_has "$OUT" '_args_cli'; then
  ok "import args: _args_cli stays private"
else
  bad "import args: _args_cli stays private" "rc=$RC out=$OUT"
fi

# --- #2244: repeated options use last-value-wins for both spellings ---
for spelling in spaced equals; do
  if [ "$spelling" = spaced ]; then
    set -- --out a --out b
  else
    set -- --out=a --out=b
  fi
  set +e
  OUT=$("$EIGS" "$PROBE" "$@" 2>&1)
  RC=$?
  set -e
  CLASS=0
  lsan_classify "$OUT" || CLASS=$?
  if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" 'b' && str_has_line "$OUT" '[["positional", []], ["--out", "b"]]'; then
    ok "repeated option ($spelling): last value and one entry"
  else
    bad "repeated option ($spelling): last value and one entry" "rc=$RC out=$OUT"
  fi
done

# --- #2244: -- ends option parsing ---
set +e
OUT=$("$EIGS" "$PROBE" -- --notaflag file 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" '["--notaflag", "file"]' && str_has_line "$OUT" '[["positional", ["--notaflag", "file"]]]'; then
  ok "double dash: remaining arguments are positional"
else
  bad "double dash: remaining arguments are positional" "rc=$RC out=$OUT"
fi

# --- #2244: lone - is positional ---
set +e
OUT=$("$EIGS" "$PROBE" - x 2>&1)
RC=$?
set -e
CLASS=0
lsan_classify "$OUT" || CLASS=$?
if [ "$RC" -eq 0 ] && [ "$CLASS" -eq 2 ] && str_has_line "$OUT" '["-", "x"]' && str_has_line "$OUT" '[["positional", ["-", "x"]]]'; then
  ok "lone dash: positional"
else
  bad "lone dash: positional" "rc=$RC out=$OUT"
fi

echo "ARGS_IMPORT_PASS=$pass FAIL=$fail"
if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "ARGS_IMPORT_ALL_PASS"
