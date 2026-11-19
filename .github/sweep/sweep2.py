#!/usr/bin/env python3
"""sweep2.py: single-edit mutants of the stall rule, read by two contracts.

The population is three regions, the
operators below at every site, and the hand variants.

Arms:
  B  the base's contract on the base's build with the mutant
  H  the head's contract on the head's build with the mutant
(SWEEP_H_CONTRACT names another contract file for the H arm: the positive controls.)

Regions:
  R1  src/vm.c   the reader's four functions
  R2  src/vm.c   the loop's stall counter
  R3  src/eigenscript.c   every function the reader calls, directly or through
      one another (derived here from the head's two files)
A region's text must be byte-identical in the two trees; the tool checks it.

Operators: ROR LOR CON AOR UNM NOT NEG DEL RET (as in the first tool), and the
ones the bar's review added (see OPERATORS below).

Usage: sweep2.py list | census | run [--only ID ... | --shard I/N] | merge DIR ... | table
Env: SWEEP_S (trees B and H), SWEEP_OUT, SWEEP_GENV (optional wrapper), SWEEP_CC.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

S = Path(os.environ["SWEEP_S"])
OUT = Path(os.environ["SWEEP_OUT"])
GENV = os.environ.get("SWEEP_GENV", "")
CC = os.environ.get("SWEEP_CC", "")
H_CONTRACT = os.environ.get("SWEEP_H_CONTRACT", "tests/phase2/stall_contract.py")
ONLY_FILE = set(Path(os.environ["SWEEP_ONLY_FILE"]).read_text().split()) if os.environ.get("SWEEP_ONLY_FILE") else None
ARMS = {"B": ("B", "tests/phase2/stall_contract.py"), "H": ("H", H_CONTRACT)}
VM, ES = "src/vm.c", "src/eigenscript.c"
R1_START = "static int obs_stall_magnitude_cmp(ObserverNumber a, ObserverNumber b) {"
R1_END = "void vm_obs_slot_dropped(Env *e) {"
R2_ANCHOR = "        if (obs_stall_quiet()) {"
R2_END = "    /* #772: the iteration cap fires ONLY under an explicitly armed sandbox"
READER = ("obs_stall_magnitude_cmp", "obs_stall_amplitude_noncontracting",
          "obs_stall_window_nonfinite", "obs_stall_quiet")
FUNC_RE = re.compile(r"^(?:static\s+)?(?:inline\s+)?(?:const\s+)?[A-Za-z_][\w\s\*]*?\b([A-Za-z_]\w*)\s*\([^;{]*\)\s*\{\s*$")
ONE_LINE_RE = re.compile(r"^(?:static\s+)?(?:inline\s+)?(?:const\s+)?[A-Za-z_][\w\s\*]*?\b([A-Za-z_]\w*)\s*\([^;{]*\)\s*\{.*\}\s*$")


def orig(tree, rel):
    """The unmutated file of a tree, kept beside the tree at first use."""
    keep = S / ("%s.%s.orig" % (tree, rel.replace("/", "_")))
    if not keep.exists():
        keep.write_text((S / tree / rel).read_text())
    return keep.read_text()


def functions(text):
    """name -> (first line index, last line index), for top-level definitions."""
    lines, out, i = text.split("\n"), {}, 0
    while i < len(lines):
        m = FUNC_RE.match(lines[i])
        one = ONE_LINE_RE.match(lines[i])
        if lines[i][:1] in (" ", "\t", "}", "#", "/"):
            pass
        elif m:
            j = i
            while j < len(lines) and lines[j] != "}":
                j += 1
            out[m.group(1)] = (i, j)
            i = j
        elif one:  # a definition on one line: `int f(...) { return g(...); }`
            out[one.group(1)] = (i, i)
        i += 1
    return out


def closure():
    """R3: the functions of src/eigenscript.c that the reader calls, transitively."""
    vm, es = orig("H", VM), orig("H", ES)
    fv, fe = functions(vm), functions(es)
    vl, el = vm.split("\n"), es.split("\n")
    body = lambda lines, span: "\n".join(lines[span[0]:span[1] + 1])
    todo = []
    for name in READER:
        todo += [c for c in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body(vl, fv[name])) if c in fe]
    clo = set()
    while todo:
        f = todo.pop()
        if f in clo:
            continue
        clo.add(f)
        todo += [c for c in re.findall(r"\b([A-Za-z_]\w*)\s*\(", body(el, fe[f])) if c in fe and c not in clo]
    return sorted(clo, key=lambda f: fe[f][0])


def regions():
    """[(region, file, function or None, first line index, end line index exclusive)] in the HEAD's files."""
    vm = orig("H", VM).split("\n")
    out = [("R1", VM, None, vm.index(R1_START), vm.index(R1_END))]
    c = vm.index(R2_ANCHOR)
    assert vm.count(R2_ANCHOR) == 1 and vm[c - 3] == "    if (g_unobserved_depth == 0) {", vm[c - 3]
    out.append(("R2", VM, None, c - 3, vm.index(R2_END)))
    fe = functions(orig("H", ES))
    for f in closure():
        out.append(("R3", ES, f, fe[f][0], fe[f][1] + 1))
    return out


def check_identical():
    """Every region's text is the same in the base and in the head."""
    for reg, rel, func, a, b in regions():
        h = orig("H", rel).split("\n")
        bt = orig("B", rel).split("\n")
        if func:
            fb = functions("\n".join(bt))
            assert func in fb, "%s is not in the base" % func
            ba, bb = fb[func][0], fb[func][1] + 1
        else:
            ba, bb = a, b
        assert h[a:b] == bt[ba:bb], "region %s %s differs between base and head" % (reg, func or rel)


def code_lines(lines, a, b):
    out, inc = [], False
    for i in range(a, b):
        s = lines[i].strip()
        if inc:
            if "*/" in s:
                inc = False
            continue
        if s.startswith("/*"):
            if "*/" not in s:
                inc = True
            continue
        if not s or s.startswith("//") or s in ("{", "}"):
            continue
        # a comment opened after code on this line and closed on a later one
        k = s.rfind("/*")
        if k >= 0 and "*/" not in s[k:]:
            inc = True
        out.append(i)
    return out


ROR = {"<=": ["<", ">"], ">=": [">", "<"], "==": ["!="], "!=": ["=="],
       "<": ["<=", ">="], ">": [">=", "<="]}
ROR_RE = re.compile(r"<=|>=|==|!=|(?<![-<>=!])<(?![<=])|(?<![-<>=!])>(?![>=])")
REL_RE = re.compile(r"<=|>=|==|!=|(?<![-<>=!])<(?![<=])|(?<![-<>=!])>(?![>=])")


def paren_span(line, start):
    """Index just past the parenthesis that closes the one opened before `start`."""
    depth, i = 1, start
    while i < len(line) and depth:
        depth += {"(": 1, ")": -1}.get(line[i], 0)
        i += 1
    return i - 1 if depth == 0 else None


def top_operands(expr):
    """(start, end) of each operand of the top-level && and || of an expression."""
    out, depth, start, i = [], 0, 0, 0
    while i < len(expr):
        ch = expr[i]
        depth += {"(": 1, ")": -1, "[": 1, "]": -1}.get(ch, 0)
        if depth == 0 and expr[i:i + 2] in ("&&", "||"):
            out.append((start, i))
            start = i + 2
            i += 1
        i += 1
    out.append((start, len(expr)))
    return out


def tru_edits(line):
    """TRU: a plain truth test made a comparison with one."""
    spans = []
    m = re.search(r"\b(?:if|while) \(", line)
    if m:
        e = paren_span(line, m.end())
        if e is not None:
            spans.append((m.end(), e))
    m = re.search(r"\breturn ([^;]+);", line)
    if m:
        spans.append((m.start(1), m.end(1)))
    out = []
    for a, b in spans:
        expr = line[a:b]
        for s, e in top_operands(expr):
            op = expr[s:e]
            core = op.strip()
            if not core or REL_RE.search(core) or core.startswith("!") or re.fullmatch(r"[-\d.]+", core):
                continue
            if not re.fullmatch(r"[A-Za-z_][\w\->.\[\]]*(\(.*\))?", core):
                continue
            lead = op[:len(op) - len(op.lstrip())]
            trail = op[len(op.rstrip()):]
            out.append(line[:a] + expr[:s] + lead + core + " > 1" + trail + expr[e:] + line[b:])
    return out


def line_edits(ln):
    """(operator, new line) for every single edit of one line."""
    out = []
    for m in ROR_RE.finditer(ln):
        for r in ROR[m.group(0)]:
            out.append(("ROR", ln[:m.start()] + r + ln[m.end():]))
    for m in re.finditer(r"&&|\|\|", ln):
        out.append(("LOR", ln[:m.start()] + ("||" if m.group(0) == "&&" else "&&") + ln[m.end():]))
    for m in re.finditer(r"(?<![\w.])(?<![eE][-+])(\d+)(?![\w.])", ln):
        n = int(m.group(1))
        for r in ([n + 1, n - 1] if n > 0 else [n + 1]):
            out.append(("CON", ln[:m.start()] + str(r) + ln[m.end():]))
    for m in re.finditer(r" \+ | - | / | \+= ", ln):
        r = {" + ": " - ", " - ": " + ", " / ": " * ", " += ": " -= "}[m.group(0)]
        out.append(("AOR", ln[:m.start()] + r + ln[m.end():]))
    for m in re.finditer(r"(?<=[= (])-(?=[A-Za-z_])", ln):
        out.append(("UNM", ln[:m.start()] + ln[m.end():]))
    for m in re.finditer(r"!(?!=)", ln):
        out.append(("NOT", ln[:m.start()] + ln[m.end():]))
    for m in re.finditer(r"\bif \(", ln):
        e = paren_span(ln, m.end())
        if e is not None:
            out.append(("NEG", ln[:m.end()] + "!(" + ln[m.end():e] + ")" + ln[e:]))
    st = ln.strip()
    if st.endswith(";"):
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(("DEL", indent + ("else ;" if st.startswith("else ") else ";")))
    m = re.search(r"\breturn (?![01];)([^;]+);", ln)
    if m:
        for r in ("0", "1"):
            out.append(("RET", ln[:m.start(1)] + r + ln[m.end(1):]))
    for new in tru_edits(ln):
        out.append(("TRU", new))
    for op, new in EXTRA(ln):
        out.append((op, new))
    return out


GATES = (["fabs(s->last_value) >= %s" % t for t in ("1e-3", "1.0", "1e3", "1e5")]
         + ["fabs(s->last_value) < %s" % t for t in ("1e-3", "1.0", "1e3", "1e5")]
         + ["s->values_count > 1", "s->values_count > 2", "s->values_count > (size_t)observer_slot_window(s)",
            "s->last_value > 0", "s->last_value < 0"]
         + [neg + "observer_slot_%s(s)" % p for p in ("converged", "stable", "equilibrium", "improving",
                                                    "oscillating", "diverging") for neg in ("", "!")])
GATE_FUNCS = ("obs_stall_quiet", "observer_slot_quiet")


def gate_edits(ln):
    """GATE: one more condition put on an arm. Every `if (C) ...` and every `return E;` with a
    non-literal E, in the two functions that decide the quiet reading: C becomes `(C) && G`,
    E becomes `(E) && G`, for each G of the fixed list."""
    out = []
    m = re.search(r"\bif \(", ln)
    if m:
        e = paren_span(ln, m.end())
        if e is not None:
            for g in GATES:
                out.append(ln[:m.end()] + "(" + ln[m.end():e] + ") && " + g + ln[e:])
    m = re.search(r"\breturn (?![01];)([^;]+);", ln)
    if m:
        for g in GATES:
            out.append(ln[:m.start(1)] + "(" + m.group(1) + ") && " + g + ln[m.end(1):])
    return out


def EXTRA(ln):
    return []


def mechanical():
    muts = []
    for reg, rel, func, a, b in regions():
        lines = orig("H", rel).split("\n")
        seen = set()
        for i in code_lines(lines, a, b):
            for op, new in line_edits(lines[i]):
                if new == lines[i] or (i, new) in seen:
                    continue
                seen.add((i, new))
                where = "%s+%d" % (func, i - a) if func else "L%d" % (i + 1)
                mid = "%s-%s-%s-%s" % (reg, op, where, hashlib.sha256(new.encode()).hexdigest()[:6])
                muts.append({"id": mid, "region": reg, "file": rel, "func": func, "rel": i - a,
                             "line": i + 1, "op": op, "old": lines[i].strip(), "new_line": new})
        # a `return` that runs over more than one line: RET and TRU on the statement as one line
        cl = code_lines(lines, a, b)
        for i in cl:
            if not re.search(r"\breturn\b", lines[i]) or ";" in lines[i]:
                continue
            j = i
            while j + 1 < b and ";" not in lines[j]:
                j += 1
            joined = lines[i].rstrip() + " " + " ".join(x.strip() for x in lines[i + 1:j + 1])
            edits = []
            m = re.search(r"\breturn (?![01];)([^;]+);", joined)
            if m:
                edits += [("RET", joined[:m.start(1)] + r + joined[m.end(1):]) for r in ("0", "1")]
            edits += [("TRU", new) for new in tru_edits(joined)]
            for op, new in edits:
                where = "%s+%d" % (func, i - a) if func else "L%d" % (i + 1)
                mid = "%s-%s-%s-%s" % (reg, op, where, hashlib.sha256(new.encode()).hexdigest()[:6])
                muts.append({"id": mid, "region": reg, "file": rel, "func": func, "rel": i - a,
                             "line": i + 1, "op": op, "old": lines[i].strip(), "new_line": new, "drop": j - i})
        # GATE, in the two functions that decide the quiet reading
        fn = func
        if reg == "R1":
            fv = functions(orig("H", VM))
            ga, gb = fv["obs_stall_quiet"]
            span, fn = range(ga, gb + 1), "obs_stall_quiet"
        elif func in GATE_FUNCS:
            span = range(a, b)
        else:
            span = ()
        for i in [i for i in code_lines(lines, a, b) if i in span]:
            if "const ObserverSlot *s = " in lines[i] or "!s ||" in lines[i] or "if (!s)" in lines[i]:
                continue  # before `s` is known to be a slot
            for new in gate_edits(lines[i]):
                where = "%s+%d" % (func, i - a) if func else "L%d" % (i + 1)
                mid = "%s-GATE-%s-%s" % (reg, where, hashlib.sha256(new.encode()).hexdigest()[:6])
                muts.append({"id": mid, "region": reg, "file": rel, "func": func, "rel": i - a,
                             "line": i + 1, "op": "GATE", "old": lines[i].strip(), "new_line": new})
    return muts


IDX = ("        int idx = (int)s->values_head - 1 - (int)i;\n"
       "        while (idx < 0) idx += s->values_cap;\n"
       "        ObserverNumber v = s->v_values[idx];\n"
       "        if (!v.is_int && !isfinite(v.value)) return 1;")
HEADW = ("static int obs_stall_window_nonfinite(const ObserverSlot *s) {\n"
         "    size_t n = s->values_count;\n"
         "    size_t full = (size_t)observer_slot_window(s) + 1;\n"
         "    if (n > full) n = full;")
Q = "    if (observer_slot_quiet(s)) return 1;"
REL = "fabs(s->v_rel[s->v_window_head ? s->v_window_head - 1 : s->v_cap - 1])"
FACTORS = ["0.001", "0.01", "0.1", "0.5", "0.9", "0.95", "0.99", "0.998", "0.9993",
           "0.9995", "0.99999", "1.0006", "1.002", "1.01", "1.1", "2.0", "10.0", "100.0"]


def hand():
    vm = orig("H", VM)
    idx = lambda expr: (IDX, IDX.replace("(int)s->values_head - 1 - (int)i", expr))

    def head(newfull=None, newcount=None, nocap=False):
        h = HEADW
        if newfull:
            h = h.replace("(size_t)observer_slot_window(s) + 1", newfull)
        if newcount:
            h = h.replace("s->values_count", newcount)
        if nocap:
            h = h.replace("    if (n > full) n = full;", "    (void)full;")
        return (HEADW, h)

    v = {
        "c-r312": (Q, "    if (0 && observer_slot_quiet(s)) return 1;"),
        "c-r318": idx("(int)s->values_head - (int)i"),
        "c-r319": idx("(int)s->values_head - 2 - (int)i"),
        "c-start+2": idx("(int)s->values_head + 1 - (int)i"),
        "c-start-2": idx("(int)s->values_head - 3 - (int)i"),
        "c-extent-1": head(newfull="(size_t)observer_slot_window(s)"),
        "c-extent-2": head(newfull="(size_t)observer_slot_window(s) - 1"),
        "c-extent+1": head(newfull="(size_t)observer_slot_window(s) + 2"),
        "c-nocap": head(nocap=True),
        "c-count-1": head(newcount="(size_t)(s->values_count ? s->values_count - 1 : 0)"),
        "c-f-vwincount": head(newcount="s->v_window_count"),
        "c-e-vcap": (IDX, IDX.replace("idx += s->values_cap", "idx += s->v_cap")),
        "c-q-fullwin": (Q, "    if (observer_slot_quiet(s) && s->values_count > (size_t)observer_slot_window(s)) return 1;"),
        "c-q-after-div": (Q + "\n    if (observer_slot_diverging(s)) return 1;",
                          "    if (observer_slot_diverging(s)) return 1;\n"
                          "    if (observer_slot_quiet(s) && !observer_slot_oscillating(s)) return 1;"),
        "g-q-only-osc": (Q, "    if (observer_slot_quiet(s) && observer_slot_oscillating(s)) return 1;"),
        "g-q-not-osc": (Q, "    if (observer_slot_quiet(s) && !observer_slot_oscillating(s)) return 1;"),
        "g-q-only-div": (Q, "    if (observer_slot_quiet(s) && observer_slot_diverging(s)) return 1;"),
        "g-q-not-div": (Q, "    if (observer_slot_quiet(s) && !observer_slot_diverging(s)) return 1;"),
    }
    for f in FACTORS:
        if float(f) < 1:
            v["t-x" + f] = (Q, "    if (observer_slot_quiet(s) && %s < g_obs_dh_zero * %s) return 1;" % (REL, f))
        else:
            v["t-x" + f] = (Q, "    if (observer_slot_quiet(s) || (s->v_rel && s->v_window_count && %s < g_obs_dh_zero * %s)) return 1;" % (REL, f))
    # the third blind pass's own variants (its mutate3.py), with the file each edits
    NF = "    if (obs_stall_window_nonfinite(s)) return 1;\n"
    DIV = "    if (observer_slot_diverging(s)) return 1;\n"
    OSC = "    if (observer_slot_oscillating(s))\n        return obs_stall_amplitude_noncontracting(s);\n"
    ARMSX = NF + Q + "\n" + DIV + OSC
    CNT = "        if (obs_stall_quiet()) {\n            g_loop_stall_count++;\n            if (g_loop_stall_count >= 100) {"
    RESET = "        } else {\n            g_loop_stall_count = 0;\n        }\n    }\n    /* #772"
    GATEX = "    if (g_unobserved_depth == 0) {\n        /* The shared reader"
    QF = "        return obs_v_count(s) && fabs(observer_slot_v_get(s, 0)) < g_obs_dh_zero;"
    qk = lambda k: (Q, "    if (observer_slot_quiet(s) && %s < g_obs_dh_zero * %s) return 1;" % (REL, k))
    p3 = {
        "p3-q-k0.9985": (VM,) + qk("0.9985"),
        "p3-q-k0.9999": (VM,) + qk("0.9999"),
        "p3-n-first1": (ES, QF, QF.replace("obs_v_count(s) &&", "obs_v_count(s) > 1 &&")),
        "p3-n-first1-vm": (VM, Q, "    if (s->values_count > 2 && observer_slot_quiet(s)) return 1;"),
        "p3-n-first2": (ES, QF, QF.replace("obs_v_count(s) &&", "obs_v_count(s) > 2 &&")),
        "p3-n-oldest": (ES, QF, QF.replace("observer_slot_v_get(s, 0)", "observer_slot_v_get(s, obs_v_count(s) - 1)")),
        "p3-n-v1": (ES, QF, QF.replace("observer_slot_v_get(s, 0)", "observer_slot_v_get(s, 1)")),
        "p3-n-skip-iter1": (VM, GATEX, GATEX.replace("g_unobserved_depth == 0)", "g_unobserved_depth == 0 && g_loop_iterations > 1)")),
        "p3-n-ge101": (VM, CNT, CNT.replace(">= 100", ">= 101")),
        "p3-n-ge99": (VM, CNT, CNT.replace(">= 100", ">= 99")),
        "p3-n-noreset": (VM, RESET, RESET.replace("            g_loop_stall_count = 0;\n", "            (void)0;\n")),
        "p3-n-osc-first": (VM, ARMSX, NF + OSC + Q + "\n" + DIV),
        "p3-n-nf-last": (VM, ARMSX, Q + "\n" + DIV + OSC + NF),
        "p3-n-quiet-in-osc": (VM, Q, "    if (observer_slot_quiet(s) && observer_slot_oscillating(s)) return 1;"),
        "p3-n-quiet-not-impr": (VM, Q, "    if (observer_slot_quiet(s) && !observer_slot_improving(s)) return 1;"),
    }
    out = []
    for name, (old, new) in v.items():
        assert vm.count(old) == 1, "hand variant %s: original occurs %d times" % (name, vm.count(old))
        out.append({"id": name, "region": "hand", "file": VM, "func": None, "op": name.split("-")[0],
                    "old": "", "new_line": new.strip().splitlines()[-1], "whole": (old, new)})
    for name, (rel, old, new) in p3.items():
        for t in ("B", "H"):
            assert orig(t, rel).count(old) == 1, "hand variant %s: original occurs %d times in %s of %s" % (
                name, orig(t, rel).count(old), rel, t)
        out.append({"id": name, "region": "hand", "file": rel, "func": None, "op": "p3",
                    "old": "", "new_line": new.strip().splitlines()[-1], "whole": (old, new)})
    return out


def population():
    return mechanical() + hand()


def apply(tree, m):
    """Write the mutant into one tree (and put every other mutated file back)."""
    for rel in (VM, ES):
        text = orig(tree, rel)
        if rel == m["file"]:
            if "whole" in m:
                old, new = m["whole"]
                assert text.count(old) == 1
                text = text.replace(old, new)
            else:
                lines = text.split("\n")
                if m["func"]:
                    a = functions(text)[m["func"]][0]
                    i = a + m["rel"]
                else:
                    i = m["line"] - 1
                assert lines[i].strip() == m["old"], "line moved in %s: %r" % (tree, lines[i])
                lines[i] = m["new_line"]
                for d in range(1, m.get("drop", 0) + 1):
                    lines[i + d] = ""  # the rest of a statement that was joined onto its first line
                text = "\n".join(lines)
        cur = (S / tree / rel)
        if cur.read_text() != text:
            cur.write_text(text)


def restore(tree):
    for rel in (VM, ES):
        if (S / tree / rel).read_text() != orig(tree, rel):
            (S / tree / rel).write_text(orig(tree, rel))


UB_HAND = ("c-start+2", "c-start-2", "c-r318", "c-r319", "c-extent+1", "c-nocap", "c-count-1", "c-f-vwincount",
           "c-e-vcap", "p3-n-oldest", "p3-n-v1")


def ub_suspect(m):
    """A mutant that can read outside an array or an unset variable with no compiler warning:
    its edited line (old or new, or the whole replacement of a hand variant) holds a ring index
    or a subscript, or it deletes a call that fills a variable through a pointer."""
    text = m.get("old", "") + " " + m.get("new_line", "") + " " + " ".join(m.get("whole", ()))
    if re.search(r"\bidx\b|\[[^\]]*\]|_head\b|\(int\)back\b|\(int\)i\b", text):
        return True
    if m.get("op") == "DEL" and "&" in m.get("old", "").replace("&&", ""):
        return True
    return m["id"] in UB_HAND


def sh(cmd, log, timeout):
    with open(log, "w") as f:
        try:
            return subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            return 124


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(tree, log):
    cmd = ["make", "-C", str(S / tree)]
    if GENV:
        cmd = ["env", "GATE_ENV_CC=" + CC, GENV] + cmd
    return sh(cmd, log, 1800)


def build_both(name):
    logs = {t: OUT / "logs" / ("%s.%s.build.log" % (name, t)) for t in ("B", "H")}
    if GENV:
        return {t: build(t, logs[t]) for t in ("B", "H")}
    with ThreadPoolExecutor(max_workers=2) as ex:
        futs = {t: ex.submit(build, t, logs[t]) for t in ("B", "H")}
        return {t: futs[t].result() for t in ("B", "H")}


def contract(arm, log, long_bound=False):
    tree, rel = ARMS[arm]
    cmd = ["env", "-C", str(S / tree), "python3", "-W", "error", rel, "src/eigenscript"]
    if long_bound:
        cmd += ["--timeout", "60"]
    rc = sh(([GENV] if GENV else []) + cmd, log, 7000 if long_bound else 1500)
    text = Path(log).read_text()
    fails = sorted(set(re.findall(r"^stall-contract: FAIL (\S+)", text, re.M)))
    m = re.search(r"^stall-contract: measured=(\d+) failures=(\d+)", text, re.M)
    tiers = {}
    for v, case, rcs in re.findall(r"^stall-contract: (PASS|FAIL) (\S+) tier=\S+ rc=(\d+)", text, re.M):
        tiers.setdefault(case, []).append((v, rcs))
    mixed = sorted(c for c, t in tiers.items()
                   if any(r == "124" for _, r in t) and any(v == "PASS" for v, _ in t))
    fail_rcs = re.findall(r"^stall-contract: FAIL \S+ tier=\S+ rc=(-?\d+)", text, re.M)
    out = {"rc": rc, "measured": int(m.group(1)) if m else None,
           "failures": int(m.group(2)) if m else None, "red_cases": fails, "mixed_timeouts": mixed,
           "timeout_only": bool(fail_rcs) and all(r == "124" for r in fail_rcs)}
    if mixed and not long_bound:
        # A case that timed out in one tier and passed in another may be load: the contract is run
        # once more with a 60 s bound for each reading, and that run's verdict counts. A case that
        # times out in every tier is a loop that does not end, and its red stands as it is.
        again = contract(arm, Path(str(log) + ".long"), long_bound=True)
        out["first_rc"], out["rc"], out["red_cases_long"] = rc, again["rc"], again["red_cases"]
        out["red_cases"] = again["red_cases"]
    return out


def load_state():
    p = OUT / "state.json"
    return json.loads(p.read_text()) if p.exists() else {}


def run(only, shard=None):
    (OUT / "logs").mkdir(parents=True, exist_ok=True)
    check_identical()
    state = load_state()
    muts = population()
    if "clean" not in state:
        for t in ("B", "H"):
            restore(t)
        assert not any(build_both("clean").values())
        rec = {"sha": {t: sha(S / t / "src/eigenscript") for t in ("B", "H")}, "h_contract": H_CONTRACT}
        for arm in ARMS:
            rec[arm] = contract(arm, OUT / "logs" / ("clean.%s.log" % arm))
            assert rec[arm]["rc"] == 0 and rec[arm]["failures"] == 0, (arm, rec[arm])
        assert rec["B"]["measured"] == 68, "the base's contract measures %s readings, not 68" % rec["B"]["measured"]
        assert rec["H"]["measured"] and rec["H"]["measured"] % 4 == 0 and rec["H"]["measured"] >= 80, rec["H"]
        assert rec["sha"]["B"] != rec["sha"]["H"], "the two trees built the same binary"
        state["clean"] = rec
        (OUT / "state.json").write_text(json.dumps(state, indent=1))
        print("clean:", json.dumps(rec), flush=True)
    clean_sha = state["clean"]["sha"]
    for k, m in enumerate(muts):
        if only and m["id"] not in only:
            continue
        if ONLY_FILE and m["id"] not in ONLY_FILE:
            continue
        if shard and k % shard[1] != shard[0]:
            continue
        if m["id"] in state:
            continue
        rec = {k2: m.get(k2) for k2 in ("region", "file", "func", "op", "old", "new_line")}
        for t in ("B", "H"):
            apply(t, m)
        rcs = build_both(m["id"])
        logs = "".join((OUT / "logs" / ("%s.%s.build.log" % (m["id"], t))).read_text() for t in ("B", "H"))
        rec["ub"] = "control reaches end of non-void function" in logs
        # A mutant of a ring index or of an array subscript can read outside the array with no
        # warning: marked as a suspect by its line, and reported apart.
        rec["ub_suspect"] = rec["ub"] or ub_suspect(m)
        if rcs["B"] != rcs["H"]:
            rec["status"] = "tool-error"  # one tree built and the other did not
        elif any(rcs.values()):
            rec["status"] = "no-build"
        else:
            shas = {t: sha(S / t / "src/eigenscript") for t in ("B", "H")}
            if shas == clean_sha:
                rec["status"] = "same-binary"
            else:
                rec["status"] = "ran"
                with ThreadPoolExecutor(max_workers=1 if GENV else 2) as ex:
                    futs = {arm: ex.submit(contract, arm, OUT / "logs" / ("%s.%s.log" % (m["id"], arm)))
                            for arm in ARMS}
                    for arm in ARMS:
                        rec[arm] = futs[arm].result()
        state[m["id"]] = rec
        (OUT / "state.json").write_text(json.dumps(state, indent=1))
        verdict = rec["status"] if rec["status"] != "ran" else " ".join(
            "%s=%s" % (a, "red" if rec[a]["rc"] else "green") for a in ARMS)
        print("[%d/%d] %s: %s%s" % (k + 1, len(muts), m["id"], verdict, " UB" if rec["ub"] else ""), flush=True)
    for t in ("B", "H"):
        restore(t)
    assert not any(build_both("restore").values())
    for t in ("B", "H"):
        assert sha(S / t / "src/eigenscript") == clean_sha[t], "tree %s not restored" % t
    print("SWEEP-DONE population=%d records=%d" % (len(muts), len(state) - 1), flush=True)


def merge(dirs):
    OUT.mkdir(parents=True, exist_ok=True)
    out, cleans = {}, []
    for d in dirs:
        st = json.loads((Path(d) / "state.json").read_text())
        cleans.append(st.pop("clean"))
        for k, v in st.items():
            assert k not in out, "mutant %s in two shards" % k
            out[k] = v
    assert all(c["sha"] == cleans[0]["sha"] for c in cleans), "the shards' clean builds differ"
    out["clean"] = cleans[0]
    (OUT / "state.json").write_text(json.dumps(out, indent=1))
    print("merged %d shard(s): %d mutant records" % (len(dirs), len(out) - 1))


def census():
    check_identical()
    muts = population()
    by = {}
    for m in muts:
        by[(m["region"], m["op"] if m["region"] != "hand" else "-")] = by.get((m["region"], m["op"] if m["region"] != "hand" else "-"), 0) + 1
    print("population: %d" % len(muts))
    for reg in ("R1", "R2", "R3", "hand"):
        row = {op: n for (r, op), n in by.items() if r == reg}
        print("  %-4s %4d  %s" % (reg, sum(row.values()), " ".join("%s=%d" % kv for kv in sorted(row.items()))))
    print("R3 functions (%d): %s" % (len(closure()), ", ".join(closure())))


def table():
    state = load_state()
    muts = population()
    missing = [m["id"] for m in muts if m["id"] not in state]
    ran = [(m, state[m["id"]]) for m in muts if m["id"] in state and state[m["id"]]["status"] == "ran"]
    cnt = lambda st: sum(1 for m in muts if m["id"] in state and state[m["id"]]["status"] == st)
    red = lambda r, a: r[a]["rc"] != 0
    print("population %d; not run %d; no-build %d; tool-error %d; same-binary %d; ran %d" % (
        len(muts), len(missing), cnt("no-build"), cnt("tool-error"), cnt("same-binary"), len(ran)))
    cl = state.get("clean", {})
    if cl:
        print("clean: B measured=%s failures=%s, H measured=%s failures=%s, hashes differ: %s" % (
            cl["B"]["measured"], cl["B"]["failures"], cl["H"]["measured"], cl["H"]["failures"],
            cl["sha"]["B"] != cl["sha"]["H"]))
    b = [(m, r) for m, r in ran if red(r, "B")]
    print("red on B: %d; of those red on H: %d; red on H and not on B: %d; red on neither: %d" % (
        len(b), sum(1 for m, r in b if red(r, "H")), sum(1 for m, r in ran if red(r, "H") and not red(r, "B")),
        sum(1 for m, r in ran if not red(r, "H") and not red(r, "B"))))
    for ub in (False, True):
        sel = [(m, r) for m, r in b if not red(r, "H") and bool(r.get("ub_suspect", r.get("ub"))) == ub]
        print("\n## red on B and green on H%s: %d" % (" (undefined-behaviour suspects, apart)" if ub else "", len(sel)))
        for m, r in sel:
            print("  %s | %s | %s => %s | B red: %s" % (m["id"], m["func"] or m["file"], m["old"], m["new_line"].strip(),
                                                       ", ".join(r["B"]["red_cases"])))
    ho = [(m, r) for m, r in ran if red(r, "H") and not red(r, "B")]
    print("\n## green on B and red on H: %d" % len(ho))
    for m, r in ho:
        print("  %s | %s => %s | H red: %s" % (m["id"], m["old"], m["new_line"].strip(), ", ".join(r["H"]["red_cases"])))
    print("\n## red on both, by the head's case that sees it (a case that sees nothing else is a change detector)")
    seen = {}
    for m, r in ran:
        if red(r, "H"):
            for c in r["H"]["red_cases"]:
                seen[c] = seen.get(c, 0) + 1
    print("  " + ", ".join("%s=%d" % kv for kv in sorted(seen.items(), key=lambda kv: -kv[1])))
    mixed = [(m["id"], a, r[a]["mixed_timeouts"]) for m, r in ran for a in ARMS if r[a].get("mixed_timeouts")]
    print("\ncases with a timeout in one tier beside a pass in another: %d" % len(mixed))
    for row in mixed:
        print("  %s %s %s" % row)
    ubs = [m["id"] for m in muts if m["id"] in state and state[m["id"]].get("ub")]
    print("mutants whose build warns that control reaches the end of a non-void function: %d %s" % (len(ubs), " ".join(ubs)))
    sus = [m["id"] for m in muts if m["id"] in state and state[m["id"]].get("ub_suspect")]
    print("undefined-behaviour suspects in all (that warning, or an index or subscript on the edited line): %d" % len(sus))
    lo = [(m["id"], a) for m, r in ran for a in ARMS if "first_rc" in r[a]]
    print("arms run again with a 60 s bound (a timeout beside a pass in the first run): %d %s" % (len(lo), " ".join("%s:%s" % x for x in lo[:30])))
    if missing:
        print("NOT RUN: %s" % " ".join(missing[:20]))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "census"
    a = sys.argv[2:]
    if cmd == "list":
        for m in population():
            print("%-44s %s => %s" % (m["id"], m["old"], m["new_line"].strip()))
    elif cmd == "census":
        census()
    elif cmd == "run":
        if a[:1] == ["--shard"]:
            i, n = a[1].split("/")
            run(None, (int(i), int(n)))
        else:
            run(set(a[1:]) if a[:1] == ["--only"] else None)
    elif cmd == "merge":
        merge(a)
    elif cmd == "table":
        table()
