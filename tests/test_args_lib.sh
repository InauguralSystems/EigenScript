#!/bin/bash
# Regression coverage for #1236: lib/args.eigs's parse_args called the
# `args` builtin by its public name, and `import args` binds the module's
# own namespace to that same name in the shared global scope — so by the
# time parse_args ran, `args` resolved to the namespace dict instead of the
# builtin ("cannot call dict"). Every case below runs BOTH through
# `import args` (the regression) and through `load_file of "lib/args.eigs"`
# (the older, always-worked control) in fresh interpreter processes, so a
# regression in either form is caught.
#
# Prints a summary line:
#   ARGS_LIB: N passed, M failed
#
# Exit code: 0 if all pass, 1 if any fail.

set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SRC_DIR="$ROOT_DIR/src"
EIGS="$SRC_DIR/eigenscript"

PASS=0
FAIL=0

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1${2:+ ($2)}"; FAIL=$((FAIL+1)); }

if [ ! -x "$EIGS" ]; then
    echo "  FAIL: eigenscript binary not found at $EIGS"
    echo "ARGS_LIB: 0 passed, 1 failed"
    exit 1
fi

# run_case NAME EXPECTED -- ARGV...
# Runs the same probe program via `import args` and via `load_file`, each
# in its own fresh process, and checks both match EXPECTED.
run_import() {
    "$EIGS" -e 'import args
p is args.parse_args of null
print of (args.get_positional of p)
print of (args.get_flag of [p, "--verbose"])
print of (args.get_opt of [p, "--output", "default"])' "$@" 2>&1
}

run_load() {
    "$EIGS" -e 'load_file of "lib/args.eigs"
p is parse_args of null
print of (get_positional of p)
print of (get_flag of [p, "--verbose"])
print of (get_opt of [p, "--output", "default"])' "$@" 2>&1
}

check_case() {
    local name="$1" expected="$2"
    shift 2
    local iout lout irc lrc
    iout=$(run_import "$@"); irc=$?
    lout=$(run_load "$@"); lrc=$?
    if [ "$irc" -eq 0 ] && [ "$iout" = "$expected" ]; then
        ok "$name (import)"
    else
        fail "$name (import)" "rc=$irc out='$iout' expected='$expected'"
    fi
    if [ "$lrc" -eq 0 ] && [ "$lout" = "$expected" ]; then
        ok "$name (load_file)"
    else
        fail "$name (load_file)" "rc=$lrc out='$lout' expected='$expected'"
    fi
}

# ---- Empty arguments ----
check_case "ARGSLIB01 empty argv" '[]
0
default'

# ---- Positional argument ----
check_case "ARGSLIB02 positional arg" '["input.csv"]
0
default' input.csv

# ---- Boolean flag ----
check_case "ARGSLIB03 boolean flag" '[]
1
default' --verbose

# ---- --key=value ----
check_case "ARGSLIB04 --key=value" '[]
0
a' --output=a

# ---- --key value ----
check_case "ARGSLIB05 --key value" '[]
0
a' --output a

# ---- The issue's own repro: flag + --key=value + positional together ----
check_case "ARGSLIB06 combined (issue repro)" '["input.csv"]
0
a' --output=a input.csv

# ---- Summary ----
echo ""
echo "ARGS_LIB: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
