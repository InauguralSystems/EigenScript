#!/usr/bin/env python3
"""H1's seal (#1758 pre-registration, "Sealing H1"; RULING R30-4 item 8).

usage: seal.py --round-after UTC_TIME   the drand round H1 uses: the first mainnet round published
                                        after UTC_TIME (ISO 8601, e.g. 2026-12-01T12:00:00Z)
       seal.py ROUND --out DIR          the reveal: fetch the round, derive S_H, write H1 to DIR/corpus.json
       seal.py --smoke                  one call to /public/latest: the endpoint's shape

The procedure. No secret seed exists anywhere: S_H is public randomness that
did not exist when the subject was fixed.
1. The builder posts R3.3's final SHA on #1758. The comment's createdAt is UTC_TIME.
2. `seal.py --round-after UTC_TIME` names the round: the first round of the drand
   mainnet default chain (genesis 1595431050, period 30 s) whose time is after UTC_TIME.
3. Once that round is published, `seal.py ROUND --out DIR` fetches
   https://api.drand.sh/public/ROUND, checks that the response names that round, that
   `randomness` is 64 hex digits and equals sha256(signature) (drand's definition of
   the randomness), and sets S_H = int(randomness, 16). families.py then writes H1
   (families.H1, every one seeded by S_H) into DIR.
4. H1 is labelled by certify.py and derive.py there (its manual blocks reviewed
   blind), and the labels' sha256 is posted beside the round number.
Anyone can repeat steps 2-3 and must get the byte-identical DIR/corpus.json.
"""
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))     # python3 -I drops the script's directory
import families

API = "https://api.drand.sh/public/"
GENESIS, PERIOD = 1595431050, 30        # drand mainnet default chain (chain hash 8990e7a9...)


def fetch(what):
    with urllib.request.urlopen(API + what, timeout=30) as r:
        return json.load(r)


def checked(beacon, want=None):
    rnd, rand, sig = beacon.get("round"), beacon.get("randomness", ""), beacon.get("signature", "")
    if not isinstance(rnd, int) or (want is not None and rnd != want):
        sys.exit(f"seal: the response names round {rnd!r}, not {want}")
    if not re.fullmatch(r"[0-9a-f]{64}", rand):
        sys.exit(f"seal: randomness {rand!r} is not 64 hex digits")
    if hashlib.sha256(bytes.fromhex(sig)).hexdigest() != rand:
        sys.exit("seal: randomness != sha256(signature)")
    return rnd, rand


def round_after(t):
    return (int(t.timestamp()) - GENESIS) // PERIOD + 2     # round r is published at GENESIS + (r - 1) * PERIOD


if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["--smoke"]:
        rnd, rand = checked(fetch("latest"))
        now = datetime.datetime.now(datetime.timezone.utc)
        print(f"drand latest: round {rnd}, randomness {rand}; round_after(now) = {round_after(now)}"
              f" (the latest round is {round_after(now) - 1} by the clock)")
    elif len(a) == 2 and a[0] == "--round-after":
        print(round_after(datetime.datetime.fromisoformat(a[1].replace("Z", "+00:00"))))
    elif len(a) == 3 and a[1] == "--out":
        rnd, rand = checked(fetch(a[0]), int(a[0]))
        s_h = int(rand, 16)
        families.write(families.build(families.H1, s_h), a[2])
        print(f"round {rnd}: randomness {rand}; S_H = {s_h}; H1 = {families.H1} written to {a[2]}/corpus.json")
    else:
        sys.exit(__doc__)
