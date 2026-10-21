#!/usr/bin/env bash
# plants.sh: plant one fault per check in a scratch copy of the bar (and of
# docs/design and src at EIGS_REV, extracted with git archive), run the check,
# and require its named FAIL line.
# Prints RED or SURVIVED per plant; exit 1 if any plant survives, a mutation
# does not apply, or a baseline is not clean. Run it on Xvfb (DISPLAY=:99).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=${EIGS_REPO:-/home/jon/src/InauguralSystems/EigenScriptEcosystem/EigenScript}
REV=${EIGS_REV:-1fd4422c}
PRE=${PRE_BIN:-/home/jon/src/wt/r15-critic/build/release/eigenscript}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/r16plants.XXXXXX") || exit 2
mkdir -p "$WORK/bar0" "$WORK/tree0" || exit 2
cp -r "$HERE/." "$WORK/bar0/" || exit 2
git -C "$REPO" archive -o "$WORK/tree.tar" "$REV" docs/design src && tar -x -C "$WORK/tree0" -f "$WORK/tree.tar" \
    || { echo "BROKEN: git archive $REV of $REPO"; exit 1; }
B="$WORK/bar"; T="$WORK/tree"; D="$T/docs/design"
sub() {  # sub <file> <old> <new>: replace exactly one occurrence, or fail
    python3 - "$1" "$2" "$3" <<'EOF'
import sys
p, old, new = sys.argv[1], sys.argv[2].encode().decode("unicode_escape"), sys.argv[3].encode().decode("unicode_escape")
s = open(p).read()
if s.count(old) != 1: sys.exit("sub: %d occurrences of %r in %s" % (s.count(old), old, p))
open(p, "w").write(s.replace(old, new))
EOF
}
table() { (cd "$B" && EIGS_TREE="$T" timeout 120 python3 make_table.py "$@" 2>&1); }
runner() { (cd "$B" && TMPDIR="$WORK" PROBE_STDERR_DIR="$WORK/stderr" timeout 600 bash run_probes.sh "$@" 2>&1); }
mutate() {
    case $1 in
    P1) python3 -c "import sys;p='$D/phase2-numbers.md';l=open(p).read().split('\n');k=[x for x in l if x.startswith('| \`abs\` |')];assert len(k)==1;l.remove(k[0]);open(p,'w').write('\n'.join(l))" ;;
    P2) sub "$D/phase2-numbers.md" '| `len` | int-preserving |' '| `len` | other |' ;;
    P3) sub "$D/phase2-numbers.md" '<!-- builtin-table:end -->' '| `p2plant` | other | - | - | planted |\n<!-- builtin-table:end -->' ;;
    P4) python3 -c "import re;p='$D/phase2-numbers.md';s=open(p).read();a,r=s.split('<!-- builtin-table:begin -->',1);m,e=r.split('<!-- builtin-table:end -->',1);open(p,'w').write(a+'<!-- builtin-table:begin -->\n'+'<!-- builtin-table:end -->'+e)" ;;
    P5) printf 'Value* builtin_abs(Value *arg) {\n    return arg;\n}\n' >> "$T/src/builtins_buf.c" ;;
    P6) python3 -c "import re;p='$D/phase2-inventory.txt';s=open(p).read();n=len(re.findall(r'(?m)^store_open\s+builtin_store_open\s+int-preserving',s));assert n==1,n;open(p,'w').write(re.sub(r'(?m)^(store_open\s+builtin_store_open\s+)int-preserving',r'\1other',s))" ;;
    P7) sub "$D/phase2-numbers.md" '| `gfx_clear` | other | - | bounded |' '| `gfx_clear` | other | - | - |' ;;
    P8) rm "$B/builtins/hex.tag" ;;
    P9) : > "$B/builtins/p2stale.eigs" ;;
    P10) sub "$B/rowmeta.tsv" '\nhex\t-\trelease' '\nhex\tR1.5\trelease' ;;
    P11) printf 'planted\n' >> "$B/builtins/abs.branch" ;;
    P12) sub "$B/rowmeta.tsv" 'abs\tR1.2/R1.3\trelease' 'abs\t-\trelease' ;;
    P13) cp "$B/builtins/hex.pre" "$B/builtins/hex.branch" ;;
    P14) sub "$B/builtins/audio_stream_push.pre" 'hook-loaded pcm\n' '' ;;
    P15) sub "$B/builtins/abs.pre" 'rc=0' 'hook-loaded mix\nrc=0' ;;
    P16) printf '["capability", "value", "inflate: compiled without zlib support (rebuild with `make zlib`)"]\nrc=0\n' > "$B/builtins/inflate.pre" ;;
    P17) printf 'PENDING-PROFILE server\n' > "$B/builtins/len.pre" ;;
    P18) : ;;
    P19) sub "$B/rowmeta.tsv" 'abs\tR1.2/R1.3\trelease\n' '' ;;
    P20) sub "$B/rowmeta.tsv" 'abs\tR1.2/R1.3\trelease' 'abs\tR1.2/R1.3\tgpu' ;;
    P21) sub "$B/cases.tsv" 'gfx_poll\tgfx_poll\tevents' 'gfx_poll\tgfx_poll\tbogus' ;;
    P22) sub "$B/builtins/_hooks/observation_hooks.c" 'hook_is("events")' 'hook_is("evnts")' ;;
    P23) rm "$B/builtins/_stdin/hi" ;;
    P24) : > "$B/builtins/notes.txt" ;;
    P25) sub "$B/rowmeta.tsv" '\nlen\t-\trelease' '\nlen\tmain\trelease' ;;
    P26) rm "$B/builtins/_profiles/zlib.eigs" ;;
    P27) sub "$B/cases.tsv" '\nlen\tlen\t-\t-\n' '\n' ;;
    P28) : ;;
    T1) printf 'print of (monotonic_ns of null)\n' >> "$B/builtins/len.eigs" ;;
    R1) sub "$B/run_probes.sh" 'out="$HERE/builtins/$2.$3"' 'out="$2.$3"' ;;
    R2|R3) sub "$B/run_probes.sh" '(LD_PRELOAD="$SHIM" ' '(' ;;
    R4) sub "$B/builtins/recv_timeout.eigs" 'send of [c, 7]\n' '' ;;
    R5) : ;;
    R6) rm "$B/builtins/_stdin/hi" ;;
    R7|R8) sub "$B/run_probes.sh" 'R16_HOOK="$hook"' 'R16_HOOK="$hook" R16_PLANT=silence' ;;
    *) return 1 ;;
    esac
}
check() {
    case $1 in
    P18) table --final ;;
    P28) (cd "$B" && EIGS_REV=4ac31e67 timeout 120 python3 make_table.py 2>&1) ;;
    T1) (cd "$B" && TMPDIR="$WORK" PROBE_STDERR_DIR="$WORK/stderr" timeout 300 bash determinism.sh len 2>&1) ;;
    P*) table ;;
    R1) runner abs ;;
    R2) runner audio_stream_push ;;
    R3) runner audio_stream_push >/dev/null; table ;;
    R4) runner recv_timeout ;;
    R5) (cd "$B" && PRE_BIN_ZLIB="$PRE" TAG_BIN_ZLIB="$PRE" TMPDIR="$WORK" timeout 120 bash run_probes.sh inflate 2>&1) ;;
    R6) runner proc_read_buf.hi ;;
    R7|R8) c=audio_stream_push; [ "$1" = R8 ] && c=audio_play
        runner "$c" >/dev/null
        cmp -s "$B/builtins/$c.pre" "$HERE/builtins/$c.pre" || echo "FAIL: $c.pre differs from the recorded .pre: $(grep -E 'SDL_QueueAudio|mixed' "$B/builtins/$c.pre" | tr '\n' ' ')" ;;
    esac
}
# id | the check that must go red | the FAIL line it must print (regex)
PLANTS='P1|section-6 vs inventory membership|in the inventory, not in section 6: abs$
P2|section-6 vs inventory fields|vs inventory .* for len$
P3|stale section-6 row|in section 6, not in the inventory: p2plant$
P4|examined == len(table) > 0|examined=0 table=0
P5|one defining file per row|abs: C function defined in \[.builtins.c., .builtins_buf.c.\]
P6|inventory field edit|for store_open$
P7|q7 column edit|for gfx_clear$
P8|case files vs cases.tsv (missing record)|in cases.tsv, not in builtins/\*\.tag: hex$
P9|case files vs cases.tsv (stray probe)|in builtins/\*\.eigs, not in cases.tsv: p2stale$
P10|closed_in needs .pre == .branch (A2)|hex: closed_in .R1\.5. but changes_vs_pre is yes
P11|closed_in needs .pre == .branch after a .branch edit (A2)|abs: closed_in .R1\.2/R1\.3. but changes_vs_pre is yes
P12|vacuity guard: closed_in removed|vacuous: abs is a
P13|vacuity guard: .branch equal to .pre|vacuous: hex is a
P14|hook record without its shim (table)|audio_stream_push\.pre holds \[\], not one .hook-loaded pcm. line
P15|hook-loaded line on a non-hook case|abs\.pre holds .hook-loaded mix. but the case has no hook
P16|capability transcript on a non-release row (A3)|inflate\.pre is a capability-unavailable transcript
P17|PENDING-PROFILE on a release row|len\.pre: .PENDING-PROFILE server. on a release row
P18|--final refuses pending records|inflate: \.pre is PENDING-PROFILE zlib \(--final\)
P19|rowmeta vs table membership|in section 6, not in rowmeta\.tsv: abs$
P20|profile vocabulary|rowmeta\.tsv: abs has profile .gpu.
P21|cases hooks vs shim hooks|in the cases. hooks, not in the shim.s hooks: bogus$
P22|shim hooks vs cases hooks|in the cases. hooks, not in the shim.s hooks: events$
P23|stdin fixtures vs cases|in the cases. stdin, not in builtins/_stdin: hi$
P24|stray file in builtins/|builtins/notes\.txt is neither a case file nor a fixture dir
P25|closed_in only on guarded rows|len: closed_in .main. on a row the vacuity guard does not cover
P26|profile witnesses vs profiles|in the non-release profiles, not in builtins/_profiles: zlib$
P27|primary case per row|in section 6, not in the primary cases: len$
P28|population pinned to 1fd4422c: the pre-#1841 revision lacks read_text|in rowmeta\.tsv, not in section 6: read_text$
T1|determinism: a printed time (the R1.6a-D2 class)|^UNSTABLE len\.pre$
R1|runner: empty stdout with rc 0|FAIL: abs\.pre printed nothing with rc 0
R2|runner: hook case without the shim|FAIL: audio_stream_push\.pre ran without its hook pcm
R3|table: hook case recorded without the shim|audio_stream_push\.pre holds \[\], not one .hook-loaded pcm. line
R4|runner: a probe that blocks (rc 124)|FAIL: recv_timeout\.pre timed out \(rc 124\)
R5|runner: profile witness refuses a release binary|FAIL: .* is not a zlib build
R6|runner: missing stdin fixture|FAIL: proc_read_buf\.hi: no stdin fixture
R7|pcm hook observes the delivered PCM (silence)|FAIL: audio_stream_push\.pre differs from the recorded \.pre: SDL_QueueAudio 3: 0 0 0
R8|mix hook observes the mixed PCM (silence)|FAIL: audio_play\.pre differs from the recorded \.pre: \["mixed", false\]'
fresh() { rm -rf "$B" "$T"; cp -r "$WORK/bar0" "$B" && cp -r "$WORK/tree0" "$T"; }
bad=0
fresh; out=$(table); rc=$?
if [ $rc -ne 0 ] || grep -q '^FAIL' <<<"$out"; then echo "BASELINE make_table not clean (rc $rc)"; bad=1; else echo "BASELINE make_table clean: $(grep '^guard:' <<<"$out")"; fi
fresh; out=$(runner abs audio_stream_push gfx_poll.empty proc_read_buf.hi inflate); rc=$?
if [ $rc -ne 0 ] || grep -q '^FAIL' <<<"$out"; then echo "BASELINE runner not clean (rc $rc): $out"; bad=1; else echo "BASELINE runner clean: $(tail -1 <<<"$out")"; fi
n=0; red=0
while IFS='|' read -r id what want; do
    n=$((n + 1)); fresh
    if ! mutate "$id" >"$WORK/mutate.log" 2>&1; then echo "BROKEN $id ($what): the mutation did not apply: $(cat "$WORK/mutate.log")"; bad=1; continue; fi
    out=$(check "$id")
    line=$(grep -E -m1 -- "$want" <<<"$out")
    if [ -n "$line" ]; then red=$((red + 1)); echo "RED $id ($what): $line"; else echo "SURVIVED $id ($what)"; bad=1; fi
done <<<"$PLANTS"
want_n=$(grep -c . <<<"$PLANTS")
echo "plants examined=$n table=$want_n red=$red survived=$((n - red))"
rm -rf "$WORK"
[ "$n" -eq "$want_n" ] && [ "$n" -gt 0 ] && [ "$red" -eq "$n" ] && [ "$bad" -eq 0 ] || exit 1
