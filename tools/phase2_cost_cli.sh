#!/usr/bin/env bash
set -eu
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
tmp=${TMPDIR:-/tmp}/phase2-cost-cli.$$
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/tree/tools" "$tmp/tree/tests/phase2" "$tmp/tree/bench" "$tmp/bin"
mkdir -p "$tmp/novg"
ln -s /usr/bin/python3 "$tmp/novg/python3"
ln -s /usr/bin/nm "$tmp/novg/nm"
ln -s /usr/bin/git "$tmp/novg/git"
ln -s /usr/bin/dirname "$tmp/novg/dirname"
cp "$repo/tools/phase2_cost.sh" "$repo/tools/phase2_cost_declarations.py" "$tmp/tree/tools/"
cp "$repo/src/eigenscript" "$tmp/tree/base"
cp "$repo/src/eigenscript" "$tmp/tree/cand"
: >"$tmp/tree/tests/phase2/cost_expect.txt"
: >"$tmp/tree/tests/phase2/oracle_expect.txt"
printf 'print of 1\n' >"$tmp/tree/bench/one.eigs"
cat >"$tmp/tree/codspeed.yml" <<'EOF'
    exec: ./src/eigenscript bench/one.eigs
EOF
(cd "$tmp/tree" && git init -q && git add . && git add -f bench/one.eigs)

cat >"$tmp/bin/valgrind" <<'EOF'
#!/usr/bin/env bash
set -eu
out=
for arg do case $arg in --cachegrind-out-file=*) out=${arg#*=};; esac; done
[ -n "$out" ] || exit 90
if [ "${PHASE2_FAKE_CRASH:-0}" = 1 ]; then exit 7; fi
case "$*" in
  *'/cand '*) printf 'summary: %s\n' "${PHASE2_FAKE_CAND_IR:-100}" >"$out"; printf '%s\n' "${PHASE2_FAKE_CAND_OUTPUT:-same}";;
  *) printf 'summary: %s\n' "${PHASE2_FAKE_BASE_IR:-100}" >"$out"; printf '%s\n' "${PHASE2_FAKE_BASE_OUTPUT:-same}";;
esac
EOF
chmod +x "$tmp/bin/valgrind"

pass=0
run_case() {
  label=$1 code=$2 message=$3 path=$4; shift 4
  set +e
  (cd "$path" && "$@") >"$tmp/out" 2>&1
  rc=$?
  set -e
  if [ "$rc" -ne "$code" ] || ! grep -F "$message" "$tmp/out" >/dev/null; then
    printf 'FAIL: %s expected rc=%s message=%s; got rc=%s\n' "$label" "$code" "$message" "$rc"
    cat "$tmp/out"
    exit 1
  fi
  pass=$((pass + 1))
}

# Every case invokes the public command line in the scratch checkout.
run_case missing-argument 2 'supply <base-bin> <cand-bin>' "$tmp/tree" bash tools/phase2_cost.sh
run_case missing-valgrind 2 'valgrind is required' "$tmp/tree" /usr/bin/env PATH="$tmp/novg" /bin/bash tools/phase2_cost.sh base cand
cp "$tmp/tree/codspeed.yml" "$tmp/codspeed"
printf '%s\n' '    exec: ./src/eigenscript bench/ghost.eigs' >>"$tmp/tree/codspeed.yml"
run_case ghost-entry 2 'coverage' "$tmp/tree" env PATH="$tmp/bin:/usr/bin:/bin" bash tools/phase2_cost.sh base cand
cp "$tmp/codspeed" "$tmp/tree/codspeed.yml"
run_case crashing-workload 2 'rc=7' "$tmp/tree" env PHASE2_FAKE_CRASH=1 PATH="$tmp/bin:/usr/bin:/bin" bash tools/phase2_cost.sh base cand
run_case differing-output 2 'output differs' "$tmp/tree" env PHASE2_FAKE_CAND_OUTPUT=different PATH="$tmp/bin:/usr/bin:/bin" bash tools/phase2_cost.sh base cand
run_case missing-binary 2 'binary path does not exist' "$tmp/tree" env PATH="$tmp/bin:/usr/bin:/bin" bash tools/phase2_cost.sh absent cand
printf '#!/bin/sh\nexit 0\n' >"$tmp/tree/not-elf"; chmod +x "$tmp/tree/not-elf"
run_case non-elf 2 'not an ELF executable' "$tmp/tree" env PATH="$tmp/bin:/usr/bin:/bin" bash tools/phase2_cost.sh not-elf cand
run_case verdict 1 'OVER' "$tmp/tree" env PHASE2_FAKE_CAND_IR=101 PATH="$tmp/bin:/usr/bin:/bin" bash tools/phase2_cost.sh base cand

# RED plants replace each reviewed call site, then exercise that exact CLI path.
for plant in ghost crash; do
  cp "$repo/tools/phase2_cost.sh" "$tmp/tree/tools/phase2_cost.sh"
  if [ "$plant" = ghost ]; then
    python3 - "$tmp/tree/tools/phase2_cost.sh" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); s=s.replace("instrument_fail('CodSpeed workload coverage missing=%s stale=%s' %", "sys.exit('phase2-cost: FAIL: CodSpeed workload coverage missing=%s stale=%s' %", 1); p.write_text(s)
PY
    cp "$tmp/codspeed" "$tmp/tree/codspeed.yml"; printf '%s\n' '    exec: ./src/eigenscript bench/ghost.eigs' >>"$tmp/tree/codspeed.yml"
    args='env PATH='"$tmp/bin"':/usr/bin:/bin bash tools/phase2_cost.sh base cand'
  else
    python3 - "$tmp/tree/tools/phase2_cost.sh" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); s=s.replace("instrument_fail('%s %s %s rc=%d (see %s)' %", "sys.exit('phase2-cost: FAIL: %s %s %s rc=%d (see %s)' %", 1); p.write_text(s)
PY
    cp "$tmp/codspeed" "$tmp/tree/codspeed.yml"
    args='env PHASE2_FAKE_CRASH=1 PATH='"$tmp/bin"':/usr/bin:/bin bash tools/phase2_cost.sh base cand'
  fi
  set +e; (cd "$tmp/tree" && sh -c "$args") >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 1 ] || { echo "FAIL: $plant plant did not expose exit 1"; exit 1; }
  pass=$((pass + 1))
done
printf 'phase2-cost-cli-self-test: cases=%d instrument=7 verdict=1 plants=ghost:red,crash:red PASS\n' "$pass"
