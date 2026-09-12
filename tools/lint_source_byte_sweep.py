#!/usr/bin/env python3
"""Sweep SOURCE bytes through the diagnostic channels, decoding strictly.

Driven by tools/lint_message_utf8_check.sh (#1048). Its sibling
lint_message_sweep.py sweeps the length of an identifier the TOOL chooses to
quote; this one sweeps the bytes the tool did NOT choose — bytes that come
straight out of the file being linted. That is the other half of the class,
and the half a round-2 fix that only budgeted message length left open:

    printf 'q\xc3\xa9nergie is 2\nprint of q\xc3\xa9nergie\n' > f.eigs

On v0.43.0 the lexer quoted the byte it could not tokenize with `%c`, so the
message read `unexpected character '<0xc3>'` — half of the two-byte `é` — and
`--lint --json`, the human line and the LSP's JSON-RPC frame all carried a
payload a strict decoder rejects. Measured on that release: 512 of 1524
byte/shape/channel combinations were malformed.

What is swept, per byte, on BOTH channels (stdout `--lint --json`, and the
human stderr line, which carries its own copy of the bytes):

    bare      the byte alone on a statement line       -> E002, message echoes it
    ident     the byte inside an identifier            -> E002 + a parse error
                                                          whose caret excerpt
                                                          echoes the source line
    string    the byte inside a string literal         -> the lexer accepts any
                                                          byte here; nothing may
                                                          leak it later
    key       the byte inside a DUPLICATE dict key     -> W010 interpolates the
                                                          key, so this is a lint
                                                          RULE echoing source
                                                          bytes, not the lexer

Every byte >= 0x80 is swept (those are the only ones that can be malformed),
plus a few ASCII controls for the control-dropping path in the JSON escaper,
plus multi-byte SEQUENCES: truncated 2/3/4-byte prefixes, an overlong form and
a surrogate (all must be replaced, never emitted), and well-formed 2/3/4-byte
characters (which must survive BYTE-FOR-BYTE — over-sanitizing would be its own
regression, so the valid cases are asserted present, not just decodable).

A fourth thing the tool renders is the file PATH — which it never assembled and
which is a byte string on POSIX. It reaches `--lint --json` through a different
chokepoint (the JSON escaper) than any message, and on the E000 unreadable-file
path it is the ONLY text in the payload, so it is swept too.

Vacuity guards: a bare/ident run must produce E002 AND name the byte in the
`\\xNN` spelling, so a lexer that stopped reporting the byte at all fails here
instead of sweeping clean; a path run must still name the file; and the
valid-character cases must be found intact.
"""
import json
import os
import subprocess
import sys
import tempfile

from lint_path_fixture import create_warning_file

CONTROLS = [0x01, 0x07, 0x1F, 0x7F]
SEQ_BAD = {
    "trunc2":   b"\xc3",
    "trunc3":   b"\xe2\x80",
    "trunc4":   b"\xf0\x9f\x98",
    "overlong": b"\xc0\xaf",
    "surrogate": b"\xed\xa0\x80",
    "lone-cont": b"\xbf",
}
SEQ_OK = {
    "2-byte": "é".encode("utf-8"),
    "3-byte": "—".encode("utf-8"),
    "4-byte": "😀".encode("utf-8"),
}


def shapes(b: bytes):
    return {
        "bare":   b"x is 1\n" + b + b"\nprint of x\n",
        "ident":  b"q" + b + b"name is 1\nprint of 1\n",
        "string": b'x is "a' + b + b'b"\nprint of x\n',
        "key":    b'd is {"k' + b + b'y": 1, "k' + b + b'y": 2}\nprint of d\n',
    }


def run(eigs, src, mode):
    with tempfile.NamedTemporaryFile("wb", suffix=".eigs", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        r = subprocess.run([eigs] + mode + [path], capture_output=True)
        return (r.stdout if "--json" in mode else r.stdout + r.stderr)
    finally:
        os.unlink(path)


def sweep_paths(eigs, bad, vacuous):
    """The file path is text the tool did not choose either. Two shapes: a
    readable file whose warning payload carries `"file"`, and a missing file
    (E000, whose whole message is the path)."""
    runs = 0
    with tempfile.TemporaryDirectory() as d:
        for name, raw in [("invalid", b"bad\xffname"), ("lone-lead", b"bad\xc3name"),
                          ("valid", "badénom".encode("utf-8"))]:
            path = os.path.join(os.fsencode(d), b"w_" + raw + b".eigs")
            # Missing paths exercise invalid argv bytes even when the filesystem
            # cannot store them. Readable paths remain covered wherever creation
            # succeeds, and a valid UTF-8 readable path is mandatory everywhere.
            targets = [(False, path + b".missing")]
            if create_warning_file(path):
                targets.insert(0, (True, path))
            for present, target in targets:
                for mode in ([b"--lint", b"--json"], [b"--lint"]):
                    r = subprocess.run([eigs.encode()] + mode + [target],
                                       capture_output=True)
                    out = r.stdout if b"--json" in mode else r.stdout + r.stderr
                    runs += 1
                    label = "%s path %s %s" % (name, "present" if present else "missing",
                                               b" ".join(mode).decode())
                    try:
                        out.decode("utf-8")
                    except UnicodeDecodeError as e:
                        bad.append("%s: %s" % (label, e))
                        continue
                    expected_path = target.decode("utf-8", errors="replace")
                    # --lint defaults to warnings-as-errors, so W001 and
                    # E000 both return 1; crashes must not look like a match.
                    if r.returncode != 1:
                        vacuous.append("%s: unexpected exit %d" % (label, r.returncode))
                    if b"--json" in mode:
                        try:
                            rows = json.loads(out)
                            expected_code = "W001" if present else "E000"
                            if len(rows) != 1 or rows[0].get("code") != expected_code:
                                raise ValueError("expected one %s diagnostic" % expected_code)
                            if rows[0].get("file") != expected_path:
                                raise ValueError("file field did not preserve the sanitized path")
                        except (ValueError, TypeError, AttributeError) as error:
                            vacuous.append("%s: %s" % (label, error))
                    else:
                        expected = (expected_path + ":1: warning[W001]:" if present
                                    else "cannot read file '%s'" % expected_path)
                        if expected.encode("utf-8") not in out:
                            vacuous.append("%s: missing diagnostic naming the sanitized path" % label)
    return runs


def main() -> int:
    eigs = sys.argv[1]
    if sys.argv[2:] == ["--selftest-paths"]:
        return selftest_paths(eigs)
    bad, vacuous, runs = [], [], 0
    byte_cases = [(hex(v), bytes([v])) for v in list(range(0x80, 0x100)) + CONTROLS]
    for name, b in byte_cases + sorted(SEQ_BAD.items()):
        for shape, src in shapes(b).items():
            for mode in (["--lint", "--json"], ["--lint"]):
                out = run(eigs, src, mode)
                runs += 1
                try:
                    out.decode("utf-8")
                except UnicodeDecodeError as e:
                    bad.append("%s %s %s: %s" % (name, shape, " ".join(mode), e))
                    continue
                if shape in ("bare", "ident") and b[0] >= 0x80:
                    spelled = ("\\x%02x" % b[0]).encode()
                    if b"E002" not in out or spelled not in out:
                        vacuous.append("%s %s %s: no E002 naming %s"
                                       % (name, shape, " ".join(mode),
                                          spelled.decode()))
                if shape == "key" and b"W010" not in out:
                    vacuous.append("%s key %s: the rule stopped firing"
                                   % (name, " ".join(mode)))
    # Well-formed characters must survive unchanged: the fix replaces INVALID
    # bytes, and a fix that replaced every non-ASCII byte would pass every
    # decode above while destroying the diagnostic.
    for name, b in sorted(SEQ_OK.items()):
        # Two places echo well-formed source bytes: a rule that interpolates
        # them (W010's dict key, both channels) and the parse-error caret
        # excerpt (the human channel only — the JSON payload carries the
        # lexer's first error, which names a byte, not the character).
        for shape, modes in (("key", (["--lint", "--json"], ["--lint"])),
                             ("ident", (["--lint"],))):
            for mode in modes:
                out = run(eigs, shapes(b)[shape], mode)
                runs += 1
                try:
                    out.decode("utf-8")
                except UnicodeDecodeError as e:
                    bad.append("valid %s %s %s: %s" % (name, shape, " ".join(mode), e))
                    continue
                if b not in out:
                    vacuous.append("valid %s %s %s: the character was not echoed intact"
                                   % (name, shape, " ".join(mode)))
    runs += sweep_paths(eigs, bad, vacuous)
    if bad:
        print("MALFORMED: " + "; ".join(bad[:6]))
        return 1
    if vacuous:
        print("VACUOUS: " + "; ".join(vacuous[:6]))
        return 1
    print("swept %d source-byte cases x 4 shapes + 3 path shapes x 2 channels "
          "(%d runs), all decode"
          % (len(byte_cases) + len(SEQ_BAD), runs))
    return 0


def selftest_paths(eigs):
    """Run the real path sweep with filesystem encoding rejection injected."""
    import contextlib
    import errno
    import io
    from unittest.mock import patch

    real_open = open
    for code in (errno.EILSEQ, errno.EINVAL):
        def reject_invalid(path, *args, **kwargs):
            try:
                os.fsencode(path).decode("utf-8")
            except UnicodeDecodeError:
                raise OSError(code, "planted filename encoding rejection", path)
            return real_open(path, *args, **kwargs)

        bad, vacuous = [], []
        notes = io.StringIO()
        with patch("lint_path_fixture.open", reject_invalid, create=True):
            with contextlib.redirect_stderr(notes):
                runs = sweep_paths(eigs, bad, vacuous)
        # Two missing invalid names and both states of the valid name, each
        # on two channels. Omitting the fallback or the valid control fails.
        if runs != 8 or bad or vacuous or notes.getvalue().count("NOTE:") != 2:
            print("SELFTEST-FAIL: filename rejection errno %d: %d runs; %s"
                  % (code, runs, bad + vacuous))
            return 1
        print("  selftest ok: filename rejection errno %d retains 8 path runs" % code)

    # The fallback must not turn unrelated fixture failures into coverage
    # exemptions, or accept encoding errors on an ordinary valid filename.
    for path, code in ((b"invalid\xff.eigs", errno.EACCES),
                       (b"invalid\xff.eigs", errno.ENOSPC),
                       (b"valid.eigs", errno.EILSEQ),
                       (b"valid.eigs", errno.EINVAL)):
        with patch("lint_path_fixture.open", side_effect=OSError(code, "planted"),
                   create=True):
            try:
                create_warning_file(path)
            except OSError as error:
                if error.errno == code:
                    continue
            print("SELFTEST-FAIL: unrelated fixture error was waived")
            return 1
    print("  selftest ok: 4 unrelated fixture errors remain fatal")
    return 0


if __name__ == "__main__":
    sys.exit(main())
