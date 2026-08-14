#!/usr/bin/env python3
"""#915 drift gate: every opcode that READS observer state must be listed in
chunk_reads_observer().

chunk_reads_observer (src/chunk.c) decides whether a program is allowed to skip
observer bookkeeping. If an opcode reads observer state and is NOT in its list,
a program using only that opcode gates itself off and the opcode then reads a
slot nobody ever updated — it returns "equilibrium" for everything, forever,
with no crash and no failing assert. That is the worst failure shape available
here, and it is invisible to the test suite unless a test happens to cover that
exact opcode.

So the list must not be hand-maintained against nothing. This checks it against
the authoritative source: the VM's own dispatch bodies. An opcode whose CASE
block calls any observer-READ function must appear in the list.

The check runs in one direction on purpose. vm.c reader missing from chunk.c is
a HARD FAILURE (silent-wrong). chunk.c listing an opcode vm.c does not read is
merely conservative — that program observes when it need not, costing speed and
nothing else — so it is reported, not failed.

Validate this checker with a planted fault before trusting it: delete an opcode
from chunk_reads_observer's list and confirm this script fails.
"""
import re
import sys
import pathlib

REPO = pathlib.Path(__file__).resolve().parent.parent

# Functions that READ observer state to produce a value. Deliberately excludes
# observer_slot_update / observer_slot_update_num / observer_slot_record_value,
# which WRITE — an opcode that only writes does not force observation, since
# with the gate closed there is nothing to write for.
# Touching a slot AT ALL is the real signal. obs_stall_trajectory (vm.c) reads
# observer state by direct struct access — env_obs_slot(...) then s->dH,
# s->entropy — and calls no named reader, so a checker keyed on reader FUNCTIONS
# never reached it. That was this gate's own blind spot: OP_LOOP_STALL_CHECK, the
# opcode this file's docstring cites as the reason the callee closure exists,
# was being reported as "listed but not reading".
#
# env_obs_slot cannot simply be a reader, because writers call it too and listing
# a writer would force observation on at every assignment — i.e. delete the gate.
# So slot-touching opcodes that only WRITE are waived BY NAME below, and every
# other slot-toucher must appear in chunk_reads_observer. A new opcode that
# touches a slot now has to be classified deliberately instead of defaulting to
# invisible.
SLOT_TOUCH = "env_obs_slot"

WRITE_ONLY_WAIVERS = {
    # Each of these calls env_obs_slot solely to UPDATE the slot from the value
    # just assigned. With the gate closed there is nothing to write, so they do
    # not force observation on.
    "OP_OBSERVE_ASSIGN":       "writes the slot from the assigned value",
    "OP_OBSERVE_ASSIGN_LOCAL": "writes the slot from the assigned local",
    "OP_OBSERVE_NAME_POST":    "#262 re-observe AFTER SET; write-only",
    "OP_LOCAL_DOT_SET":        "writes the slot after a dot-assignment",
}

READERS = [
    "observer_slot_report",          # covers _entropy / _value by prefix
    "observer_slot_oscillating",
    "observer_slot_converged",
    "observer_slot_diverging",
    "observer_slot_improving",
    "observer_slot_stable",
    "observer_slot_equilibrium",
    "observer_slot_from_trajectory",
    "vm_slot_query_view",
]


def function_bodies(src: str):
    """Yield (name, body) for each top-level function definition in a .c file."""
    for m in re.finditer(r"^[A-Za-z_][\w \t*]*?\b(\w+)\s*\([^;{]*\)\s*\{", src, re.M):
        name = m.group(1)
        i = src.index("{", m.start())
        depth = 0
        for j in range(i, len(src)):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    yield name, src[i:j]
                    break


def expand_readers(sources: dict, base: list) -> set:
    """Transitive closure of 'reads observer state' over function calls.

    A CASE body rarely calls a slot reader directly. OP_LOOP_STALL_CHECK, for
    instance, reaches the observer through obs_stall_trajectory() — a flat scan
    of the dispatch body sees nothing and the opcode looks clean. Missing a
    reader here produces a FALSE PASS, which is worse than no gate at all, so
    the reader set has to be closed over callees rather than assumed shallow.
    """
    readers = set(base)
    # Closure stoppers. Without these the closure blows up: OP_IMPORT calls
    # compile_ast + vm_execute, and vm_execute reaches every opcode including
    # the readers, so ALL of them would be marked. These are the boundaries
    # where the gate is handled by a different mechanism and the opcode list is
    # not the right place to express it:
    #   compile_ast   — ORs chunk_reads_observer in for the nested unit itself
    #   vm_execute /  — VM re-entry; the nested chunk was scanned on its own
    #   vm_run_ex        way in, so attributing its reads to the calling opcode
    #                    says only "this opcode can run other code"
    #   eigs_observe_safepoint — reads ONLY on a pending SIGUSR1 (the #660
    #                    observer dump) and is called from every loop check, so
    #                    including it marks every looping program. Tracked
    #                    separately: a gated program's SIGUSR1 dump must SAY it
    #                    is gated rather than print empty state.
    STOP = {"compile_ast", "vm_execute", "vm_run_ex", "vm_run",
            "eigs_observe_safepoint"}
    bodies = {}
    for src in sources.values():
        for name, body in function_bodies(src):
            bodies.setdefault(name, "")
            bodies[name] += body
    changed = True
    while changed:
        changed = False
        for name, body in bodies.items():
            if name in readers or name in STOP:
                continue
            if any(re.search(r"\b%s\s*\(" % re.escape(r), body) for r in readers):
                readers.add(name)
                changed = True
    return readers


def case_blocks(src: str):
    """Yield (opcode, body) for each CASE(OP) dispatch block in vm.c.

    Brace-depth tracked rather than regex-to-next-DISPATCH: several bodies
    contain nested blocks and an early DISPATCH(), so a naive range bleeds into
    the following opcode and attributes its reads to the wrong one.
    """
    for m in re.finditer(r"\bCASE\((\w+)\)\s*:?\s*\{", src):
        op = m.group(1)
        i = src.index("{", m.start())
        depth = 0
        for j in range(i, len(src)):
            if src[j] == "{":
                depth += 1
            elif src[j] == "}":
                depth -= 1
                if depth == 0:
                    yield op, src[i:j]
                    break


def main() -> int:
    vm = (REPO / "src" / "vm.c").read_text()
    chunk = (REPO / "src" / "chunk.c").read_text()
    eigs = (REPO / "src" / "eigenscript.c").read_text()

    # Close the reader set over callees first — see expand_readers().
    # SLOT_TOUCH seeds the closure too, so a helper that reads a slot by direct
    # struct access (obs_stall_trajectory) marks every opcode that calls it.
    # Write-only opcodes are exempted afterwards, by name, below.
    readers = expand_readers({"vm.c": vm, "eigenscript.c": eigs},
                             READERS + [SLOT_TOUCH])

    # The authoritative set: opcodes whose dispatch body reaches a reader.
    vm_readers = set()
    for op, body in case_blocks(vm):
        hit = any(re.search(r"\b%s\s*\(" % re.escape(r), body) for r in readers)
        if hit and ("OP_" + op) in WRITE_ONLY_WAIVERS:
            hit = False          # declared write-only; see WRITE_ONLY_WAIVERS
        if hit:
            vm_readers.add("OP_" + op)

    # The list under test.
    m = re.search(r"int chunk_reads_observer\(.*?\n\}", chunk, re.S)
    if not m:
        print("FAIL: could not find chunk_reads_observer() in src/chunk.c")
        return 2
    listed = set(re.findall(r"case (OP_\w+):", m.group(0)))

    if not vm_readers:
        print("FAIL: found no observer-reading opcodes in vm.c — the extractor "
              "is broken (or READERS drifted), not the tree")
        return 2

    missing = sorted(vm_readers - listed)
    extra = sorted(listed - vm_readers)

    print(f"observer-reading opcodes in vm.c: {len(vm_readers)}")
    print(f"listed in chunk_reads_observer:   {len(listed)}")

    for op in extra:
        print(f"  note (conservative, not a failure): {op} is listed but vm.c's "
              f"dispatch body does not read observer state")

    if missing:
        print()
        for op in missing:
            print(f"  MISSING: {op} reads observer state in vm.c but is not "
                  f"listed in chunk_reads_observer")
        print()
        print("RESULT: FAIL — a program using only the missing opcode(s) would "
              "gate itself off and then read observer state nobody updated.")
        return 1

    print("RESULT: PASS — every observer-reading opcode is accounted for")
    return 0


if __name__ == "__main__":
    sys.exit(main())
