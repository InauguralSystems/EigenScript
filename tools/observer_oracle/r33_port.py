#!/usr/bin/env python3
"""R33-1 value-route instrument, anchored to runtime source 54008422.

This module never loads a population or selects an experimental policy by
measurement. F0 follows src/eigenscript.c's numeric fold and classifiers;
the other ten policies differ only at S1--S4/S6/S8/N1 and their ruled step
readers. Exact settled tolerances and the exact N1 branch stay unchanged.
Python's native int/float comparison supplies the runtime's exact mixed
comparison; all arithmetic on the numeric shadows is binary64.
"""

import copy
import math
import sys
from dataclasses import dataclass

SUBJECT = "54008422b7bb4950131f4dd4d15ead942a2ecb2e"
PREDS = ("converged", "stable", "improving", "oscillating", "diverging", "equilibrium")
FRACTIONS = ("1e-2", "1e-3", "1e-4", "1e-6")
POLICIES = ("F0", "STD-rel") + tuple(
    f"C_{f}^{mode}" for mode in ("win", "hist") for f in FRACTIONS
) + ("PRE1045",)
INT_MIN, INT_MAX = -(2**63), 2**63 - 1


def fmax(a, b):
    """obs_fmax, including its operand order for NaNs and signed zeros."""
    if math.isnan(a):
        return b
    if math.isnan(b):
        return a
    return a if a > b else b


def divide(a, b):
    """C binary64 division, including signed zero and invalid operations."""
    if b != 0.0:
        return a / b
    if a == 0.0 or math.isnan(a):
        return math.nan
    negative = math.copysign(1.0, a) != math.copysign(1.0, b)
    return -math.inf if negative else math.inf


def logarithm(v):
    if v == 0.0:
        return -math.inf
    if v < 0.0:
        return math.nan
    return math.log(v)


def exponential(v):
    try:
        return math.exp(v)
    except OverflowError:
        return math.inf


def is_int(v):
    return type(v) is int


def kind(v):
    return None if v is None else "int" if is_int(v) else "float"


@dataclass(frozen=True)
class Policy:
    name: str = "F0"

    def __post_init__(self):
        if self.name not in POLICIES:
            raise ValueError(f"unknown R33 policy {self.name!r}")

    @property
    def mode(self):
        return self.name.split("^")[1] if self.name.startswith("C_") else None

    @property
    def fraction(self):
        return float(self.name[2:].split("^")[0]) if self.mode else None

    def magnitude(self, reference, peak, scale):
        if self.name == "F0":
            return fmax(abs(reference), scale)
        if self.name == "STD-rel":
            return abs(reference)
        if self.name == "PRE1045":
            return 1.0 + abs(reference)
        return fmax(abs(reference), self.fraction * peak)

    def step(self, raw, previous, current, peak, scale):
        if self.name == "PRE1045":
            denominator = 1.0 + abs(current)
        else:
            reference = fmax(abs(current), abs(previous))
            denominator = self.magnitude(reference, peak, scale)
        if (self.name == "STD-rel" or self.mode) and denominator == 0.0:
            if math.isfinite(previous) and math.isfinite(current) and previous == current == 0.0:
                return raw  # the registered finite zero-to-zero step, preserving its sign
        return divide(raw, denominator)


class Slot:
    """A numeric binding's retained state; each record is one observation.

    Lists are oldest first. Predicate loops explicitly reverse them wherever
    the runtime walks the newest-first ring, preserving floating sum order.
    The constructor accepts a direct-test depth of 1 as well as normal
    runtime depths through 64; the subject's default depth is 10.
    """

    def __init__(self, policy="F0", window=10, scale=0.001, dh_zero=0.001, dh_small=0.01):
        self.policy = policy if isinstance(policy, Policy) else Policy(policy)
        if type(window) is not int or not 1 <= window <= 64:
            raise ValueError("window must be an integer in 1..64")
        self.window = window
        self.scale, self.zero, self.small = float(scale), float(dh_zero), float(dh_small)
        self.reset()

    def reset(self):
        self.values, self.raw, self.exact, self.rel = [], [], [], []
        self.best, self.best_used, self.since = 0.0, False, 255
        self.peak_abs, self.count = 0.0, 0

    def copy(self):
        return copy.deepcopy(self)

    def peak(self):
        if self.policy.mode == "hist":
            return self.peak_abs
        peak = 0.0
        for value in self.values:
            shadow = float(value)
            if math.isfinite(shadow) and abs(shadow) > peak:
                peak = abs(shadow)
        return peak

    def record(self, value):
        if type(value) not in (int, float):
            raise TypeError("numeric port accepts typed int or float observations")
        if is_int(value) and not INT_MIN <= value <= INT_MAX:
            raise ValueError("integer observation is outside int64")
        shadow = float(value)
        previous = self.values[-1] if self.values else None
        if previous is not None:
            delta = value - previous if is_int(value) and is_int(previous) else 0
            exact = is_int(value) and is_int(previous) and INT_MIN <= delta <= INT_MAX
            raw = float(delta) if exact else shadow - float(previous)
        self.values.append(value)
        self.values = self.values[-(self.window + 1):]
        if math.isfinite(shadow) and abs(shadow) > self.peak_abs:
            self.peak_abs = abs(shadow)
        peak = self.peak()
        if previous is not None:
            relative = self.policy.step(raw, float(previous), shadow, peak, self.scale)
            self.raw.append(raw)
            self.exact.append(exact)
            self.rel.append(relative)
            self.raw, self.exact, self.rel = (xs[-self.window:] for xs in (self.raw, self.exact, self.rel))
        else:
            self.since = 255
        threshold = self.best - self.zero * self.policy.magnitude(self.best, peak, self.scale)
        if not self.best_used and math.isfinite(shadow):
            self.best, self.best_used = shadow, True
        elif self.best_used and math.isfinite(shadow) and value < threshold:
            self.best, self.since = shadow, 0
        elif self.since < 255:
            self.since += 1
        self.count += 1
        return self

    def steps(self):
        if not self.policy.mode:
            return self.rel[:]
        # Item 7: every retained step uses the peak of this question. Raw
        # exact-int subtraction is retained rather than reconstructed from
        # rounded float shadows, as in observer_slot_record_num.
        peak = self.peak()
        return [self.policy.step(raw, float(a), float(b), peak, self.scale)
                for raw, a, b in zip(self.raw, self.values, self.values[1:])]

    def all_exact(self):
        return bool(self.exact) and all(self.exact)

    def noise_floor(self):
        if self.all_exact():
            return 0.0
        last = float(self.values[-1]) if self.values else 0.0
        magnitude = (1.0 + abs(last) if self.policy.name in ("F0", "PRE1045") else
                     self.policy.magnitude(last, self.peak(), self.scale))
        return 4.0 * sys.float_info.epsilon * magnitude

    def raw_nonvanishing(self):
        count = len(self.raw)
        if count < 4:
            return False
        half = count // 2
        recent = 0.0
        older = 0.0
        newest = self.raw[::-1]
        for d in newest[:half]:
            recent += abs(d)
        for d in newest[half:]:
            older += abs(d)
        recent /= float(half)
        older /= float(count - half)
        floor = self.noise_floor()
        if older <= floor or recent <= floor:
            return False
        return recent >= older * (1.0 - 1e-9)

    def raw_diverging(self):
        if not self.raw_nonvanishing():
            return False
        first = self.raw[-1]
        return all(not d * first <= 0.0 for d in self.raw[-2::-1])

    def raw_oscillating(self):
        if not self.raw_nonvanishing():
            return False
        floor = self.noise_floor()
        newest = self.raw[::-1]
        flips = sum(a * b < 0.0 and abs(a) > floor and abs(b) > floor
                    for a, b in zip(newest, newest[1:]))
        return flips >= (self.window + 2) // 3

    def flags(self):
        all_zero, all_small = True, True
        for relative in self.steps()[::-1]:
            magnitude = abs(relative)
            if magnitude >= self.zero:
                all_zero = False
            if magnitude >= self.small:
                all_small = False
        return all_zero, all_small

    def rel_oscillating(self):
        if len(self.raw) < 3:
            return False
        newest = self.steps()[::-1]
        flips = sum(a * b < 0.0 and abs(a) > self.zero and abs(b) > self.zero
                    for a, b in zip(newest, newest[1:]))
        return flips >= (self.window + 2) // 3

    def bounded_oscillating(self):
        if len(self.raw) < self.window or self.flags()[0]:
            return False
        floor = self.noise_floor()
        net, path, previous = 0.0, 0.0, 0.0
        reversals, have_previous = 0, False
        for d in self.raw[::-1]:
            net += d
            path += abs(d)
            if abs(d) > floor:
                if have_previous and d * previous < 0.0:
                    reversals += 1
                previous, have_previous = d, True
        if path <= floor:
            return False
        return reversals >= 2 and abs(net) <= 0.3 * path

    def finite_window(self):
        return bool(self.values) and all(math.isfinite(float(v)) for v in self.values)

    def opposite_inf(self):
        last = float(self.values[-1])
        return any(math.isinf(float(v)) and math.copysign(1.0, float(v)) != math.copysign(1.0, last)
                   for v in self.values[::-1])

    def oscillating(self):
        if not self.values or math.isnan(float(self.values[-1])):
            return False
        if math.isinf(float(self.values[-1])):
            return self.opposite_inf()
        return self.rel_oscillating() or self.raw_oscillating() or self.bounded_oscillating()

    def diverging(self):
        if not self.values or math.isnan(float(self.values[-1])):
            return False
        if math.isinf(float(self.values[-1])):
            return not self.opposite_inf()
        return self.raw_diverging()

    def reference_diverging(self):
        if len(self.values) < self.window + 1:
            return False
        w = [float(v) for v in self.values]
        tau = self.zero * self.policy.magnitude(w[-1], self.peak(), self.scale)
        positive, negative = True, True
        for a, b in zip(w, w[1:]):
            d = b - a
            if not d > tau:
                positive = False
            if not d < -tau:
                negative = False
        if not positive and not negative:
            return False
        sum_log = 0.0
        for i in range(2, len(w)):
            a, b = w[i - 1] - w[i - 2], w[i] - w[i - 1]
            sum_log += logarithm(divide(abs(b), abs(a)))
        return exponential(divide(sum_log, float(len(w) - 2))) >= 1.0 - 1e-9

    def reference_expanding(self):
        w = [float(v) for v in self.values]
        mean = 0.0
        for value in w:
            mean += value
        mean /= float(len(w))
        half = len(w) // 2
        older, newer, crossings = 0.0, 0.0, 0
        for i, value in enumerate(w):
            d = value - mean
            magnitude = abs(d)
            if i < half:
                if magnitude > older:
                    older = magnitude
            elif magnitude > newer:
                newer = magnitude
            if i and (w[i - 1] - mean) * d < 0.0:
                crossings += 1
        return crossings >= 2 and newer > older

    def improving(self):
        if not self.best_used or self.since >= self.window or not self.finite_window():
            return False
        return not self.reference_diverging() and not (
            len(self.values) >= self.window + 1 and self.reference_expanding())

    def exact_diameter(self):
        # C's uint64 subtraction, then conversion to double; valid even
        # when the diameter exceeds INT64_MAX.
        return float(max(self.values) - min(self.values))

    def converged(self):
        if len(self.values) < self.window + 1 or not self.finite_window():
            return False
        if self.all_exact():
            return self.exact_diameter() <= self.zero * self.scale
        lo, hi = min(map(float, self.values)), max(map(float, self.values))
        return hi - lo <= self.zero * self.policy.magnitude(float(self.values[-1]), self.peak(), self.scale)

    def raw_one_direction(self):
        negative, nonzero = False, 0
        for d in self.raw[::-1]:
            if d == 0.0:
                continue
            sign = math.copysign(1.0, d) < 0.0
            if nonzero == 0:
                negative = sign
            elif sign != negative:
                return False
            nonzero += 1
        return nonzero >= 2

    def equilibrium(self):
        if not self.values or not math.isfinite(float(self.values[-1])) or len(self.raw) < self.window:
            return False
        if self.raw_one_direction() or self.raw_oscillating():
            return False
        newest = self.steps()[::-1]
        total = 0.0
        for relative in newest:
            total += relative
        mean = total / float(self.window)
        if abs(mean) >= self.zero:
            return False
        variance = 0.0
        for relative in newest:
            d = relative - mean
            variance += d * d
        variance /= float(self.window)
        return variance < self.zero * self.zero

    def stable(self):
        if len(self.values) < self.window + 1 or not self.finite_window():
            return False
        if self.all_exact():
            return self.exact_diameter() <= 2.0 * self.small * self.scale
        lo, hi = min(map(float, self.values)), max(map(float, self.values))
        half_diameter = hi / 2.0 - lo / 2.0
        midrange = hi / 2.0 + lo / 2.0
        return half_diameter <= self.small * self.policy.magnitude(midrange, self.peak(), self.scale)

    def report(self):
        if not self.values:
            return "equilibrium"
        if math.isnan(float(self.values[-1])):
            return "undefined"
        if self.oscillating():
            return "oscillating"
        if self.diverging():
            return "diverging"
        if not self.raw:
            return "equilibrium"
        if self.improving():
            return "improving"
        if len(self.raw) >= self.window:
            for name in ("converged", "equilibrium", "stable"):
                if getattr(self, name)():
                    return name
            return "moving"
        return "stable" if self.flags()[1] else "moving"

    def reading(self):
        where = self.values[-1] if self.values else None
        why = None
        how = None
        quiet = False
        if self.raw:
            why = self.values[-1] - self.values[-2] if self.exact[-1] else self.raw[-1]
            relative = self.steps()[-1]
            how = (math.nan if math.isnan(self.raw[-1]) else 0.0 if math.isinf(self.raw[-1]) else
                   divide(self.zero, self.zero + abs(relative)))
            quiet = abs(relative) < self.zero
        return {**{name: bool(getattr(self, name)()) for name in PREDS},
                "report": self.report(), "how": how, "quiet": bool(quiet),
                "where": where, "where_kind": kind(where), "why": why,
                "why_kind": kind(why), "count": self.count}

    def snapshot(self):
        """Temporal reads retain the answer at their own moment (item 7)."""
        return copy.deepcopy(self.reading())

    def trajectory(self):
        raw = [b - a if exact else d for a, b, d, exact in
               zip(self.values, self.values[1:], self.raw, self.exact)]
        return {"kind": "trajectory", "values": self.values[:], "rel": self.steps(),
                "raw": raw, "exact": self.exact[:], "dh": [], "entropy": None,
                "dH": None, "last_entropy": None, "last_value": self.values[-1] if self.values else None,
                "best": self.best if self.best_used else None,
                "since": self.since if self.since != 255 else None,
                "observed": bool(self.values), "numeric": bool(self.values),
                "window": self.window,
                **({"peak_abs": self.peak_abs} if self.policy.mode == "hist" else {})}

    @classmethod
    def from_trajectory(cls, data, policy="F0", **configuration):
        """Import retained values and D2 state; C ignores stored relatives."""
        if data.get("kind") != "trajectory":
            raise ValueError("not a trajectory")
        obj = cls(policy=policy, window=data["window"], **configuration)
        values, relative, raw, exact = (data[k] for k in ("values", "rel", "raw", "exact"))
        if not (len(relative) == len(raw) == len(exact) == max(0, len(values) - 1)):
            raise ValueError("trajectory channels have unequal lengths")
        for value in values:
            obj.record(value)
        for old, rebuilt in zip(exact[-obj.window:], obj.exact):
            if type(old) is not bool or (old and not rebuilt):
                raise ValueError("trajectory cannot invent exactness")
        obj.raw = [float(v) for v in raw[-obj.window:]]
        obj.exact = exact[-obj.window:]
        if not obj.policy.mode:
            obj.rel = [float(v) for v in relative[-obj.window:]]
        best = data.get("best")
        if best is not None:
            if type(best) not in (int, float) or not math.isfinite(float(best)):
                raise ValueError("trajectory best is not finite")
            obj.best, obj.best_used = float(best), True
        age = data.get("since")
        if age is not None and (type(age) not in (int, float) or not math.isfinite(float(age)) or
                                age != math.floor(age) or not 0 <= age <= 255):
            raise ValueError("trajectory since is not a uint8")
        obj.since = 255 if age is None else int(age)
        if obj.policy.mode == "hist":
            peak = data.get("peak_abs")
            if type(peak) not in (int, float) or not math.isfinite(float(peak)) or peak < obj.peak_abs:
                raise ValueError("historical trajectory lacks its finite history peak")
            obj.peak_abs = float(peak)
        return obj
