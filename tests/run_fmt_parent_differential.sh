#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
SELFTEST=0
if [ "${1:-}" = "--selftest" ]; then SELFTEST=1; PARENT=; else PARENT=${1:-}; fi
TEMP=
cleanup() { [ -z "$TEMP" ] || rm -rf "$TEMP"; }
trap cleanup EXIT
if [ -z "$PARENT" ]; then
    # A language branch may have syntax absent from its main merge-base.
    # Prefer an explicit reviewed incumbent, then this numeric branch's pin;
    # ordinary branches retain merge-base. Never compare unrelated trees.
    if [ -n "${FMT_PARENT_REF:-}" ]; then
        PARENT_REF=$FMT_PARENT_REF
        PARENT_SOURCE=FMT_PARENT_REF
    elif [ -e "$ROOT/tests/phase2/fmt_parent_ref.txt" ]; then
        PARENT_REF=$(python3 -c 'import re,sys; from pathlib import Path; lines=[line.strip() for line in Path(sys.argv[1]).read_text().splitlines() if line.strip() and not line.lstrip().startswith("#")]; (len(lines)==1 and re.fullmatch(r"[0-9a-f]{40}",lines[0])) or sys.exit("formatter differential: Phase 2 incumbent pin must contain exactly one 40-hex commit"); print(lines[0])' "$ROOT/tests/phase2/fmt_parent_ref.txt") || exit 1
        PARENT_SOURCE=tests/phase2/fmt_parent_ref.txt
    else
        PARENT_REF=$(git -C "$ROOT" merge-base HEAD origin/main 2>/dev/null) || {
            echo "formatter differential: the parent commit is not in this clone; fetch history (cannot merge-base HEAD origin/main)" >&2
            exit 1
        }
        PARENT_SOURCE=merge-base
    fi
    PARENT_REF=$(git -C "$ROOT" rev-parse --verify --end-of-options "$PARENT_REF^{commit}" 2>/dev/null) || {
        echo "formatter differential: incumbent ref is not a commit in this clone" >&2
        exit 1
    }
    git -C "$ROOT" merge-base --is-ancestor "$PARENT_REF" HEAD || {
        echo "formatter differential: incumbent $PARENT_REF is not an ancestor of HEAD" >&2
        exit 1
    }
    echo "formatter differential: incumbent=$PARENT_REF source=$PARENT_SOURCE"
    if [ -n "${FMT_PARENT_BINARY:-}" ]; then
        # Borrow the already-built reviewed oracle in its owning checkout;
        # source identity and cleanliness must agree with the resolved ref.
        PARENT=$(python3 -c 'import os,sys; from pathlib import Path; p=Path(sys.argv[1]).resolve(strict=True); (p.is_file() and os.access(p,os.X_OK)) or sys.exit("formatter differential: cached incumbent is not an executable file"); magic=p.open("rb").read(4); (magic.hex() in ("7f454c46","feedface","feedfacf","cefaedfe","cffaedfe","cafebabe","bebafeca","cafebabf","bfbafeca") or magic[:2]==b"MZ") or sys.exit("formatter differential: cached incumbent must be a native binary"); print(p)' "$FMT_PARENT_BINARY") || exit 1
        PARENT_OWNER=$(git --no-optional-locks -C "$(dirname "$PARENT")" rev-parse --show-toplevel 2>/dev/null) || {
            echo "formatter differential: cached incumbent has no owning Git checkout" >&2
            exit 1
        }
        PARENT_HEAD=$(git --no-optional-locks -C "$PARENT_OWNER" rev-parse --verify 'HEAD^{commit}') || exit 1
        [ "$PARENT_HEAD" = "$PARENT_REF" ] || {
            echo "formatter differential: cached incumbent HEAD $PARENT_HEAD differs from $PARENT_REF" >&2
            exit 1
        }
        PARENT_TRACKED=$(git --no-optional-locks -C "$PARENT_OWNER" status --porcelain --untracked-files=no) || exit 1
        [ -z "$PARENT_TRACKED" ] || {
            echo "formatter differential: cached incumbent has dirty tracked source: $PARENT_OWNER" >&2
            exit 1
        }
        echo "formatter differential: cached incumbent binary=$PARENT root=$PARENT_OWNER"
    else
        TEMP=$(mktemp -d "$(dirname "$ROOT")/.eigs-fmt-parent-XXXXXX")
        git -C "$ROOT" archive "$PARENT_REF" | tar -x -C "$TEMP" || {
            echo "formatter differential: could not obtain incumbent $PARENT_REF" >&2
            exit 1
        }
        # This binary is a formatter oracle, not a performance result.  Avoid the
        # release build's expensive optimisation so the <=60s source-gate row
        # spends its budget comparing output rather than optimizing the VM/JIT.
        # Overriding CFLAGS replaces the Makefile's own, so carry the -Werror trio
        # from the incumbent's tools/werror_flags.txt (CI's cc-guard rejects a
        # compile without it). The incumbent build is serial on the same machine.
        werror=$(cat "$TEMP/tools/werror_flags.txt") && [ -n "$werror" ] || {
            echo "formatter differential: incumbent $PARENT_REF has no tools/werror_flags.txt" >&2
            exit 1
        }
        make -C "$TEMP" \
            CFLAGS="-Wall -Wextra -Werror=implicit-function-declaration $werror -O0 -fPIE" >/dev/null || {
            echo "formatter differential: could not build incumbent $PARENT_REF" >&2
            exit 1
        }
        PARENT="$TEMP/src/eigenscript"
    fi
fi
python3 tests/fmt_parent_differential.py "$PARENT" "$ROOT/src/eigenscript" "$ROOT"

if [ "$SELFTEST" -eq 1 ]; then
    if FMT_DIFFERENTIAL_PLANT_NORMALIZATION=1 FMT_DIFFERENTIAL_PROBE_ONLY=1 \
        python3 tests/fmt_parent_differential.py "$PARENT" "$ROOT/src/eigenscript" "$ROOT" >/dev/null 2>&1; then
        echo "FAIL: formatter differential missed normalization regression" >&2
        exit 1
    fi
    echo "formatter differential selftest: live comparison passed; normalization plant caught"
fi
