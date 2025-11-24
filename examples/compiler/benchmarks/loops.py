#!/usr/bin/env python3
"""Recursive sum benchmark - Python baseline"""


def sum_to(n):
    if n < 1:
        return 0
    else:
        return sum_to(n - 1) + n


x = sum_to(100)
print(x)
