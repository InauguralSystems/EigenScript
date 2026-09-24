# file: tests/http_readiness.py
# Crash control for tools/mutants.sh http_readiness: no named FAIL is printed.
s/^import contextlib$/raise SystemExit(77)\nimport contextlib/
