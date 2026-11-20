#!/bin/sh
# regen.sh <eigenscript> <outdir>: re-records the generator programs named in
# the first loop below and splices the tapes of #2433 into <outdir>. A tape
# gets `O 0 cfg` or `O 0 win x` records that set the window at chosen
# assignments of x (splice.py):
#   c_*, L_* and const_win_lr: lowered after the first assignment, raised
#     after a later one;
#   M_*: raised after the first, lowered after the second, raised again after
#     the thirtieth;
#   F_*: set before the first, lowered after it, raised after the
#     twenty-ninth;
#   const_win_lr_nostream: const_win_lr without the stream number, which the
#     reader refuses.
# The recordings stay as *.rec.
set -eu
bin=$1; out=$2; here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
for p in alt alt31 const long longalt; do
    env EIGS_TRACE="$out/$p.rec" "$bin" "$here/$p.eigs" > /dev/null
done
for form in cfg win; do
    python3 "$here/splice.py" "$out/longalt.rec" "$out/M_longalt_${form}.tape" "$form" 1 64 2 4 30 64
    python3 "$here/splice.py" "$out/alt31.rec" "$out/F_alt31_${form}.tape" "$form" 0 30 1 5 29 64
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
