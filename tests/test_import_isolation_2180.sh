#!/usr/bin/env bash
echo "PLAN: 5"
set -u
EIGS=${EIGS:-$(cd "$(dirname "$0")/.." && pwd)/src/eigenscript}
W=$(mktemp -d)
# The runtime reports a module by its resolved path; on macOS mktemp returns
# /var/folders/... while the real path is /private/var/... (a symlink).
W=$(cd "$W" && pwd -P)
trap 'rm -rf "$W"' EXIT

cat >"$W/dep.eigs" <<'EIG'
dep_value is 7
EIG
cat >"$W/isolated.eigs" <<'EIG'
import dep
own_value is 11
configured is null
define configure(v) as:
    configured is v
define valid() as:
    return own_value + dep.dep_value + (len of [1, 2])
define configured_value() as:
    return configured
define leak_after(n) as:
    total is 0
    for i in range of n:
        total is total + i
    if n > 100:
        return importer_only
    return total
define osr_leak() as:
    total is 0
    for i in range of 200:
        total is total + i
        if i == 150:
            return importer_only
    return total
EIG
cat >"$W/control.eigs" <<'EIG'
importer_only is 2180
import isolated
print of (isolated.valid of null)
isolated.configure of importer_only
print of (isolated.configured_value of null)
EIG
control=$($EIGS "$W/control.eigs" 2>&1); crc=$?
if [ "$crc" -eq 0 ] && [ "$control" = $'20\n2180' ]; then
    echo "PASS: module resolves its own binding, own import and stdlib; explicit setter configures it"
else
    echo "FAIL: isolated module control (rc=$crc): $control"
fi

cat >"$W/vm.eigs" <<'EIG'
importer_only is 2180
import isolated
print of (isolated.leak_after of 101)
EIG
cat >"$W/jit.eigs" <<'EIG'
importer_only is 2180
import isolated
for warm in range of 20:
    isolated.leak_after of 100
print of (isolated.leak_after of 101)
EIG
cat >"$W/osr.eigs" <<'EIG'
importer_only is 2180
import isolated
print of (isolated.osr_leak of null)
EIG
for tier in vm jit osr; do
    case "$tier" in
        vm) out=$(EIGS_JIT_OFF=1 "$EIGS" "$W/vm.eigs" 2>&1); rc=$? ;;
        jit) out=$(EIGS_JIT_HOT=1 EIGS_JIT_ENTRY_THRESHOLD=1 "$EIGS" "$W/jit.eigs" 2>&1); rc=$? ;;
        osr) out=$(EIGS_JIT_HOT=1 EIGS_JIT_OSR_THRESHOLD=1 "$EIGS" "$W/osr.eigs" 2>&1); rc=$? ;;
    esac
    if [ "$rc" -ne 0 ] \
       && grep -Fq "undefined variable 'importer_only' in imported module '$W/isolated.eigs'" <<< "$out" \
       && grep -Fq "pass the value explicitly" <<< "$out"; then
        echo "PASS: $tier isolates importer globals and gives the module/pass-explicitly diagnostic"
    else
        echo "FAIL: $tier import isolation diagnostic (rc=$rc): $out"
    fi
done

cat >"$W/loaded.eigs" <<'EIG'
print of importer_only
EIG
cat >"$W/load_control.eigs" <<'EIG'
importer_only is 2180
load_file of "loaded.eigs"
EIG
loaded=$($EIGS "$W/load_control.eigs" 2>&1); lrc=$?
if [ "$lrc" -eq 0 ] && [ "$loaded" = 2180 ]; then
    echo "PASS: load_file retains its shared scope"
else
    echo "FAIL: load_file contract changed (rc=$lrc): $loaded"
fi
