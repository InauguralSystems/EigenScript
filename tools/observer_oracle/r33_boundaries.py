#!/usr/bin/env python3
"""Purpose-built F0 identity windows, separate from the fixed512+4 roster.

These inputs have no oracle accuracy labels and choose no experimental arm.
The writer emits only inputs. A manifest commit must precede any binary read.
"""
import json
import math
from pathlib import Path
import sys

import r33_fixtures as F


def fixtures():
    cases = []
    def add(name, values, purpose, window=10):
        cases.append({'id': 'boundary-' + name, 'values': [F.typed(v) for v in values],
                      'checkpoints': list(range(len(values))), 'window': window,
                      'purpose': purpose, 'policy': 'F0'})
    add('s4-slow-drift', [1000.0 - 0.5*n for n in range(21)], 'S4 tau=0 vetoes a real D2 improvement')
    add('s4-fast-drift', [1000.0 - 2.0*n for n in range(21)], 'S4 tau x10 suppresses the reference-diverging veto')
    add('s4-first-reference', [1000.0 - 0.995*n for n in range(11)], 'S4 last-reference versus first-reference')
    add('s4-small-slow', [1e-4 - 5e-7*n for n in range(21)], 'S4 absolute floor versus no floor')
    add('s4-small-fast', [1e-4 - 2e-6*n for n in range(21)], 'S4 floor x10 versus F0 floor')
    for name, ratio in (('ratio-equality', 1.0-1e-9), ('ratio-slack', 1.0-1e-7)):
        values=[10.0]
        step=-1.0
        for _ in range(10):
            values.append(values[-1]+step)
            step*=ratio
        add('s4-'+name, values, 'S4 geometric step-ratio at/inside its registered1e-9 slack')
    values=[5e-6]
    tau=0.001*0.001
    for _ in range(10):
        value=values[-1]-tau
        while values[-1]-value < tau:
            value=math.nextafter(value,-math.inf)
        values.append(value)
    add('s4-negative-tau-equality', values, 'S4 negative step exactly at tau among strictly larger steps')
    add('d2-exact-int', [9223372036854775807, 9214148664817921023],
        'D2 exact integer/float strict comparison, source test_trajectory best_boundary')
    add('d2-equality', [1000.0, 999.0], 'D2 value equals significant-improvement threshold')
    add('d2-int-equality', [1000, 999], 'S2 exact current int equals significant-improvement threshold')
    add('since-saturation', [1.0,0.0]+[0.0]*260, 'D2 uint8 age saturates instead of wrapping into improving')
    add('n1-last-reference', [0.0, 1.0, 2.0, 3.0, 1e16], 'N1 last value versus previous value in noise floor')
    for ulps in (6,12):
        add(f'n1-{ulps}-ulps', [1.0+ulps*n*sys.float_info.epsilon for n in range(5)],
            'N1 additive1 and4eps multiplier have distinct partial raw thresholds')
    add('reference-expanding', [-1.,1.,-2.,2.,-4.,4.,-8.,8.,-16.,16.,-32.],
        'Expanding alternating magnitudes veto a recent D2 improvement')
    add('partial-raw-four', [float(i) for i in range(5)], 'Exactly four raw steps, no seeded prefix')
    add('partial-raw-negative-four', [-float(i) for i in range(5)], 'Four negative raw steps')
    add('partial-raw-flips', [1.0, -1.0, 1.0, -1.0, 1.0], 'Four raw steps and oscillation threshold')
    add('raw-flips-four', [1.+(1e-12 if i%2 else -1e-12) for i in range(6)],
        'Exactly four raw reversals while every relative step lies below the zero threshold')
    f=8*sys.float_info.epsilon
    add('raw-older-floor-equality',[1-6*f,1-5*f,1-4*f,1-2*f,1.],
        'Older raw mean exactly equals N1 floor while recent mean is larger')
    f=4*sys.float_info.epsilon
    a=f*(1+5e-10)
    add('raw-recent-floor-equality',[-2*a-2*f,-a-2*f,-2*f,-f,0.],
        'Recent raw mean equals N1 floor; older mean differs within the nonvanishing slack')
    add('s6-last-reference',[1000.]+[1000.5]*9+[1001.0005],
        'S6 diameter lies between first-reference and last-reference tolerances')
    add('raw-half-partition',[0.,1.,101.,201.,202.], 'Raw older/recent halves versus a quarter-window partition')
    add('nan-first-oscillation',[math.nan]+[1.,-1.]*5, 'Finite last value after an old NaN can still oscillate')
    add('reference-half-partition',[-1.,1.,-10.,10.,-1.,1.,-2.,2.,-3.,3.,-4.],
        'Reference expansion halves versus a quarter-window partition')
    f=4*sys.float_info.epsilon
    for name,raw in (('raw-osc-floor-equality',[100*f,-100*f,f,-100*f,100*f,-100*f]),
                     ('raw-osc-floor-complement',[f/2,-10*f]*5),
                     ('bounded-floor-equality',[1.,1.,1.,1.,-1.,-1.,f,-1.,-1.,0.])):
        values=[-sum(raw)]
        for step in raw:values.append(values[-1]+step)
        add(name,values,'N1 per-step floor gates a reversal at its exact raw equality or complement')
    add('raw-positive-tiny-five',[1.+12*n*sys.float_info.epsilon for n in range(6)],
        'Positive raw products below1 are not sign reversals; five steps reach the flip threshold')
    add('one-direction-two', [1.]*9+[1.000001,1.000002], 'Full window has exactly two nonzero same-sign steps')
    for name,raw in (('bounded-two-reversals',[1.,1.,1.,-1.,-1.,-1.,-1.,1.,1.,1.]),
                     ('bounded-net-equality',[1.,1.,1.25]+[-.875]*4+[1.,1.,1.25])):
        values=[0.]
        for step in raw:values.append(values[-1]+step)
        add(name,values,'Bounded-oscillation reversal count/net-to-path equality, with other oscillation routes below threshold')
    add('reference-crossings-two',[-1.,-.5,0.,.5,1.,.5,0.,-.5,-1.,-1.5,-2.],
        'Reference expansion exactly two mean crossings and a recent D2 best')
    z = 0.001 * 0.001
    b = 0.01 * 0.001
    add('s6-equality', [z] + [0.0]*10, 'S6 float diameter exactly equals F0 tolerance')
    add('s8-equality', [-b] + [b]*9 + [0.0], 'S8 half-diameter exactly equals F0 tolerance')
    add('s5-int-constant', [0]*11, 'S5 exact integer zero diameter')
    add('s7-int-moving', [2**53+i for i in range(11)], 'S7 exact diameter and magnitude-independent tolerance')
    add('flags-small-equality', [0.0, b], 'Partial report all-small flag at its equality boundary')
    add('flags-zero-equality', [0.0,z,0.0,z,0.0,z/2,0.0,z/2,0.0,z/2,0.0],
        'All-zero flag equality with shrinking raw oscillation and zero net path')
    # Named finite local grids are arithmetic boundary inputs, not draws from
    # any process-family generator. Every point is fixed before binary use.
    for exponent in (-20, -10, 0, 10):
        unit = math.ldexp(1.0, exponent)
        for sign in (-1.0, 1.0):
            add(f'ratio-{exponent}-{int(sign)}', [sign*unit*i for i in range(11)],
                'Reference-diverging ratio exactly1; finite arithmetic scaling')
    for k, relative in ((1, 0.001125),):
        for offset in (-13,-12,-11,0,1):
            x = 0.0
            values = [x]
            for _ in range(9):
                x += relative * 0.001
                values.append(x)
            last = (0.01 - 9*relative) * 0.001
            for _ in range(abs(offset)):
                last = math.nextafter(last, math.inf if offset > 0 else -math.inf)
            values.append(x + last)
            add(f'eq-mean-{k}-{offset+12}', values, 'Equilibrium mean/variance neighborhood, mixed-sign steps')
    for offset in (-1,0,1):
        step = z
        for _ in range(abs(offset)):
            step = math.nextafter(step, math.inf if offset > 0 else -math.inf)
        values = [0.0]
        for d in [step]*5 + [-step]*5:
            values.append(values[-1] + d)
        add(f'eq-variance-{offset+16}', values, 'Equilibrium variance equality neighborhood with one reversal')
    # Dyadic values make the reference tau exactly representable (.001*1000).
    for initial in (1000.0, 1.0, 0.0):
        for direction in (-1.0, 1.0):
            for delta in (0.001,1e-6,1.0):
                add(f'tau-{initial.hex()}-{int(direction)}-{delta.hex()}',
                    [initial + direction*delta*n for n in range(11)], 'Raw-step/reference-tau equality neighborhood')
    return cases + supplemental_fixtures()


def write(destination):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    rows = fixtures()
    if len({r['id'] for r in rows}) != len(rows):
        raise RuntimeError('duplicate purpose fixture id')
    path = destination / 'cases.jsonl'
    path.write_text(''.join(json.dumps(r, sort_keys=True)+'\n' for r in rows))
    programs = destination / 'programs'
    programs.mkdir(exist_ok=True)
    for row in rows:
        if row['window'] != 10:
            raise RuntimeError('numeric fixture emitter keeps the fixed subject default window10')
        (programs / (row['id']+'.eigs')).write_text(F.emit(row))
    print(f'F0 purpose inputs: {len(rows)} windows, {sum(len(r["values"]) for r in rows)} observations; no binary run')


def supplemental_fixtures():
    """Source-derived gaps found after the first purpose-fixture binary read.

    These get their own pre-read commit; they do not rewrite the74-input seal.
    """
    definitions=(
        ('initial-nonfinite-best',[math.inf]+[1000.-0.5*n for n in range(21)],
         'Initial nonfinite value must not initialize D2 best'),
        ('nonfinite-best-poison',[1000.,-math.inf]+[1000.-0.5*n for n in range(21)],
         'A later negative infinity must not replace a finite D2 best'),
        ('integer-subtraction-endpoints',[0,-2**63,0,2**63-1],
         'Exact int subtraction includes both INT64_MIN and INT64_MAX endpoints'),
        ('oscillation-last-nan',[1.,-1.]*5+[math.nan],
         'Last-value NaN routing suppresses retained relative reversals'),
        ('tiny-full-oscillation',[1.+(1e-12 if i%2 else -1e-12) for i in range(11)],
         'Raw oscillation veto of equilibrium is queried directly at a full window'),
        ('damped-small-relative',[1.+((-1.)**i)*1e-6*(.9**i) for i in range(11)],
         'All relative steps are in the zero bucket while raw oscillation decays'),
        ('typed-integer-constant',[5]*11,
         'Exact integer constant at nonzero magnitude constrains minimum/diameter references'))
    return [{'id':'boundary-supplemental-'+name,'values':[F.typed(v) for v in values],
             'checkpoints':list(range(len(values))),'window':10,'purpose':purpose,'policy':'F0'}
            for name,values,purpose in definitions]


def write_supplemental(destination):
    destination=Path(destination)
    destination.mkdir(parents=True,exist_ok=True)
    rows=supplemental_fixtures()
    (destination/'supplemental-cases.jsonl').write_text(''.join(json.dumps(r,sort_keys=True)+'\n' for r in rows))
    programs=destination/'supplemental-programs'
    programs.mkdir(exist_ok=True)
    for row in rows:
        (programs/(row['id']+'.eigs')).write_text(F.emit(row))
    print(f'SUPPLEMENTAL F0 inputs: {len(rows)} windows, {sum(len(r["values"]) for r in rows)} observations; no binary run')


if __name__ == '__main__':
    if len(sys.argv)==3 and sys.argv[1]=='--supplemental':
        write_supplemental(sys.argv[2])
    elif len(sys.argv)==2:
        write(sys.argv[1])
    else:
        raise SystemExit('usage: r33_boundaries.py [--supplemental] DESTINATION')
