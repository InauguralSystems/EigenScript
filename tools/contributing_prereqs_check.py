#!/usr/bin/env python3
"""Keep CONTRIBUTING's contributor prerequisites explicit and complete."""

import re
import sys
import tempfile
from pathlib import Path


REQUIREMENTS = {
    "runtime/build distinction": r"minimal runtime build",
    "Bash": r"\bBash\b",
    "C build toolchain": r"\bC build toolchain\b",
    "Make": r"\bMake\b",
    "Python 3": r"\bPython 3\b",
    "PyYAML": r"\bPyYAML\b",
    "Git": r"\bGit\b",
    "standard Unix utilities": r"\bstandard Unix (?:shell and build )?utilities\b|\bstandard Unix shell and build\s+utilities\b",
    "SHA-256 utility": r"`sha256sum` or `shasum`",
    "Git checkout requirement": r"suite must run from a Git checkout",
    "prepared devcontainer link": r"\[[^]]*(?:devcontainer|Codespaces)[^]]*\]\(\.devcontainer/\)",
}


def check(path: Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    match = re.search(r"^## Getting Started\s*$([\s\S]*?)(?=^## )", text,
                      re.MULTILINE)
    if match is None:
        return ["Getting Started section"]
    text = match.group(1)
    return [name for name, pattern in REQUIREMENTS.items()
            if re.search(pattern, text, re.IGNORECASE) is None]


def selftest() -> int:
    source = Path("CONTRIBUTING.md").read_text(encoding="utf-8")
    if check(Path("CONTRIBUTING.md")):
        print("contributing-prereqs selftest: RED: source guide is not a valid fixture")
        return 1
    with tempfile.TemporaryDirectory() as directory:
        fixture = Path(directory) / "CONTRIBUTING.md"
        for name, pattern in REQUIREMENTS.items():
            planted, count = re.subn(pattern, "REMOVED", source,
                                     flags=re.IGNORECASE)
            if count < 1:
                print(f"contributing-prereqs selftest: RED: could not plant {name}")
                return 1
            fixture.write_text(planted, encoding="utf-8")
            if name not in check(fixture):
                print(f"contributing-prereqs selftest: RED: missed {name}")
                return 1
    print(f"contributing-prereqs selftest: GREEN: {len(REQUIREMENTS)} planted omissions caught")
    return 0


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        return selftest()
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("CONTRIBUTING.md")
    missing = check(path)
    if missing:
        for item in missing:
            print(f"contributing-prereqs: RED: missing {item}")
        return 1
    print(f"contributing-prereqs: GREEN: {len(REQUIREMENTS)} requirements documented")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
