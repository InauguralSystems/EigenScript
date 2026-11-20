#!/bin/sh
# regen.sh <eigenscript> <outdir>: re-records the four programs and splices
# the 30 lowered-window tapes (#2433) into <outdir>. A tape gets `O 0 cfg` or
# `O 0 win x` records lowering x's window after its first assignment and
# raising it after a later one (splice.py); the _nostream tape drops the
# stream number, which the reader refuses. The recordings stay as *.rec.
set -eu
bin=$1; out=$2; here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
for p in alt const long longalt; do
    env EIGS_TRACE="$out/$p.rec" "$bin" "$here/$p.eigs" > /dev/null
done
for prog in alt const; do
    for form in cfg win; do
        for low in 4 7; do
            after=6; [ "$low" = 7 ] && after=9
            for high in 10 64; do
                python3 "$here/splice.py" "$out/$prog.rec" "$out/c_${prog}_${form}_${low}_${high}.tape" "$form" "$low" "$high" "$after"
            done
        done
    done
done
python3 "$here/splice.py" "$out/const.rec" "$out/const_win_lr.tape" win 4 10 7
sed 's/^O 0 /O /' "$out/const_win_lr.tape" > "$out/const_win_lr_nostream.tape"
for prog in long longalt; do
    for spec in "cfg 4 10 14" "cfg 4 10 8" "cfg 4 64 14" "cfg 7 10 14" "win 4 10 14" "win 7 64 20"; do
        set -- $spec
        python3 "$here/splice.py" "$out/$prog.rec" "$out/L_${prog}_$1_$2_$3_$4.tape" "$1" "$2" "$3" "$4"
    done
done
