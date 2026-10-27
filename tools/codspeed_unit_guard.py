#!/usr/bin/env python3
"""codspeed_unit_guard.py -- the CodSpeed lane's UNIT is a claim; this pins it (#2002).

The claim (docs/INSTRUMENTS.md, row "CodSpeed simulation lane"): a row's Value is MODELED
CYCLES at 3.6 GHz, not instructions. CodSpeed's runner always runs callgrind with a fixed cache
simulation; `cycle-estimation: false` only drops the per-instruction cycle table. The server
then reports value = ir + l1m + llm (seconds) with, EXACTLY (measured on CI, run
6ae12936845b2efa5a0d75bc, observed_loop):

  ir  = 1 cycle   x (Ir + Dr + Dw)             every instruction fetch and data load/store
  l1m = 5 cycles  x (I1mr + D1mr + D1mw)       every L1 miss, in addition
  llm = 100 cycles x (ILmr + DLmr + DLmw)      every last-level miss (instruction or data), in addition

so Value runs 1.4 to 1.6 x cachegrind `Ir`. Until #2002 the workflow comment called the
headline "INSTRUCTIONS"; the first lane run with `cycle-estimation: false` (2026-09-21, #1221)
already read 1.39 to 1.56 x Ir.

Why a guard: the unit is decided outside this repo (the action's default runner, the valgrind
fork it installs, CodSpeed's server) and a bump changes it silently. Two layers: the workflow
pins `runner-version` (tools/codspeed_targets_check.sh fails if the pin goes), and this script
runs in the lane after the CodSpeed step. It reads, for ONE row, the raw callgrind events the
runner just wrote (the profile folder it leaves in the temp dir: the very data it uploaded)
and the Value the server computed from them (CodSpeed's public API, via the action's `run-id`
output), and fails, naming every property that moved, unless the profile's event set is the
expected one (a cycle table adds columns), the profile's cache geometry is the registered one
(32 KiB 8-way L1s, 8 MiB 16-way LL, 64-byte lines), each of ir, l1m, llm equals its formula
above to half a cycle, and value = ir + l1m + llm. It cannot see what the region of measurement
is (the runner counts from the LD_PRELOAD constructor to the destructor) or which objects the
runner skips: those stay with the runner-version pin.

Same run, same host, same region: a first version recomputed the events with cachegrind over
the whole process and read 1.4% low on CI, because the runner measures from the LD_PRELOAD
constructor to the destructor and so excludes the dynamic loader's work. This checks the
simulator's arithmetic, not a Value/Ir ratio (that ratio moved 9% in five weeks from
interpreter changes alone). A guard that cannot verify (API down, row missing, no profile
folder) fails too: one that goes quiet when blind is the "measured less, still green" fault.

  tools/codspeed_unit_guard.py             # gate: needs CODSPEED_RUN_ID and the runner's profile folder
  tools/codspeed_unit_guard.py --selftest  # every plant must go red (offline)

Exit: 0 verified, 1 UNIT DRIFT, 2 CANNOT VERIFY.
"""
import glob
import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- the claim ---------------------------------------------------------------------------
GUARD_TARGET = "observed_loop"        # plain command (no env wrapper), one row per command, no timing prints
HZ = 3.6e9                            # CodSpeed's reference frequency: seconds * HZ is a whole cycle count
EXPECTED_EVENTS = ["Ir", "Dr", "Dw", "I1mr", "D1mr", "D1mw", "ILmr", "DLmr", "DLmw", "sysCount", "sysTime", "sysCpuTime"]
CHARGES = (                           # (server column, cycles per event, the events charged)
    ("ir", 1, ("Ir", "Dr", "Dw")),
    ("l1m", 5, ("I1mr", "D1mr", "D1mw")),
    ("llm", 100, ("ILmr", "DLmr", "DLmw")),
)
EXACT = 0.5                           # cycles: the arithmetic is integer, so half a cycle is exact
GEOMETRY = ["I1 cache: 32768 B, 64 B, 8-way associative", "D1 cache: 32768 B, 64 B, 8-way associative",
            "LL cache: 8388608 B, 64 B, 16-way associative"]       # the runner's --I1/--D1/--LL, as callgrind prints them
API_URL = "https://gql.codspeed.io/"
POLL_SECONDS = 15
DEADLINE_SECONDS = 480                # wall clock for the server to process the upload; the job's own limit is 20 minutes
REQUEST_SECONDS = 30

QUERY = ("query($o:String!,$n:String!,$r:String!){ repository(owner:$o,name:$n){ run(id:$r){ id status "
         "results { benchmark { name executor } value valgrind { timeDistribution { ir l1m llm sys } } } } } }")


class Drift(Exception):
    """The unit moved: exit 1."""


class Blind(Exception):
    """The guard could not verify: exit 2."""


# --- local half: the raw events the runner wrote ----------------------------------------------
def exec_line(codspeed_yml_text, target):
    """The exec line of `target` in codspeed.yml, so the guard and the lane cannot drift apart."""
    lines = codspeed_yml_text.splitlines()
    for i, ln in enumerate(lines):
        if re.match(r'^\s*-\s*name:\s*"%s"\s*$' % re.escape(target), ln):
            for nxt in lines[i + 1:i + 4]:
                m = re.match(r'^\s*exec:\s*(.+?)\s*$', nxt)
                if m:
                    return " ".join(m.group(1).split())   # an `env` wrapper would not match the profile's cmd: line
            break
    raise Blind("target %r (or its exec line) not found in codspeed.yml" % target)


def read_callgrind(path):
    """(cmd, events header, {event: total}, cache-geometry lines) of one callgrind output; totals None if it counted nothing."""
    cmd = ev = tot = None
    geo = []
    with open(path, errors="replace") as f:
        for ln in f:
            if ln.startswith("cmd:"):
                cmd = " ".join(ln[4:].split())
            elif ln.startswith("desc:") and ("cache:" in ln):
                g = " ".join(ln[5:].split())
                if g not in geo:
                    geo.append(g)
            elif ln.startswith("events:"):
                ev = ln.split()[1:]
            elif ln.startswith("totals:") and ev:
                try:
                    v = [int(x) for x in ln.split()[1:]]
                except ValueError:
                    continue
                if len(v) != len(ev):
                    continue                    # the "totals: 0" placeholder parts
                tot = v if tot is None else [a + b for a, b in zip(tot, v)]
    return cmd, ev, (dict(zip(ev, tot)) if ev and tot else None), geo


def profile_dirs(env):
    bases = []
    for b in (env.get("TMPDIR"), tempfile.gettempdir(), "/tmp", env.get("RUNNER_TEMP")):
        if b and b not in bases:
            bases.append(b)
    dirs = []
    for b in bases:
        dirs += [d for d in glob.glob(os.path.join(b, "profile.*.out")) if os.path.isdir(d)]
    return sorted(dirs, key=lambda d: os.path.getmtime(d), reverse=True)


def local_events(env, cmd, read=read_callgrind, dirs=profile_dirs):
    """Header, event totals and cache geometry of the one profile whose command is `cmd`."""
    found = []
    for d in dirs(env):
        for p in sorted(glob.glob(os.path.join(d, "*.out"))):
            c, ev, tot, geo = read(p)
            if c == cmd and tot:
                found.append((p, ev, tot, geo))
        if found:
            break                               # the newest profile folder that holds the row
    if not found:
        near = sorted(glob.glob(os.path.join(tempfile.gettempdir(), "*profile*")))[:10]
        raise Blind("no callgrind profile for %r under %s: the runner's profile folder is not where the guard looks "
                    "(temp dir entries named *profile*: %s)" % (cmd, ", ".join(dirs(env)) or "any temp dir", near or "none"))
    if len(found) > 1:
        raise Blind("%d profiles carry the command %r (%s): the row is not unique"
                    % (len(found), cmd, ", ".join(os.path.basename(p) for p, _, _, _ in found)))
    return found[0][1], found[0][2], found[0][3]


# --- server half: CodSpeed's public API ----------------------------------------------------
def fetch_run(repo, run_id, post=None):
    owner, name = repo.split("/", 1)
    body = json.dumps({"query": QUERY, "variables": {"o": owner, "n": name, "r": run_id}}).encode()
    req = urllib.request.Request(API_URL, data=body, headers={"content-type": "application/json",
                                                              "user-agent": "eigenscript-codspeed-unit-guard"})
    try:
        raw = (post or (lambda r: urllib.request.urlopen(r, timeout=REQUEST_SECONDS).read()))(req)
        d = json.loads(raw)
    except Exception as e:  # network, HTTP, JSON: all "cannot verify yet"
        raise Blind("CodSpeed API read failed: %s" % e)
    if d.get("errors"):
        raise Blind("CodSpeed API returned errors: %s" % json.dumps(d["errors"])[:300])
    run = ((d.get("data") or {}).get("repository") or {}).get("run")
    if not run:
        raise Blind("CodSpeed API has no run %r for %s (yet)" % (run_id, repo))
    return run


def row_of(run, target):
    """{value, ir, l1m, llm} in seconds, or None while the upload is still being processed."""
    for r in run.get("results") or []:
        if (r.get("benchmark") or {}).get("name") == target:
            td = ((r.get("valgrind") or {}).get("timeDistribution")) or {}
            if r.get("value") is None or any(td.get(k) is None for k in ("ir", "l1m", "llm")):
                return None
            return {"value": float(r["value"]), "ir": float(td["ir"]), "l1m": float(td["l1m"]), "llm": float(td["llm"])}
    return None


def await_row(repo, run_id, fetch, sleep, clock=time.monotonic):
    last = "no response"
    deadline = clock() + DEADLINE_SECONDS
    while True:
        try:
            run = fetch(repo, run_id)
        except Blind as e:           # transient: the upload may not be indexed yet
            last = str(e)
            run = None
        if run is not None:
            status = str(run.get("status") or "").upper()
            if status in ("FAILURE", "FAILED", "ERROR", "CANCELLED"):
                raise Blind("CodSpeed run %s ended with status %s" % (run_id, status))
            row = row_of(run, GUARD_TARGET)
            if status == "COMPLETED" and row is not None:
                return row
            last = "status %s, %s row %s" % (status or "?", GUARD_TARGET, "present" if row else "absent")
        if clock() + POLL_SECONDS > deadline:
            raise Blind("CodSpeed run %s produced no complete %r result in %d s (%s)"
                        % (run_id, GUARD_TARGET, DEADLINE_SECONDS, last))
        sleep(POLL_SECONDS)


# --- the judgement ---------------------------------------------------------------------------
def judge(row, header, ev, geometry=GEOMETRY, charges=CHARGES, hz=HZ, expected=EXPECTED_EVENTS, exact=EXACT):
    """Raise Drift naming every property that moved; return the numbers when none did."""
    cyc = {k: row[k] * hz for k in ("value", "ir", "l1m", "llm")}
    want = {col: k * sum(ev[e] for e in evs) for col, k, evs in charges}
    seen = ("server: value %.0f = ir %.0f + l1m %.0f + llm %.0f cycles; profile: Ir %d, Dr %d, Dw %d, L1 misses %d, LL misses %d"
            % (cyc["value"], cyc["ir"], cyc["l1m"], cyc["llm"], ev["Ir"], ev["Dr"], ev["Dw"],
               ev["I1mr"] + ev["D1mr"] + ev["D1mw"], ev["ILmr"] + ev["DLmr"] + ev["DLmw"]))
    bad = []
    if list(geometry) != GEOMETRY:
        bad.append("the profile's cache geometry is %s, not %s: the simulated caches changed, so every miss count did"
                   % ("; ".join(geometry) or "absent", "; ".join(GEOMETRY)))
    if list(header) != list(expected):
        bad.append("the runner's profile carries events %s, not %s: its measurement changed (a cycle table adds columns)"
                   % (" ".join(header), " ".join(expected)))
    for col, k, evs in charges:
        if abs(cyc[col] - want[col]) > exact:
            bad.append("`%s` = %.0f cycles but %d x (%s) over the profile's events is %.0f: off by %+.0f cycles (%+.3f%%)"
                       % (col, cyc[col], k, "+".join(evs), want[col], cyc[col] - want[col],
                          100.0 * (cyc[col] / want[col] - 1.0) if want[col] else float("inf")))
    if abs(cyc["value"] - (cyc["ir"] + cyc["l1m"] + cyc["llm"])) > exact:
        bad.append("value %.0f != ir + l1m + llm = %.0f: something else is now part of the Value"
                   % (cyc["value"], cyc["ir"] + cyc["l1m"] + cyc["llm"]))
    if bad:
        raise Drift("; ".join(bad) + " [" + seen + "]. The lane's unit is not the one docs/INSTRUMENTS.md registers: check the "
                    "runner-version pin and the action SHA in .github/workflows/codspeed.yml and CodSpeed's changelog, then "
                    "re-measure BEFORE editing the claim in tools/codspeed_unit_guard.py.")
    return {"value": cyc["value"], "cycles": cyc, "want": want, "events": ev, "value_over_ir": cyc["value"] / ev["Ir"]}


def gate(env, read=lambda p: open(p).read(), events_fn=local_events, fetch=fetch_run, sleep=time.sleep, clock=time.monotonic):
    run_id = (env.get("CODSPEED_RUN_ID") or "").strip()
    if not run_id:
        raise Blind("CODSPEED_RUN_ID is empty: the action's run-id output is missing (runner older than 5.4.0, or no upload)")
    repo = env.get("GITHUB_REPOSITORY") or "InauguralSystems/EigenScript"
    cmd = exec_line(read(os.path.join(ROOT, "codspeed.yml")), GUARD_TARGET)
    header, ev, geometry = events_fn(env, cmd)
    missing = [k for k in EXPECTED_EVENTS[:9] if k not in ev]
    if missing:
        raise Blind("the profile has no %s counts" % "/".join(missing))
    if ev["Ir"] <= 0:
        raise Blind("the profile for %r counted nothing (Ir = %d): the instrumented region was empty" % (cmd, ev["Ir"]))
    row = await_row(repo, run_id, fetch, sleep, clock)
    return judge(row, header, ev, geometry), run_id


def main():
    try:
        info, run_id = gate(os.environ)
    except Drift as e:
        print("CODSPEED UNIT DRIFT: " + str(e))
        return 1
    except Blind as e:
        print("CODSPEED UNIT GUARD CANNOT VERIFY: " + str(e))
        return 2
    except Exception as e:                      # an instrument failure is not a verdict, and not a traceback with exit 1
        print("CODSPEED UNIT GUARD CANNOT VERIFY: unexpected %s: %s" % (type(e).__name__, e))
        return 2
    ev, c = info["events"], info["cycles"]
    print("codspeed unit guard: OK  run=%s row=%s  Value=%.0f cycles = ir %.0f + l1m %.0f + llm %.0f, each equal to its formula "
          "over the profile (half-cycle limit)  Value/Ir=%.4f  profile: %s"
          % (run_id, GUARD_TARGET, info["value"], c["ir"], c["l1m"], c["llm"], info["value_over_ir"],
             " ".join("%s=%d" % (k, ev[k]) for k in EXPECTED_EVENTS[:9])))
    return 0


# --- self-test: every plant must go red, the controls must stay green -------------------------
#                      Ir          Dr         Dw        I1mr   D1mr    D1mw    ILmr  DLmr  DLmw   sysCount sysTime   sysCpuTime
FIXTURE_TOTALS = [44_609_145, 12_419_284, 5_661_946, 3_000, 30_000, 12_000, 2_500, 500, 9_000, 41, 2_630_012, 1_865_757]
# The claim restated by hand, NOT through CHARGES or GEOMETRY, so that editing either breaks the controls below:
#   ir = Ir+Dr+Dw, l1m = 5 x (I1mr+D1mr+D1mw), llm = 100 x (ILmr+DLmr+DLmw), caches 32 KiB 8-way x2 + 8 MiB 16-way, 64-byte lines
HONEST = {"ir": 44_609_145 + 12_419_284 + 5_661_946, "l1m": 5 * (3_000 + 30_000 + 12_000), "llm": 100 * (2_500 + 500 + 9_000)}
HONEST_GEOMETRY = ["I1 cache: 32768 B, 64 B, 8-way associative", "D1 cache: 32768 B, 64 B, 8-way associative",
                   "LL cache: 8388608 B, 64 B, 16-way associative"]


def _fixture_profile(totals=None, header=None, cmd="./src/eigenscript bench/observed_loop.eigs", geometry=None):
    """A callgrind output in the runner's shape: placeholder parts around the real one."""
    header = header or EXPECTED_EVENTS
    totals = totals or FIXTURE_TOTALS
    geometry = HONEST_GEOMETRY if geometry is None else geometry
    hdr = "events: " + " ".join(header)
    return "\n".join(["# callgrind format", "version: 1", "creator: callgrind-3.26.0.codspeed7", "pid: 1", "cmd:  " + cmd, "part: 1"]
                     + ["desc: " + g for g in geometry]
                     + [hdr, "summary: 0", "totals: 0", "", "part: 2"] + ["desc: " + g for g in geometry]
                     + [hdr, "summary: %d" % totals[0], "totals: " + " ".join(str(t) for t in totals), "", "part: 3", hdr,
                        "summary: 0", "totals: 0", ""])


def selftest():
    import contextlib
    import io
    import subprocess
    results = []

    def check(name, ok):
        print("  %s: %s" % ("PASS" if ok else "FAIL", name))
        results.append(bool(ok))

    tmp = tempfile.mkdtemp(prefix="unit-guard-selftest.")
    prof = os.path.join(tmp, "profile.abcdefghij.out")

    def put(name, text, folder=prof):
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, name), "w") as f:
            f.write(text)

    put("100.out", _fixture_profile())
    put("101.out", _fixture_profile(cmd="exec-harness --name x ./src/eigenscript bench/observed_loop.eigs"))
    put("102.out", _fixture_profile(cmd="./src/eigenscript bench/dict_ops.eigs"))
    cmd = "./src/eigenscript bench/observed_loop.eigs"
    header, ev, geo = local_events({}, cmd, dirs=lambda e: [prof])
    check("parse: the fixture reads Ir 44,609,145, Dr 12,419,284, Dw 5,661,946, the event set and the three cache lines, "
          "and skips the placeholder parts",
          (ev["Ir"], ev["Dr"], ev["Dw"]) == (44609145, 12419284, 5661946) and header == EXPECTED_EVENTS and geo == HONEST_GEOMETRY)

    def server_row(ir=HONEST["ir"], l1m=HONEST["l1m"], llm=HONEST["llm"], extra=0.0):
        return {"value": (ir + l1m + llm + extra) / HZ, "ir": ir / HZ, "l1m": l1m / HZ, "llm": llm / HZ}

    def run(row, charges=CHARGES, hdr=header, events=ev, geometry=geo):
        return judge(row, hdr, events, geometry, charges=charges)

    def plant(name, expect, fn):
        got = "green"
        try:
            fn()
        except Drift:
            got = "drift"
        except Blind:
            got = "blind"
        check("plant %r is %s%s" % (name, expect, "" if got == expect else " (got %s)" % got), got == expect)

    plant("control: the honest row, restated by hand (ir = Ir+Dr+Dw, l1m = 5 x L1 misses, llm = 100 x LL misses)", "green",
          lambda: run(server_row()))
    plant("control: 0.3 cycle of float noise on ir", "green", lambda: run(server_row(ir=HONEST["ir"] + 0.3)))
    many = dict(ev, I1mr=500_000, D1mr=1_500_000, D1mw=1_000_000, ILmr=20_000, DLmr=300_000, DLmw=200_000)
    plant("control: a row with 3 M L1 misses and 520 K LL misses pins both coefficients", "green",
          lambda: run(server_row(l1m=5 * 3_000_000, llm=100 * 520_000), events=many))
    plant("the wrong claim (ir charges Ir only: the instructions-only claim) against an honest row", "drift",
          lambda: run(server_row(), charges=(("ir", 1, ("Ir",)),) + CHARGES[1:]))
    plant("the lane returns to instructions-only (ir = Ir, no miss terms)", "drift",
          lambda: run(server_row(ir=ev["Ir"], l1m=0, llm=0)))
    plant("the lane stops charging data writes", "drift", lambda: run(server_row(ir=ev["Ir"] + ev["Dr"])))
    plant("ir is off by 2 cycles", "drift", lambda: run(server_row(ir=HONEST["ir"] + 2)))
    plant("the L1 miss penalty moves from 5 to 6 cycles", "drift", lambda: run(server_row(l1m=6 * 45_000)))
    plant("the LL miss penalty moves from 100 to 120 cycles", "drift", lambda: run(server_row(llm=120 * 12_000)))
    plant("a stall model returns (miss terms 60% of the Value)", "drift",
          lambda: run(server_row(l1m=HONEST["ir"] * 0.6, llm=HONEST["ir"] * 0.9)))
    plant("system time is added to the Value", "drift", lambda: run(server_row(extra=2_000_000)))
    plant("the frequency changes (everything scales by 3.6/3.0)", "drift",
          lambda: run({k: v * 3.6 / 3.0 for k, v in server_row().items()}))
    plant("the profile gains per-instruction cycle columns (cycle-estimation on)", "drift",
          lambda: run(server_row(), hdr=EXPECTED_EVENTS + ["Ct", "Cl"]))
    plant("the simulated L1 shrinks to 16 KiB", "drift",
          lambda: run(server_row(), geometry=["I1 cache: 16384 B, 64 B, 8-way associative"] + HONEST_GEOMETRY[1:]))
    plant("the cache lines are missing from the profile", "drift", lambda: run(server_row(), geometry=[]))

    yml = '  - name: "observed_loop"\n    id: observed-loop\n    exec: ./src/eigenscript bench/observed_loop.eigs\n'
    honest = server_row()
    ok_run = {"id": "r", "status": "COMPLETED", "results": [{"benchmark": {"name": GUARD_TARGET, "executor": "Valgrind"},
              "value": honest["value"], "valgrind": {"timeDistribution": {k: honest[k] for k in ("ir", "l1m", "llm")}}}]}
    calls = []

    def drive(run_obj=None, env=None, yml_text=yml, fetch_script=None, folder=prof):
        env = {"CODSPEED_RUN_ID": "r1", "GITHUB_REPOSITORY": "o/n"} if env is None else env
        del calls[:]

        def fetch(repo, rid):
            calls.append(rid)
            if fetch_script:
                step = fetch_script[min(len(calls) - 1, len(fetch_script) - 1)]
                if isinstance(step, str):
                    raise Blind(step)
                return step
            return run_obj or ok_run
        now = [0.0]

        def sleep(sec):                         # a fake clock: the deadline logic runs in no real time
            now[0] += sec
        return gate(env, read=lambda p: yml_text, events_fn=lambda e, c: local_events(e, c, dirs=lambda x: [folder]),
                    fetch=fetch, sleep=sleep, clock=lambda: now[0])

    def with_status(status, with_row=True):
        r = json.loads(json.dumps(ok_run))
        r["status"] = status
        if not with_row:
            r["results"] = []
        return r

    plant("the whole path with an honest run", "green", lambda: drive())
    plant("the API errors once, then answers (transient)", "green", lambda: drive(fetch_script=["HTTP 503", ok_run]))
    plant("the run is PENDING for a while, then COMPLETED", "green",
          lambda: drive(fetch_script=[with_status("PENDING", False), with_status("PROCESSING"), ok_run]))
    plant("the API never answers", "blind", lambda: drive(fetch_script=["HTTP 503"]))
    check("a dead API is given up on within ten minutes (at most 41 reads at 15 s), not left to the job's 20-minute limit",
          10 <= len(calls) <= 41)
    plant("the run never completes", "blind", lambda: drive(run_obj=with_status("PENDING")))
    plant("the run failed server-side", "blind", lambda: drive(run_obj=with_status("FAILURE")))
    check("a failed run is reported at the first read, not at the deadline", len(calls) == 1)
    plant("the guard row is missing from the run", "blind", lambda: drive(run_obj=with_status("COMPLETED", False)))
    plant("run-id output missing", "blind", lambda: drive(env={"GITHUB_REPOSITORY": "o/n"}))
    plant("guard row renamed in codspeed.yml", "blind", lambda: drive(yml_text='  - name: "other"\n    exec: x\n'))
    plant("guard row wrapped in `env` (its profile carries another command)", "blind",
          lambda: drive(yml_text=yml.replace("exec: ./", "exec: env X=1 ./")))
    plant("the runner's profile folder is missing", "blind", lambda: drive(folder=os.path.join(tmp, "nowhere")))
    empty = os.path.join(tmp, "profile.emptyempty.out")
    os.makedirs(empty)
    plant("the profile folder holds no profile for the row", "blind", lambda: drive(folder=empty))
    twin = os.path.join(tmp, "profile.twintwintw.out")
    put("200.out", _fixture_profile(), folder=twin)
    put("201.out", _fixture_profile(), folder=twin)
    plant("two profiles carry the row's command (a twin row)", "blind", lambda: drive(folder=twin))
    zero = os.path.join(tmp, "profile.zerozerozz.out")
    put("300.out", _fixture_profile(totals=[0] * 12), folder=zero)
    plant("the profile counted nothing", "blind", lambda: drive(folder=zero))
    short = os.path.join(tmp, "profile.shortshort.out")
    put("400.out", _fixture_profile(header=["Ir", "sysTime"], totals=[5, 6]), folder=short)
    plant("the profile lacks the cache counts", "blind", lambda: drive(folder=short))
    ir_only = {"benchmark": {"name": GUARD_TARGET, "executor": "Valgrind"}, "value": ev["Ir"] / HZ,
               "valgrind": {"timeDistribution": {"ir": ev["Ir"] / HZ, "l1m": 0.0, "llm": 0.0}}}
    plant("the run drifts through the whole path (an instructions-only server)", "drift",
          lambda: drive(run_obj={**ok_run, "results": [ir_only]}))
    cyc = os.path.join(tmp, "profile.cyclecolumn.out")
    put("500.out", _fixture_profile(header=EXPECTED_EVENTS + ["Ct", "Cl"], totals=FIXTURE_TOTALS + [1, 1]), folder=cyc)
    plant("the whole path with a cycle-estimation profile", "drift", lambda: drive(folder=cyc))
    small = os.path.join(tmp, "profile.smallcaches.out")
    put("600.out", _fixture_profile(geometry=["I1 cache: 16384 B, 64 B, 8-way associative"] + HONEST_GEOMETRY[1:]), folder=small)
    plant("the whole path with a 16 KiB L1 profile", "drift", lambda: drive(folder=small))

    # the pieces the fakes above bypass: folder discovery, row choice among many, the HTTP layer, the real entry point
    base = os.path.join(tmp, "tmpbase")
    for name, age in (("profile.aaaaaaaaaa.out", 300), ("profile.bbbbbbbbbb.out", 100), ("notaprofile", 50)):
        os.makedirs(os.path.join(base, name))
        os.utime(os.path.join(base, name), (time.time() - age, time.time() - age))
    check("profile_dirs: newest profile.*.out first, other names ignored",
          [os.path.basename(d) for d in profile_dirs({"TMPDIR": base})][:2] == ["profile.bbbbbbbbbb.out", "profile.aaaaaaaaaa.out"]
          and "notaprofile" not in [os.path.basename(d) for d in profile_dirs({"TMPDIR": base})])
    many_rows = {"results": [{"benchmark": {"name": n}, "value": v, "valgrind": {"timeDistribution": {"ir": v, "l1m": 0.0, "llm": 0.0}}}
                             for n, v in (("dict_ops", 1.0), (GUARD_TARGET, 2.0), ("string_build", 3.0))]}
    check("row_of: picks the guard row by name among several", row_of(many_rows, GUARD_TARGET)["value"] == 2.0)
    check("row_of: a row without a value is not ready", row_of({"results": [{"benchmark": {"name": GUARD_TARGET}, "value": None}]}, GUARD_TARGET) is None)
    good = json.dumps({"data": {"repository": {"run": {"id": "r", "status": "COMPLETED", "results": []}}}}).encode()
    check("fetch_run: a well-formed answer is returned", fetch_run("o/n", "r", post=lambda req: good)["id"] == "r")

    def blind(fn):
        try:
            fn()
        except Blind:
            return True
        return False
    check("fetch_run: GraphQL errors are CANNOT VERIFY", blind(lambda: fetch_run("o/n", "r", post=lambda req: json.dumps({"errors": [{"message": "x"}]}).encode())))
    check("fetch_run: a partial answer (data and errors together) is CANNOT VERIFY",
          blind(lambda: fetch_run("o/n", "r", post=lambda req: json.dumps(
              {"data": {"repository": {"run": {"id": "r", "status": "COMPLETED", "results": []}}}, "errors": [{"message": "x"}]}).encode())))
    check("fetch_run: a null run is CANNOT VERIFY",
          blind(lambda: fetch_run("o/n", "r", post=lambda req: json.dumps({"data": {"repository": {"run": None}}}).encode())))
    check("fetch_run: a non-JSON answer is CANNOT VERIFY", blind(lambda: fetch_run("o/n", "r", post=lambda req: b"<html>")))

    def boom_post(req):
        raise OSError("down")
    check("fetch_run: a network failure is CANNOT VERIFY", blind(lambda: fetch_run("o/n", "r", post=boom_post)))
    env = {k: v for k, v in os.environ.items() if k != "CODSPEED_RUN_ID"}
    p = subprocess.run([sys.executable, os.path.abspath(__file__)], env=env, capture_output=True, text=True, cwd=ROOT)
    check("the real entry point, run as the workflow runs it without a run-id, exits 2 and says CANNOT VERIFY",
          p.returncode == 2 and "CANNOT VERIFY" in p.stdout)

    # exit codes: a verdict (1), an instrument failure (2) and a crash (2, not a traceback with exit 1)
    real_gate = globals()["gate"]
    try:
        for name, exc, want in (("drift", Drift("x"), 1), ("blind", Blind("x"), 2), ("a crash", RuntimeError("x"), 2)):
            def boom(*a, **k):
                raise exc
            globals()["gate"] = boom
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = main()
            check("main() maps %s to exit %d" % (name, want), rc == want and buf.getvalue().strip() != "")
    finally:
        globals()["gate"] = real_gate

    shutil.rmtree(tmp, ignore_errors=True)
    n, ok = len(results), sum(results)
    print("SELFTEST %s: %d/%d" % ("OK" if ok == n else "FAILED", ok, n))
    return 0 if ok == n else 1


if __name__ == "__main__":
    sys.exit(selftest() if "--selftest" in sys.argv[1:] else main())
