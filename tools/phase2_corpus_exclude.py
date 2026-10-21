#!/usr/bin/env python3
"""Apply the corpus's declared directory exclusions to both file inventories."""
from pathlib import Path, PurePosixPath
import re
import sys


def is_owned(path, entries):
    return any(path.startswith(prefix) for prefix, _, _ in entries)


def filter_paths(root, selected):
    """Filter a broad corpus before callers narrow it to their own file shapes."""
    root = Path(root)
    selected = list(selected)
    entries = []
    for number, line in enumerate((root / 'tests/phase2/corpus_exclude.txt').read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split(maxsplit=2)
        if len(fields) != 3 or not fields[2].strip():
            raise ValueError('line %d needs directory, owner and reason' % number)
        prefix, owner, reason = fields
        for value in (prefix, owner):
            if PurePosixPath(value).is_absolute() or '..' in PurePosixPath(value).parts or '.' in value.split('/'):
                raise ValueError('unsafe path ' + value)
        if not re.fullmatch(r'tests/[A-Za-z0-9_./-]+/', prefix):
            raise ValueError('invalid directory ' + prefix)
        if not re.fullmatch(r'(?:tools|tests)/[A-Za-z0-9_./-]+', owner) or not (root / owner).is_file():
            raise ValueError('missing owning harness ' + owner)
        if any(prefix.startswith(old) or old.startswith(prefix) for old, _, _ in entries):
            raise ValueError('duplicate or overlapping directory ' + prefix)
        matches = [p for p in (root / prefix).rglob('*.eigs') if p.is_file()]
        if not matches:
            raise ValueError('stale directory ' + prefix)
        entries.append((prefix, owner, reason))
    kept = [path for path in selected if not is_owned(path, entries)]
    if not kept:
        raise ValueError('zero programs remain after exclusions')
    for prefix, owner, reason in entries:
        size = sum(path.startswith(prefix) for path in selected)
        if not size:
            raise ValueError('stale directory %s excludes ZERO files from the corpus' % prefix)
        print('EXCLUDED %s files=%d owner=%s reason=%s' % (prefix, size, owner, reason))
    return kept, entries


def main():
    if len(sys.argv) not in (3, 5):
        raise ValueError('usage: phase2_corpus_exclude.py ROOT FILES [BASELINE COUNT]')
    root, branch = map(Path, sys.argv[1:3])
    selected = branch.read_text().splitlines()
    kept, entries = filter_paths(root, selected)
    branch.write_text(''.join(path + '\n' for path in kept))
    if len(sys.argv) == 5:
        baseline, count = map(Path, sys.argv[3:])
        base = [p for p in baseline.read_text().splitlines()
                if not is_owned(p, entries)]
        baseline.write_text(''.join(path + '\n' for path in base))
        count.write_text(str(len(selected) - len(kept)) + '\n')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print('EXCLUSION-REFUSED ' + str(error))
        sys.exit(1)
