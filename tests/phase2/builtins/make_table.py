#!/usr/bin/env python3
"""Validate the pre-registered R1.6 behaviour bar (and explicitly refresh with --write).

The inventory owns section-6 parsing. This checker retains every original bar
membership, closure, profile, hook, stdin, vacuity and accounting predicate.
Default execution never overwrites builtins.tsv or any expectation. --final
refuses pending profile observations. --run TAG BRANCH runs the same runner
used to record observations and emits the phase2-builtins PASS contract.
"""
import argparse, atexit, hashlib, importlib.util, json, os, re, shutil, subprocess, sys, tempfile

ROUNDS = ("R1.6a", "R1.6b", "R1.6c", "R1.6d", "R1.6e", "R1.6f", "R1.6g", "R1.6z")


# Author-ruled import, independent of the candidate's expectation files.
BAR_PIN = "0a73adb0612f8612d75393891ae2ba2e1c803663"
BAR_DIR = "tests/phase2/builtins/"


def frozen_bar(root):
    """Compare the complete pathname/content set; amendments waive exact bytes."""
    def git(*args):
        result = subprocess.run(["git", "-C", root, *args], capture_output=True)
        if result.returncode:
            raise ValueError("frozen bar pin %s unavailable: %s (fetch the pin explicitly)" %
                             (BAR_PIN, result.stderr.decode(errors="replace").strip()))
        return result.stdout

    paths = git("ls-tree", "-r", "--name-only", BAR_PIN, "--", BAR_DIR).decode().splitlines()
    pinned = {p: git("show", BAR_PIN + ":" + p) for p in paths if p.endswith(".branch")}
    if not pinned:
        raise ValueError("frozen bar pin %s contains no .branch paths under %s" % (BAR_PIN, BAR_DIR))
    amendments = {}
    changes = os.path.join(root, "tests/phase2/builtins_changes.md")
    with open(changes, encoding="utf-8") as stream:
        section = stream.read().split("## Frozen .branch amendments\n", 1)
    if len(section) == 2:
        for line in section[1].split("\n## ", 1)[0].splitlines():
            if not line.startswith("|"): continue
            fields = [v.strip().strip("`") for v in line.strip("|").split("|")]
            if fields[0] == "Path" or all(re.fullmatch(r"[-:]+", v) for v in fields): continue
            if len(fields) != 4:
                raise ValueError("malformed frozen bar amendment: " + line)
            path, digest, ruling, reason = fields
            if (not path.startswith(BAR_DIR) or not path.endswith(".branch") or
                    any(part in ("", ".", "..") for part in path.split("/"))):
                raise ValueError("invalid frozen bar amendment path: " + path)
            if path in amendments:
                raise ValueError("duplicate frozen bar amendment: " + path)
            if not re.fullmatch(r"[0-9a-f]{64}|DELETED", digest) or not ruling or not reason:
                raise ValueError("%s: amendment needs SHA-256 (or DELETED), ruling id and reason" % path)
            amendments[path] = (digest, ruling)
    from pathlib import Path
    actual = {p.relative_to(root).as_posix(): p.read_bytes()
              for p in (Path(root) / BAR_DIR).rglob("*.branch") if p.is_file()}
    bad = []
    changed = {p for p in pinned.keys() | actual.keys() if pinned.get(p) != actual.get(p)}
    for path in sorted(changed | amendments.keys()):
        if path not in amendments:
            bad.append("%s: unlisted frozen bar %s relative to %s" %
                       (path, "addition" if path not in pinned else "deletion" if path not in actual else "difference", BAR_PIN))
            continue
        digest, ruling = amendments[path]
        observed = hashlib.sha256(actual[path]).hexdigest() if path in actual else "DELETED"
        if path not in changed or digest != observed:
            bad.append("%s: stale amendment %s: SHA-256=%s actual=%s (must differ from pin)" %
                       (path, ruling, digest, observed))
        else:
            print("frozen-bar: accepted amendment %s path=%s SHA-256=%s" % (ruling, path, digest))
    if bad: raise ValueError("\nFAIL: ".join(bad))
    print("frozen-bar: pin=%s paths=%d amendments=%d PASS" % (BAR_PIN, len(pinned), len(amendments)))


def read_landed(path):
    """One declared full sub-round per non-comment line, in plan order."""
    seen = set()
    with open(path, encoding="utf-8") as stream:
        for line_number, line in enumerate(stream, 1):
            value = line.split("#", 1)[0].strip()
            if not value: continue
            if value not in ROUNDS: raise ValueError("line %d: unknown sub-round %r" % (line_number, value))
            if value in seen: raise ValueError("line %d: duplicate sub-round %s" % (line_number, value))
            seen.add(value)
    return [value for value in ROUNDS if value in seen]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--final", action="store_true", help="refuse pending profile records")
    parser.add_argument("--write", action="store_true", help="explicitly refresh derived builtins.tsv; never expectations")
    parser.add_argument("--run", nargs=2, metavar=("TAG_BINARY", "BRANCH_BINARY"))
    args = parser.parse_args()
    ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
    try:
        frozen_bar(ROOT)
    except (OSError, ValueError) as error:
        print("FAIL: " + str(error))
        return 1
    TREE = os.environ.get("EIGS_TREE")
    if not TREE and os.environ.get("EIGS_REV"):
        rev = os.environ["EIGS_REV"]
        repo = os.environ.get("EIGS_REPO", ROOT)
        TREE = tempfile.mkdtemp(prefix="r16table.")
        atexit.register(shutil.rmtree, TREE, True)
        archive = subprocess.run(["git", "-C", repo, "archive", rev, "docs/design", "src", "tools/phase2_inventory.py"], capture_output=True)
        unpack = subprocess.run(["tar", "-x", "-C", TREE], input=archive.stdout, capture_output=True) if archive.returncode == 0 else None
        if archive.returncode != 0 or unpack.returncode != 0:
            print("FAIL: could not extract docs/design, src and shared inventory parser at %s from %s" % (rev, repo))
            return 2
        SOURCE = "%s@%s" % (repo, rev)
    else:
        TREE = TREE or ROOT
        SOURCE = TREE
    HERE = os.path.dirname(os.path.abspath(__file__))
    BDIR = os.path.join(HERE, "builtins")
    FINAL = args.final
    PROFILES = ("release", "server", "zlib", "db")
    EXTS = (".eigs", ".branch", ".pre", ".tag")
    FIXTURE_DIRS = {"_stdin", "_profiles"}
    CAPABILITY_GONE = re.compile(r"capability unavailable|compiled without")
    fail = []

    def both_ways(a, b, a_name, b_name):
        for n in sorted(a - b): fail.append("in %s, not in %s: %s" % (a_name, b_name, n))
        for n in sorted(b - a): fail.append("in %s, not in %s: %s" % (b_name, a_name, n))

    def tsv(name, ncols):
        lines = open(os.path.join(HERE, name)).read().splitlines()
        rows = [l.split("\t") for l in lines[1:]]
        for r in rows:
            if len(r) != ncols: fail.append("%s: not %d fields: %r" % (name, ncols, r))
        return [r for r in rows if len(r) == ncols]

    spec = importlib.util.spec_from_file_location("phase2_inventory", os.path.join(TREE, "tools/phase2_inventory.py"))
    inventory = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(inventory)
    sec6, table_bad = inventory.read_table(os.path.join(TREE, "docs/design/phase2-numbers.md"))
    fail.extend(table_bad)
    sec6 = sec6 or {}

    # Exception printouts in these probes are [label, e.kind, ...]. Derive
    # the kind vocabulary from the runtime's sole public string mapping.
    error_kinds = set(re.findall(r'case EK_\w+:\s*return "([^"]+)";',
                                open(os.path.join(TREE, "src/eigenscript.c")).read()))
    if not error_kinds: fail.append("no runtime error-kind names examined")

    inv_txt = open(os.path.join(TREE, "docs/design/phase2-inventory.txt")).read()
    inv_body = inv_txt.split("\n## Builtins\n", 1)[1].split("\n## ", 1)[0]
    inv = {}
    for line in inv_body.splitlines():
        f = line.split()
        if len(f) >= 5 and f[1].startswith("builtin_"):
            inv[f[0]] = (f[1], f[2], f[3], f[4])
    both_ways(set(sec6), set(inv), "section 6", "the inventory")
    for n in sorted(set(sec6) & set(inv)):
        if sec6[n] != inv[n][1:]:
            fail.append("section 6 %s vs inventory %s for %s" % (sec6[n], inv[n][1:], n))

    src = os.path.join(TREE, "src")
    defs = {}
    for fn in sorted(os.listdir(src)):
        if fn.endswith(".c"):
            for m in re.finditer(r"^(?:static\s+)?Value\s*\*\s*(builtin_\w+)\s*\([^;{]*\)\s*\{", open(os.path.join(src, fn)).read(), re.M):
                defs.setdefault(m.group(1), []).append(fn)

    def round_of(file, cls, loss):
        if loss == "LOSS" or (file == "builtins.c" and cls == "int-preserving"): return "b"
        if file in ("builtins.c", "builtins_host.c", "vm.c"): return "c"
        if file in ("builtins_tensor.c", "builtins_buf.c") or file.startswith("model_"): return "d"
        if file == "builtins_int.c": return "g"
        if file == "ext_gfx.c": return "e"
        if file in ("ext_store.c", "ext_db.c", "ext_http.c", "ext_net.c"): return "f"
        fail.append("no round for file " + file); return "?"

    meta = {}
    for b, closed_in, profile in tsv("rowmeta.tsv", 3):
        if b in meta: fail.append("rowmeta.tsv: duplicate row " + b)
        if profile not in PROFILES: fail.append("rowmeta.tsv: %s has profile %r" % (b, profile))
        if not closed_in.strip(): fail.append("rowmeta.tsv: %s has an empty closed_in (write -)" % b)
        meta[b] = (closed_in, profile)
    both_ways(set(sec6), set(meta), "section 6", "rowmeta.tsv")

    cases = {}
    for c, b, hook, stdin in tsv("cases.tsv", 4):
        if c in cases: fail.append("cases.tsv: duplicate case " + c)
        if c != b and not c.startswith(b + "."): fail.append("cases.tsv: case %s does not name its builtin %s" % (c, b))
        if b not in sec6: fail.append("cases.tsv: case %s names no section-6 row" % c)
        cases[c] = (b, hook, stdin)
    both_ways(set(sec6), {c for c, v in cases.items() if c == v[0]}, "section 6", "the primary cases")

    shim = open(os.path.join(HERE, "..", "observation_hooks.c")).read()
    both_ways(set(re.findall(r'hook_is\("(\w+)"\)', shim)), {v[1] for v in cases.values()} - {"-"},
              "the shim's hooks", "the cases' hooks")
    both_ways(set(os.listdir(os.path.join(BDIR, "_stdin"))), {v[2] for v in cases.values()} - {"-"},
              "builtins/_stdin", "the cases' stdin")
    both_ways({f[:-5] for f in os.listdir(os.path.join(BDIR, "_profiles")) if f.endswith(".eigs")},
              {p for _, p in meta.values()} - {"release"}, "builtins/_profiles", "the non-release profiles")
    listing = set(os.listdir(BDIR))
    for f in sorted(listing - FIXTURE_DIRS):
        if not f.endswith(EXTS): fail.append("builtins/%s is neither a case file nor a fixture dir" % f)
    for ext in EXTS:
        have = {f[:-len(ext)] for f in listing if f.endswith(ext)}
        both_ways(set(cases), have, "cases.tsv", "builtins/*" + ext)
        print("files %-7s %d (cases %d)" % (ext, len(have), len(cases)))

    def record(c, ext):
        p = os.path.join(BDIR, c + ext)
        return open(p).read() if os.path.exists(p) else None

    state = {}   # (case, "pre"|"tag") -> same | differs | pending-profile | missing
    for c in sorted(cases):
        b, hook, stdin = cases[c]
        closed_in, profile = meta.get(b, ("-", "?"))
        br = record(c, ".branch")
        for kind in ("branch", "pre", "tag"):
            rec = record(c, "." + kind)
            if rec is None or br is None:
                state[(c, kind)] = "missing"; continue
            if rec.startswith("PENDING-PROFILE"):
                if kind == "branch" or profile == "release" or rec != "PENDING-PROFILE %s\n" % profile:
                    fail.append("%s.%s: %r on a %s row" % (c, kind, rec.strip(), profile))
                state[(c, kind)] = "pending-profile"; continue
            if profile != "release" and CAPABILITY_GONE.search(rec):
                fail.append("%s.%s is a capability-unavailable transcript, not a %s build (ruling A3)" % (c, kind, profile))
            lines = rec.splitlines()
            if not lines or not re.fullmatch(r"rc=-?\d+", lines[-1]) or sum(bool(re.fullmatch(r"rc=-?\d+", l)) for l in lines) != 1:
                fail.append("%s.%s: expected stdout followed by exactly one final rc=<N> line" % (c, kind))
            loaded = [l for l in lines if l.startswith("hook-loaded")]
            if hook == "-" and loaded:
                fail.append("%s.%s holds %r but the case has no hook" % (c, kind, loaded[0]))
            if hook != "-" and loaded != ["hook-loaded " + hook]:
                fail.append("%s.%s holds %r, not one 'hook-loaded %s' line: not recorded with its shim" % (c, kind, loaded, hook))
            state[(c, kind)] = "same" if rec == br else "differs"

    def agg(b, kind):
        s = [state[(c, kind)] for c in sorted(cases) if cases[c][0] == b]
        if "missing" in s: return "missing"
        if "pending-profile" in s: return "pending-profile"
        return "yes" if "differs" in s else "no"

    rows, counts, tally = [], {}, {}
    guard = {"guarded": 0, "yes": 0, "closed_in": 0, "pending-profile": 0, "vacuous": 0}
    for n in sorted(sec6):
        cls, loss, q7 = sec6[n]
        files = sorted(set(defs.get(inv.get(n, ("",))[0], [])))   # #if/#else twins (inflate) are one file
        if len(files) != 1:
            fail.append("%s: C function defined in %r (want exactly one file)" % (n, files)); file = "?"
        else:
            file = files[0]
        r = round_of(file, cls, loss)
        closed_in, profile = meta.get(n, ("-", "?"))
        mine = [c for c in sorted(cases) if cases[c][0] == n]
        hooks = [cases[c][1] for c in mine]
        stdins = [cases[c][2] for c in mine]
        vs_pre, vs_tag = agg(n, "pre"), agg(n, "tag")
        for kind, v in (("pre", vs_pre), ("tag", vs_tag)):
            if v == "missing": fail.append("%s: a .branch or .%s is missing" % (n, kind))
            if v == "pending-profile" and FINAL: fail.append("%s: .%s is PENDING-PROFILE %s (--final)" % (n, kind, profile))
        # Result subtypes are visible in the immutable expected output. Inputs
        # whose success/continuous class is not self-describing have a declaration
        # on the existing first comment line (no state_at line numbers move).
        brs = "".join(record(c, ".branch") or "" for c in mine)
        probe = record(n, ".eigs") or ""
        header = re.search(r"phase2-exercises: (\{[^\n]*\})", probe.split("\n", 1)[0])
        exercises = {}
        if header:
            try:
                exercises = json.loads(header.group(1))
                if not isinstance(exercises, dict): raise ValueError("expected object")
            except (ValueError, TypeError):
                fail.append("%s: malformed phase2-exercises header" % n)
                exercises = {}
        if cls in ("int-preserving", "float-producing"):
            kind = "int" if cls == "int-preserving" else "float"
            if '"' + kind + '"' not in brs:
                fail.append("%s: %s .branch does not show result subtype %s" % (n, cls, kind))
        if cls == "int-requiring":
            if not re.search(r'^\[.*fraction[^\n]*, "value"(?:,[^\n]*)?\]$', brs, re.M):
                fail.append("%s: int-requiring .branch has no fractional-call value raise" % n)
            if exercises.get("int-requiring") != ["fractional", "integral-float-success"] or not re.search(r"\d+\.0(?:\D|$)", probe):
                fail.append("%s: int-requiring probe needs fractional and successful integral-float exercise header" % n)
            success = exercises.get("integral-float-success")
            lines = (record(n, ".branch") or "").splitlines()
            if not isinstance(success, dict):
                fail.append("%s: integral-float success needs an identified stdout line or exit code" % n)
            elif set(success) == {"exit-code"}:
                code = success["exit-code"]
                # exit and set_exit_code expose successful integral-float
                # conversion through the requested process status (R1.6-S2).
                if (n not in ("exit", "set_exit_code") or type(code) is not int
                        or not re.search(r"\b%s of %d\.0(?:\D|$)" % (re.escape(n), code), probe)
                        or not lines or lines[-1] != "rc=%d" % code):
                    fail.append("%s: integral-float success exit code is not witnessed in .branch" % n)
            elif set(success) == {"stdout-line"}:
                line_number = success["stdout-line"]
                if type(line_number) is not int or not 1 <= line_number < len(lines):
                    fail.append("%s: integral-float success stdout line is outside .branch" % n)
                else:
                    output = lines[line_number - 1]
                    try: value = json.loads(output)
                    except ValueError: value = output
                    error = (isinstance(value, str) and value in error_kinds
                             or isinstance(value, list) and len(value) > 1
                             and isinstance(value[1], str) and value[1] in error_kinds
                             or isinstance(value, dict) and (value.get("ok") is False or "error" in value))
                    if not output or output.startswith(("rc=", "hook-loaded", "mix:", "SDL_QueueAudio")) or error:
                        fail.append("%s: integral-float success stdout line %d is an error or non-result: %s" % (n, line_number, output))
                    if lines[-1] != "rc=0":
                        fail.append("%s: integral-float success .branch does not finish with rc=0" % n)
            else:
                fail.append("%s: integral-float success header has unknown fields" % n)
        want_q7 = [] if q7 == "-" else q7.split(",")
        if exercises.get("q7", []) != want_q7:
            fail.append("%s: phase2-exercises q7 %r != table %r" % (n, exercises.get("q7", []), want_q7))
        guarded = loss == "LOSS" or cls == "int-requiring" or q7 != "-"
        if closed_in != "-":
            if not guarded: fail.append("%s: closed_in %r on a row the vacuity guard does not cover" % (n, closed_in))
            if vs_pre != "no": fail.append("%s: closed_in %r but changes_vs_pre is %s: the closure must hold as .pre == .branch (ruling A2)" % (n, closed_in, vs_pre))
        if guarded:
            guard["guarded"] += 1
            if closed_in != "-": guard["closed_in"] += 1
            elif vs_pre == "yes": guard["yes"] += 1
            elif vs_pre == "pending-profile": guard["pending-profile"] += 1
            else:
                guard["vacuous"] += 1
                fail.append("vacuous: %s is a %s row without closed_in and changes_vs_pre %s" % (n, "/".join(x for x in (cls, loss, q7) if x != "-"), vs_pre))
        rows.append((n, file, cls, loss, q7, r, closed_in, profile,
                     ",".join(hooks) if set(hooks) != {"-"} else "-",
                     ",".join(stdins) if set(stdins) != {"-"} else "-", vs_pre, vs_tag))
        counts[r] = counts.get(r, 0) + 1
        for kind, v in (("pre", vs_pre), ("tag", vs_tag)):
            tally[(r, kind, v)] = tally.get((r, kind, v), 0) + 1

    want = {"b": 46, "c": 77, "d": 53, "e": 38, "f": 19}  # R1.6a-D1 read_text; R1.6b-D3 http_post LOSS; R1.6-S2 set_exit_code
    if counts != want: fail.append("round counts %s, the plan says %s" % (counts, want))
    if not rows or len(rows) != len(sec6): fail.append("examined=%d table=%d" % (len(rows), len(sec6)))
    if guard["guarded"] != guard["yes"] + guard["closed_in"] + guard["pending-profile"] + guard["vacuous"]:
        fail.append("guard accounting %r" % guard)

    header = "builtin\tfile\tclass\tloss\tq7\tround\tclosed_in\tprofile\thook\tstdin\tchanges_vs_pre\tchanges_vs_tag\n"
    expected = header + "".join("\t".join(row) + "\n" for row in rows)
    if args.write:
        if not fail:
            with open(os.path.join(HERE, "builtins.tsv"), "w") as out: out.write(expected)
    else:
        with open(os.path.join(HERE, "builtins.tsv")) as stream:
            if stream.readline() != header: fail.append("builtins.tsv: header differs from the declared schema")
        current = tsv("builtins.tsv", 12)
        have = {}
        for row in current:
            if row[0] in have: fail.append("builtins.tsv: duplicate row " + row[0])
            have[row[0]] = row
        both_ways(set(have), set(sec6), "builtins.tsv", "section 6")
        fields = header.strip().split("\t")
        for row in rows:
            if row[0] in have:
                for field, got, want_value in zip(fields[1:], have[row[0]][1:], row[1:]):
                    if got != want_value: fail.append("%s: builtins.tsv %s %r != derived %r" % (row[0], field, got, want_value))


    prof = {p: sum(1 for _, q in meta.values() if q == p) for p in PROFILES}
    print("source=%s" % SOURCE)
    print("examined=%d section6=%d inventory=%d rowmeta=%d cases=%d" % (len(rows), len(sec6), len(inv), len(meta), len(cases)))
    print("closed_in=%d %s hook_cases=%d stdin_cases=%d" % (sum(1 for ci, _ in meta.values() if ci != "-"),
          " ".join("%s=%d" % kv for kv in prof.items()), sum(1 for v in cases.values() if v[1] != "-"),
          sum(1 for v in cases.values() if v[2] != "-")))
    for r in sorted(want):
        print("round %s: %d rows; " % (r, counts.get(r, 0)) + "; ".join(
            "vs_%s yes=%d no=%d pending-profile=%d" % (k, tally.get((r, k, "yes"), 0), tally.get((r, k, "no"), 0),
                                                       tally.get((r, k, "pending-profile"), 0)) for k in ("pre", "tag")))
    print("guard: guarded=%(guarded)d yes=%(yes)d closed_in=%(closed_in)d pending_profile=%(pending-profile)d vacuous=%(vacuous)d" % guard
          + (" (final)" if FINAL else ""))
    for f in fail: print("FAIL: " + f)
    if fail: return 1
    if args.run:
        try: landed = read_landed(os.path.join(HERE, "..", "builtins_landed.txt"))
        except (OSError, ValueError) as error:
            print("FAIL: builtins_landed.txt: " + str(error)); return 1
        env = os.environ.copy()
        env["R16_LANDED"] = " ".join(landed)
        rc = subprocess.call(["bash", os.path.join(HERE, "run_probes.sh"), "--check", *args.run], env=env)
        if rc: return rc
        migrated = sum(1 for row in rows if "R1.6" + row[5] in landed)
        print("phase2-builtins: PASS rows=%d landed=%s migrated=%d unchanged=%d" %
              (len(rows), ",".join(landed) or "-", migrated, len(rows) - migrated))
    return 0


if __name__ == "__main__":
    sys.exit(main())
