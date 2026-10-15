#!/usr/bin/env bash
# tools/phase2_check.sh [--through Rk] [--baseline BIN] [--smi-trap BIN] [--calibrate] <tag-binary> <branch-binary>
# #1758 Phase 2's row checker (docs/design/phase2-numbers.md 9.2): the MAP's
# landed rows on the v0.46.0 tag and the branch in four tiers, their tier
# witnesses, and a mechanical round's gates. The work is in
# tools/phase2_check.py, whose docstring is the reference.
# -W error: a Python warning (a DeprecationWarning on a newer Python, an
# unclosed file) is a FAIL here, never a line inside a parsed output (the
# R1.1 critic: Python 3.13's warning was read as two classifiers).
command -v python3 >/dev/null 2>&1 || { echo "phase2-check: FAIL: python3 is required"; exit 2; }
exec python3 -W error "$(dirname "$0")/phase2_check.py" "$@"
