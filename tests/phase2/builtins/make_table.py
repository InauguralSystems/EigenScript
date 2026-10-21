#!/usr/bin/env python3
"""make_table.py [--final]: write builtins.tsv from the design and the tree, then check it.

Population: the section-6 table between the builtin-table markers of
docs/design/phase2-numbers.md, checked both ways against the inventory's
`## Builtins` list (docs/design/phase2-inventory.txt), field by field.
file: the src/*.c file that DEFINES the inventory's C function. round: the
R1.6 plan's rule. rowmeta.tsv gives each row's closed_in and profile (rulings
A2, A3); cases.tsv gives each probe case's builtin, hook and stdin (A4, A5).
A row's primary case is builtins/<b>; a second case is builtins/<b>.<label>.
changes_vs_pre / changes_vs_tag: .branch vs .pre / .tag over the row's cases
(ruling A1; `pending-profile` while a non-release row waits for its matched
build). Exit 1 on any FAIL:
- membership, both ways: table/inventory, table/rowmeta, table/primary cases,
  cases/probe files, hooks/shim, stdin cases/fixtures, profiles/witnesses;
- a closed_in row has .pre == .branch on every case (the closure is checked);
- the vacuity guard: a LOSS, int-requiring or Q7 row without closed_in has
  changes_vs_pre yes;
- a hook case's .branch, .pre and .tag hold one `hook-loaded <hook>` line (the
  shim was preloaded), and no other case holds one;
- a non-release record is `PENDING-PROFILE <profile>` or a matched-build
  record, never a capability-unavailable transcript; a release record is never
  pending. --final (R1.6a, after the matched builds): pending is a FAIL too.
examined must equal the table and be > 0.
"""
import os, re, sys

TREE = os.environ.get("EIGS_TREE", "/home/jon/src/wt/r15-critic")
HERE = os.path.dirname(os.path.abspath(__file__))
BDIR = os.path.join(HERE, "builtins")
FINAL = "--final" in sys.argv[1:]
PROFILES = ("release", "server", "zlib", "db")
EXTS = (".eigs", ".branch", ".pre", ".tag")
FIXTURE_DIRS = {"_hooks", "_stdin", "_profiles"}
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

doc = open(os.path.join(TREE, "docs/design/phase2-numbers.md")).read()
body = doc.split("<!-- builtin-table:begin -->", 1)[1].split("<!-- builtin-table:end -->", 1)[0]
sec6 = {}
for line in body.splitlines():
    if not line.startswith("| `"):
        continue
    m = re.match(r"^\| `([^`]+)` \| ([^|]+) \| ([^|]+) \| ([^|]+) \|", line)
    if not m:
        fail.append("unparsed section-6 line: " + line[:60]); continue
    name, cls, loss, q7 = (g.strip() for g in m.groups())
    if name in sec6: fail.append("duplicate section-6 row " + name)
    sec6[name] = (cls, loss, q7)

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

shim = open(os.path.join(BDIR, "_hooks", "observation_hooks.c")).read()
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

want = {"b": 45, "c": 75, "d": 53, "e": 38, "f": 20}
if counts != want: fail.append("round counts %s, the plan says %s" % (counts, want))
if not rows or len(rows) != len(sec6): fail.append("examined=%d table=%d" % (len(rows), len(sec6)))
if guard["guarded"] != guard["yes"] + guard["closed_in"] + guard["pending-profile"] + guard["vacuous"]:
    fail.append("guard accounting %r" % guard)

with open(os.path.join(HERE, "builtins.tsv"), "w") as out:
    out.write("builtin\tfile\tclass\tloss\tq7\tround\tclosed_in\tprofile\thook\tstdin\tchanges_vs_pre\tchanges_vs_tag\n")
    for row in rows: out.write("\t".join(row) + "\n")

prof = {p: sum(1 for _, q in meta.values() if q == p) for p in PROFILES}
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
sys.exit(1 if fail else 0)
