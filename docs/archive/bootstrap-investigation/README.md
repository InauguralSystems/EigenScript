# Bootstrap Investigation Archive

**Status: RESOLVED** (December 5, 2025)

This directory contains historical documentation from the bootstrap investigation conducted December 3-5, 2025. These files document the debugging process that led to achieving **fixpoint bootstrap** in v0.4.1.

## What Happened

1. **Dec 3-4**: Investigation began into why Stage 1 compiler produced incorrect output
2. **Dec 4-5**: Root causes identified and fixed:
   - External variable assignment in codegen
   - Runtime pointer detection for non-PIE binaries
   - Cross-module global naming alignment
3. **Dec 5**: Fixpoint bootstrap achieved - Stage 2 = Stage 3

## Files in This Archive

| File | Description |
|------|-------------|
| `BOOTSTRAP_PLAN_SUMMARY.md` | High-level investigation strategy |
| `BOOTSTRAP_FIX_PLAN.md` | Detailed technical analysis of the numeric literal bug |
| `BOOTSTRAP_INVESTIGATION_CHECKLIST.md` | Step-by-step debugging checklist |
| `BOOTSTRAP_ROADMAP.md` | Phased approach to fixing bootstrap |
| `BOOTSTRAP_DEBUG_QUICKREF.md` | Quick reference for debugging |
| `BOOTSTRAP_INDEX.md` | Index of all bootstrap documentation |

## Current Documentation

For up-to-date information on the self-hosted compiler, see:
- [SELF_HOSTING_QUICKSTART.md](../../SELF_HOSTING_QUICKSTART.md) - Get started in 5 minutes
- [COMPILER_SELF_HOSTING.md](../../COMPILER_SELF_HOSTING.md) - Complete technical guide

## Why Keep These Files?

These documents are preserved for:
1. **Historical reference** - Understanding the bootstrap journey
2. **Learning** - Future debugging of similar issues
3. **Attribution** - Recording the work that achieved this milestone
