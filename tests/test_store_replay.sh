#!/usr/bin/env bash
set -u

EIG=${1:-./eigenscript}
T=$(mktemp -d "${TMPDIR:-/tmp}/eigs-store-replay.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
db="$T/probe.db"
tape="$T/run.tape"

cat > "$T/init.eigs" <<EOF
db is store_open of "$db"
store_put of [db, "config", {"_id":"answer","value":10}]
store_close of db
EOF
cat > "$T/read.eigs" <<EOF
db is store_open of "$db"
r is store_get of [db, "config", "answer"]
print of r.value
store_close of db
EOF
cat > "$T/update.eigs" <<EOF
db is store_open of "$db"
store_update of [db, "config", "answer", {"_id":"answer","value":20}]
store_close of db
EOF

"$EIG" "$T/init.eigs" || exit 1
recorded=$(EIGS_TRACE="$tape" "$EIG" "$T/read.eigs") || exit 1
[ "$recorded" = 10 ] || { echo "FAIL: record printed '$recorded', expected 10"; exit 1; }
"$EIG" "$T/update.eigs" || exit 1

check_refusal() {
    label=$1
    out=$T/out err=$T/err
    EIGS_REPLAY="$tape" EIGS_REPLAY_STRICT=1 "$EIG" "$T/read.eigs" >"$out" 2>"$err"
    rc=$?
    if [ "$rc" -eq 0 ] || [ -s "$out" ] || ! grep -q 'store_open: not replayable under EIGS_REPLAY (store boundary' "$err"; then
        echo "FAIL: $label replay was not refused before live store access (rc=$rc)"
        sed 's/^/stdout: /' "$out"
        sed 's/^/stderr: /' "$err"
        exit 1
    fi
}

check_refusal changed-database
rm -f "$db"
check_refusal missing-database
[ ! -e "$db" ] || { echo "FAIL: missing-database replay recreated the store"; exit 1; }

echo "PASS: store replay refuses changed and missing live databases before access"
