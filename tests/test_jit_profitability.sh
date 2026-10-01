#!/usr/bin/env bash
set -u
EIGS="${EIGS:-$(cd "$(dirname "$0")/../src" && pwd)/eigenscript}"
PROG="$(cd "$(dirname "$0")" && pwd)/test_jit_profitability.eigs"

run_checked() {
    local result_name=$1 output rc
    shift
    output=$(env "$@" "$EIGS" "$PROG" 2>&1); rc=$?
    printf -v "$result_name" '%s' "$output"
    if ((rc != 0)); then
        printf '%s\n' "$output"
        echo "FAIL: eigenscript exited with status $rc"
        exit 1
    fi
    if printf '%s\n' "$output" | grep -qE '(AddressSanitizer|LeakSanitizer|UndefinedBehaviorSanitizer|runtime error:|Sanitizer:DEADLYSIGNAL)'; then
        printf '%s\n' "$output"
        echo "FAIL: sanitizer diagnostic in eigenscript output"
        exit 1
    fi
}

base=''
off=''
run_checked base EIGS_JIT_DUMP_SELECTION=1 EIGS_JIT_ENTRY_THRESHOLD=2 EIGS_JIT_OSR_THRESHOLD=100
run_checked off EIGS_JIT_DUMP_SELECTION=1 EIGS_JIT_ENTRY_THRESHOLD=2 EIGS_JIT_OSR_THRESHOLD=100 EIGS_JIT_OFF=1

if printf '%s\n' "$base" | grep -q '^JIT selection:'; then
    printf '%s\n' "$base" | grep -q "chunk='tiny_entry'.*scope=entry.*decision=reject" || { echo "FAIL: tiny entry was not rejected"; exit 1; }
    printf '%s\n' "$base" | grep -q "chunk='large_entry'.*scope=entry.*decision=accept" || { echo "FAIL: large entry was not accepted"; exit 1; }
    printf '%s\n' "$base" | grep -q "chunk='dict_ic_entry'.*scope=entry.*dict_ic=1.*decision=accept" || { echo "FAIL: short dict-IC entry was not accepted"; exit 1; }
    printf '%s\n' "$base" | grep -q "chunk='osr_entry'.*scope=osr.*decision=accept" || { echo "FAIL: OSR was not independently accepted"; exit 1; }
else
    case "$(uname -m)" in
        arm64|aarch64) echo "SKIP: JIT selection assertions (JIT unavailable on ARM64)" ;;
        *) echo "FAIL: JIT emitted no selection rows"; exit 1 ;;
    esac
fi
printf '%s\n' "$base" | grep -q "All tests passed" || { echo "FAIL: selected-tier output changed"; exit 1; }
printf '%s\n' "$off" | grep -q "All tests passed" || { echo "FAIL: EIGS_JIT_OFF output changed"; exit 1; }
if printf '%s\n' "$off" | grep -q '^JIT selection:'; then echo "FAIL: EIGS_JIT_OFF selected a tier"; exit 1; fi
echo "PASS: jit_profitability: OK"
