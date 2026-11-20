import sys
# splice.py <in.tape> <out.tape> <form cfg|win> <place> <window> [...]
# A place of 0 means before the first assignment; N means after assignment N.
# The former <low> <raise> <raise-after> form remains accepted so regenerating
# the original corpus is byte-for-byte stable.
src, dst, form = sys.argv[1:4]
if len(sys.argv) == 7:
    low, high, after = map(int, sys.argv[4:7])
    places = [(1, low), (after, high)]
else:
    if len(sys.argv) < 6 or len(sys.argv) % 2:
        raise SystemExit("usage: splice.py IN OUT cfg|win PLACE WINDOW [PLACE WINDOW ...]")
    values = list(map(int, sys.argv[4:]))
    places = list(zip(values[::2], values[1::2]))
def rec(w):
    return ("O 0 cfg 0.001 0.01 %d 0.001\n" % w) if form == "cfg" else ("O 0 win x %d\n" % w)
out = []; n = 0
for line in open(src):
    if line.startswith("A 0 x=") and n == 0:
        out.extend(rec(w) for place, w in places if place == 0)
    out.append(line)
    if line.startswith("A 0 x="):
        n += 1
        out.extend(rec(w) for place, w in places if place == n)
open(dst, "w").write("".join(out))
