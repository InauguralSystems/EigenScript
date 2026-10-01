#!/usr/bin/env python3
"""Keep docs/SPEC.md the sole language authority (#1271)."""
from pathlib import Path
import re, subprocess, sys, tempfile, shutil
ROOT = Path(__file__).resolve().parents[1]
TERMS = re.compile(r"\b(must|must not|always|never|requires?|raises?|returns?|is undefined|is a parse error)\b", re.I)
REMOVED = ("LANGUAGE" + "_CONTRACT.md", "GRAM" + "MAR.md")

def normalized_lines(path):
    out = {}
    for no, raw in enumerate(path.read_text(errors="replace").splitlines(), 1):
        text = re.sub(r"[`*_]", "", raw.strip())
        text = re.sub(r"\s+", " ", text)
        if len(text) >= 45 and TERMS.search(text) and not text.startswith(("#", "|")):
            out.setdefault(text.casefold(), []).append(no)
    return out

def check(root, planted=False):
    errors=[]
    spec=root/'docs/SPEC.md'
    identities=normalized_lines(spec)
    for doc in sorted((root/'docs').glob('*.md')):
        if doc.name in {'SPEC.md', 'SPEC_CONSOLIDATION_MAP.md'}:
            continue
        for text, lines in normalized_lines(doc).items():
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
    candidates=normalized_lines(ROOT/'docs/SPEC.md')
    chosen=next((line for line in candidates if all(line not in normalized_lines(p) for p in (ROOT/'docs').glob('*.md') if p.name not in {'SPEC.md','SPEC_CONSOLIDATION_MAP.md'})), None)
    if not chosen: return ['self-test could not find a unique normative identity']
    with tempfile.TemporaryDirectory(prefix='spec-authority-') as td:
        root=Path(td); (root/'docs').mkdir()
        shutil.copy(ROOT/'docs/SPEC.md', root/'docs/SPEC.md')
        (root/'docs/SYNTAX.md').write_text('# planted duplicate\n\n'+chosen+'\n')
        planted=check(root, planted=True)
        if not any('duplicated normative rule' in e for e in planted):
            return ['self-test planted a copied rule but the gate stayed green']
    return []

errors = selftest() if '--self-test' in sys.argv else check(ROOT)
if errors:
    print('spec-authority: FAIL')
    for e in errors: print('  '+e)
    raise SystemExit(1)
print('spec-authority: PASS (sole authority, removed paths, duplicate-rule scan)')
