import sys
# splice.py <in.tape> <out.tape> <form cfg|win> <low> <raise> <raise_after_assign_index>
src, dst, form, low, high, after = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
def rec(w):
    return ("O 0 cfg 0.001 0.01 %d 0.001\n" % w) if form == "cfg" else ("O 0 win x %d\n" % w)
out = []; n = 0
for line in open(src):
    out.append(line)
    if line.startswith("A 0 x="):
        n += 1
        if n == 1: out.append(rec(low))
        if n == after: out.append(rec(high))
open(dst, "w").write("".join(out))
