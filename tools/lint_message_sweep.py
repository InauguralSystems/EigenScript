#!/usr/bin/env python3
"""Sweep identifier length across the longest lint messages, decoding strictly.

Driven by tools/lint_message_utf8_check.sh (#1048). The defect this exists for
is LENGTH-SENSITIVE: a lint message is assembled into a 256-byte buffer, and as
the interpolated identifier grows the truncation point walks through the
message. Only the lengths that land it inside a multi-byte character (the em
dashes and typographic quotes the messages themselves carry) produce malformed
output, so a corpus of hand-picked lengths misses it. Measured against
v0.43.0 — the release before the fix — each of these shapes has a narrow band
of bad lengths and nothing outside it:

    W024  len 56           (both channels)
    W015  len 74           (both channels)
    W018  len 198, 199     (both channels)
    W023  len 161, 162     (both channels)

Those four are the rules whose messages are long enough to truncate at a
plausible identifier length; W024 is merely the one a consumer hit. Both
channels are decoded, because the human line on stderr and the `--lint --json`
payload on stdout carry separate copies of the bytes and were fixed at
different chokepoints.

Residual: this sweeps FOUR shapes, not every rule. The class guarantee is the
structural one the caller checks — every diagnostic is assembled by lint_vdiag,
which truncates through lint_utf8_prefix — and this is its empirical
corroboration, not its proof.
"""
import os
import subprocess
import sys
import tempfile

MAX_LEN = 250


def shape(code: str, n: int) -> str:
    a = "q" + "z" * (n - 1)
    if code == "W024":
        return ("fleet is [[1, 2, 3.0], [4, 5, 6.0]]\ni is 0\nloop while i < 2:\n"
                "    local %s is fleet[i][2]\n    print of diverging of %s\n"
                "    i is i + 1\n" % (a, a))
    if code == "W015":
        return ("define %s() as:\n    return 1\ndefine g() as:\n    %s is 5\n"
                "    return %s\nprint of (g of [])\n" % (a, a, a))
    if code == "W018":
        return ('try:\n    print of ([] of 1)\ncatch %s:\n'
                '    if %s.kind == "IO":\n        print of 1\n' % (a, a))
    if code == "W023":
        return ("%s is 5\ndefine f(flag) as:\n    if flag == 1:\n        local %s is 1\n"
                "    else:\n        %s is 2\n    return %s\nprint of (f of 0)\n"
                % (a, a, a, a))
    raise KeyError(code)


def main() -> int:
    eigs = sys.argv[1]
    codes = ["W024", "W015", "W018", "W023"]
    bad, seen, runs = [], 0, 0
    for code in codes:
        for n in range(1, MAX_LEN + 1):
            with tempfile.NamedTemporaryFile("w", suffix=".eigs", delete=False) as f:
                f.write(shape(code, n))
                path = f.name
            try:
                for mode in (["--lint"], ["--lint", "--json"]):
                    r = subprocess.run([eigs] + mode + [path], capture_output=True)
                    out = r.stdout if "--json" in mode else r.stderr
                    runs += 1
                    if code.encode() in out:
                        seen += 1
                    try:
                        out.decode("utf-8")
                    except UnicodeDecodeError as e:
                        bad.append("%s len=%d %s: %s" % (code, n, " ".join(mode), e))
            finally:
                os.unlink(path)
    # Vacuity guard: every length of every shape must have produced its own
    # code on both channels. Without it, a shape that stopped firing (a rule
    # renamed, a fixture that no longer parses) would sweep clean and pass.
    if seen < runs:
        print("VACUOUS: only %d of %d outputs carried their code" % (seen, runs))
        return 1
    if bad:
        print("MALFORMED: " + "; ".join(bad[:6]))
        return 1
    print("swept %d shapes x %d lengths x 2 channels (%d runs), all decode"
          % (len(codes), MAX_LEN, runs))
    return 0


if __name__ == "__main__":
    sys.exit(main())
