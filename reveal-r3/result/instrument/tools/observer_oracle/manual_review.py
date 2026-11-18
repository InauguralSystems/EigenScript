#!/usr/bin/env python3
"""Blind-review gate for families.py manual arguments (#2330).

manual_review.json is the reviewer's record. SHA256 pins the UTF-8 canonical
argument, and family/cite keys are matched exactly. F6's generated P is the
sole parameter placeholder: a finite decimal > 2 becomes {P}. F15 appends
one exact positive scaling suffix; its origin family is retained in the key.
F15b arguments are unchanged copies of their named origin. No verdict is
supplied by this helper or its inventory writer.
"""
import hashlib
import json
import math
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT = HERE / 'manual_review.json'


def review_key(row):
    """Return (family key, cite tuple, canonical argument), refusing unknown shapes."""
    man = row.get('manual', {})
    arg = man.get('argument', '')
    family = row.get('family', '')
    match = re.fullmatch(r'F(6|8|9|10) .+', family)
    base = re.fullmatch(r'F15b base for unit-scaled copies, from F(8|9|10) .+', family)
    if match:
        origin, prefix = match[1], ''
    elif base:
        origin, prefix = base[1], 'F15b/'
    elif family == 'F15 unit-scaled copies':
        origin, prefix = None, 'F15/'
    else:
        raise ValueError(f"{row.get('id')}: unrecognized manual family {family!r}")
    if prefix == 'F15/':
        scale = row.get('scale')
        if scale not in (0.001, 1000):
            raise ValueError(f"{row.get('id')}: unregistered F15 manual scale {scale!r}")
        suffix = f'; the row is the base row times {scale:g} > 0'
        if arg.endswith(suffix):
            core = arg[:-len(suffix)]
            if core.startswith('theta = 2 pi / P with P = '):
                origin = '6'
            elif core.startswith('an iid sequence '):
                origin = '8'
            elif core.startswith('|x_n - mu|'):
                origin = '9'
            elif core.startswith('a mean-zero walk '):
                origin = '10'
            else:
                raise ValueError(f"{row.get('id')}: unknown F15 manual origin")
        elif arg.startswith(f'x_n = {scale:g} sum_(k=1)^(n+1) k^-p with p > 1: '):
            origin = '2'
        else:
            raise ValueError(f"{row.get('id')}: missing F15 manual scaling argument")
        prefix += f'F{origin}/x{scale:g}'
    else:
        prefix += f'F{origin}'
    if origin == '6':
        found = re.search(r'(?<=P = )([^ ]+)(?= > 2)', arg)
        if found is None:
            raise ValueError(f"{row.get('id')}: no F6 period")
        try:
            period = float(found[0])
        except ValueError as exc:
            raise ValueError(f"{row.get('id')}: invalid F6 period") from exc
        if not math.isfinite(period) or period <= 2:
            raise ValueError(f"{row.get('id')}: F6 period must be finite and > 2")
        arg = arg[:found.start()] + '{P}' + arg[found.end():]
    claims = man.get('claims')
    want = {'limit': None, 'tends_to': None, 'bounded': origin != '10'}
    if origin == '2':
        # F2's finite limit is parameter-dependent; certify.py proves the base.
        want = {'limit': row.get('props', {}).get('limit'), 'tends_to': None, 'bounded': True}
        if not isinstance(want['limit'], (int, float)) or not math.isfinite(want['limit']):
            raise ValueError(f"{row.get('id')}: F2 manual finite limit missing")
    if claims != want:
        raise ValueError(f"{row.get('id')}: manual claims differ from reviewed family claims")
    return prefix, tuple(man.get('cite', ())), arg


def check_manual_reviews(corpus, record=None):
    """Return reviewed row ids, or ValueError naming the first refused row.

    Passing an in-memory record supports hermetic selftest fixtures. Production
    calls load the tracked record; callers cannot supply an approval CLI path.
    """
    if record is None:
        record = json.loads(DEFAULT.read_text())
    frozen = hashlib.sha256((HERE / 'families.py').read_bytes()).hexdigest()
    if record.get('families_sha256') != frozen:
        raise ValueError('manual review: families.py differs from reviewed generator')
    entries = record.get('templates', [])
    if not entries:
        raise ValueError('manual review: template table is empty')
    keys = [(e['family'], tuple(e['cite']), e['argument']) for e in entries]
    if len(set(keys)) != len(keys):
        raise ValueError('manual review: duplicate template')
    index = dict(zip(keys, entries))
    reviewed = []
    for row in corpus['rows']:
        if 'manual' not in row:
            continue
        key = review_key(row)
        entry = index.get(key)
        if entry is None or entry.get('sha256') != hashlib.sha256(key[2].encode()).hexdigest():
            raise ValueError(f"{row['id']}: manual argument is not a recorded template")
        if entry.get('verdict') != 'APPROVED' or not entry.get('reviewer') or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', entry.get('date', '')):
            raise ValueError(f"{row['id']}: manual argument lacks recorded blind APPROVED verdict, reviewer and date ({key[0]})")
        reviewed.append(row['id'])
    return reviewed
