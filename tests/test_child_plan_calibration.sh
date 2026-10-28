#!/usr/bin/env bash
# Clean control plus the two plan-contract plants used only by the calibration driver.
set -u
[ "${EIGS_PLAN_PLANT:-}" = missing-plan ] || echo "PLAN: 2"
echo "  PASS: first declared check"
[ "${EIGS_PLAN_PLANT:-}" = short ] || echo "  PASS: second declared check"
