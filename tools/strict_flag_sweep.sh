#!/usr/bin/env bash
# Flip each declared strict-flag reader in an isolated copy and require its
# independently named check to fail.  This is deliberately not in the suite:
# it performs one complete rebuild per reader.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = --selftest ]; then
    awk -F '\t' 'NR > 1 && NF == 4 { n++ } END { exit !(n == 15) }' tests/strict_flag_readers.tsv || { echo "FAIL: strict flag sweep table population"; exit 1; }
    echo "PASS: strict flag sweep derives 15 declared reader plants"
    exit 0
fi
START=$(date +%s)
TMP=${TMPDIR:-/tmp}/eigs-strict-flag-sweep.$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP"
examined=0; red=0
while IFS=$'\t' read -r file reader flag check; do
    [ "$file" = file ] && continue
    [ -n "$file" ] || continue
    examined=$((examined + 1)); copy="$TMP/$examined"
    mkdir -p "$copy"
    (cd "$ROOT" && tar --exclude=.git --exclude=editors/vscode/node_modules -cf - .) | (cd "$copy" && tar -xf -)
    other=arithmetic; [ "$flag" = arithmetic ] && other=guards
    python3 - "$copy/$file" "$reader" "$flag" "$other" <<'PY'
import re,sys
p,reader,old,new=sys.argv[1:]; s=open(p).read()
if reader.isupper():
 m=re.search(r'#define\s+'+re.escape(reader)+r'\b',s); assert m
 end=s.find('\n',m.start())
 while end>0 and s[end-1]=='\\': end=s.find('\n',end+1)
 a,b=m.start(),end
else:
 m=re.search(r'\b'+re.escape(reader)+r'\s*\([^;{}]*\)\s*\{',s,re.S); assert m
 a=m.start(); depth=0; b=None
 for i,c in enumerate(s[m.end()-1:],m.end()-1):
  if c=='{': depth+=1
  elif c=='}':
   depth-=1
   if depth==0: b=i+1; break
 assert b
part=s[a:b]; needle='g_strict_'+old; assert part.count(needle)==1,(reader,part.count(needle))
s=s[:a]+part.replace(needle,'g_strict_'+new,1)+s[b:]
open(p,'w').write(s)
PY
    # Re-declare the planted source truth so the inventory check cannot be the
    # reason for red; the named behavioral check must kill the plant.
    python3 - "$copy/tests/strict_flag_readers.tsv" "$file" "$reader" "$other" <<'PY'
import sys
p,f,r,new=sys.argv[1:]; lines=open(p).read().splitlines()
out=[]
for line in lines:
 x=line.split('\t')
 if len(x)==4 and x[:2]==[f,r]: x[2]=new; line='\t'.join(x)
 out.append(line)
open(p,'w').write('\n'.join(out)+'\n')
PY
    # Renew every exempt source pin affected by the careless edit.
    python3 - "$copy/tools/strict_shape_contracts.json" "$file" > "$copy/.repins" <<'PY'
import json,sys
j=json.load(open(sys.argv[1])); f=sys.argv[2]
for row in j:
 if row.get('file')==f and row.get('disposition')=='exempt' and row.get('source_sha256'): print(row['function'])
PY
    while IFS= read -r name; do [ -z "$name" ] || (cd "$copy" && python3 tools/strict_shape_contract.py --repin "$name" --write >/dev/null 2>&1 || true); done < "$copy/.repins"
    (cd "$copy" && ./build.sh >/dev/null 2>&1) || { echo "$file:$reader | $check | BUILD FAILED"; continue; }
    if [[ "$check" = tests/* ]]; then
        output=$(cd "$copy" && bash tools/phase2_readers.sh 2>&1); status=$?
    else
        output=$(cd "$copy" && bash tools/strict_differential.sh --no-baseline 2>&1); status=$?
    fi
    line=$(printf '%s\n' "$output" | grep -m1 -E 'FAIL|CONTRACT FAILED|default contract:' || true)
    if [ "$status" -ne 0 ]; then red=$((red + 1)); else line='GREEN (plant survived)'; fi
    printf '%s:%s | %s | %s\n' "$file" "$reader" "$check" "$line"
done < "$ROOT/tests/strict_flag_readers.tsv"
elapsed=$(($(date +%s)-START))
printf 'examined=%d red=%d wall_time=%ds\n' "$examined" "$red" "$elapsed"
[ "$examined" -gt 0 ] && [ "$red" -eq "$examined" ]
