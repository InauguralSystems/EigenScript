#!/usr/bin/env python3
"""Keep docs/SPEC.md the sole language authority (#1271)."""
from pathlib import Path
import re, subprocess, sys, tempfile, shutil
ROOT = Path(__file__).resolve().parents[1]
REMOVED = ("LANGUAGE" + "_CONTRACT.md", "GRAM" + "MAR.md")

def normalized_statements(path):
    """Return substantive Markdown statements, including short rules and tables."""
    out = {}
    fenced = False
    for no, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        stripped = raw.strip()
        if stripped.startswith("```"):
            fenced = not fenced
            continue
        if fenced or not stripped or stripped.startswith("#"):
            continue
        text = re.sub(r"[`*_]", "", stripped)
        # Table layout is not part of a rule's identity, but every cell is.
        text = " | ".join(cell.strip() for cell in text.strip("|").split("|"))
        text = re.sub(r"\s+", " ", text)
        if len(text) >= 12 and not re.fullmatch(r"[-: |]+", text):
            out.setdefault(text.casefold(), []).append(no)
    return out

def check(root, planted=False):
    errors=[]
    spec=root/'docs/SPEC.md'
    identities=normalized_statements(spec)
    for doc in sorted((root/'docs').glob('*.md')):
        if doc.name in {'SPEC.md', 'SPEC_CONSOLIDATION_MAP.md'}:
            continue
        for text, lines in normalized_statements(doc).items():
            if text in identities:
                errors.append(f"duplicated normative rule: {doc.relative_to(root)}:{lines[0]} matches SPEC.md:{identities[text][0]}")
    if not planted:
        for old in REMOVED:
            if (root/'docs'/old).exists(): errors.append(f"removed authority still exists: docs/{old}")
        proc=subprocess.run(['git','grep','-n','-E','LANGUAGE_CONTRACT\\.md|GRAMMAR\\.md','--',':!CHANGELOG.md',':!changes/**',':!tools/spec_authority_check.py'], cwd=root, text=True, capture_output=True)
        if proc.returncode == 0: errors.append('live reference to removed authority:\n'+proc.stdout.rstrip())
        elif proc.returncode != 1: errors.append('git grep failed: '+proc.stderr.rstrip())
    return errors

def selftest():
    errs=check(ROOT)
    if errs:
        return errs
    candidates=normalized_statements(ROOT/'docs/SPEC.md')
    other_docs = [p for p in (ROOT/'docs').glob('*.md') if p.name not in {'SPEC.md','SPEC_CONSOLIDATION_MAP.md'}]
    chosen=next((line for line in candidates if all(line not in normalized_statements(p) for p in other_docs)), None)
    if not chosen: return ['self-test could not find a unique statement identity']
    with tempfile.TemporaryDirectory(prefix='spec-authority-') as td:
        root=Path(td); (root/'docs').mkdir()
        shutil.copy(ROOT/'docs/SPEC.md', root/'docs/SPEC.md')
        probes = [chosen, 'Functions, builtins: by identity.', '| Rule | Calls use identity |']
        for probe in probes:
            (root/'docs/SYNTAX.md').write_text('# planted duplicate\n\n'+probe+'\n')
            # Add the short/table probes to the temporary authority as well.
            with (root/'docs/SPEC.md').open('a') as authority:
                authority.write('\n'+probe+'\n')
            planted=check(root, planted=True)
            if not any('duplicated normative rule' in e for e in planted):
                return [f'self-test planted an undetected duplicate: {probe}']
    return []

errors = selftest() if '--self-test' in sys.argv else check(ROOT)
if errors:
    print('spec-authority: FAIL')
    for e in errors: print('  '+e)
    raise SystemExit(1)
print('spec-authority: PASS (sole authority, removed paths, duplicate-rule scan)')
