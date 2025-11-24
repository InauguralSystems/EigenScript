#!/usr/bin/env python3
"""Factorial benchmark - Python baseline"""


def factorial(n):
    if n < 2:
        return 1
    else:
        return n * factorial(n - 1)


x = factorial(10)
print(x)
