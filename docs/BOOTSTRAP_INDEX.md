# Bootstrap Investigation - Documentation Index

**Created:** 2025-12-03  
**Status:** Active Investigation  
**Purpose:** Central hub for all bootstrap-related documentation

---

## Overview

This directory contains comprehensive documentation for investigating and fixing the EigenScript self-hosted compiler bootstrapping issues. The primary focus is the **numeric literal bug** that prevents the Stage 1 compiler from correctly compiling programs.

---

## Document Structure

### 🗺️ [BOOTSTRAP_ROADMAP.md](./BOOTSTRAP_ROADMAP.md)
**Start here for the big picture**

- High-level overview of the bootstrap process
- The three stages of self-hosting
- Timeline and milestones
- Risk assessment
- Success criteria

**Use when:** You want to understand the overall plan and timeline

---

### 📋 [BOOTSTRAP_FIX_PLAN.md](./BOOTSTRAP_FIX_PLAN.md)
**Comprehensive technical investigation plan**

- Detailed problem analysis
- Known facts and what's been investigated
- 5 specific hypotheses to test
- Investigation strategy (5 phases)
- Diagnostic steps with exact commands
- Fix implementation plan
- 28 pages of detailed guidance

**Use when:** You're actively investigating the bug and need detailed technical guidance

---

### ✅ [BOOTSTRAP_INVESTIGATION_CHECKLIST.md](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)
**Actionable day-to-day checklist**

- Quick start commands
- Phase-by-phase checklists
- Test case templates
- Progress tracking tables
- Emergency rollback procedures
- 14 pages of practical steps

**Use when:** You're doing the actual investigation work and need step-by-step guidance

---

### 🔧 [BOOTSTRAP_DEBUG_QUICKREF.md](./BOOTSTRAP_DEBUG_QUICKREF.md)
**One-page command reference**

- Quick commands for common tasks
- Debug logging snippets
- Test case examples
- Validation checklist
- Emergency procedures
- 5 pages of quick reference

**Use when:** You need to quickly look up a command or debug technique

---

## The Problem

### Current Situation

```
Stage 0 (Python)  →  Stage 1 (EigenScript)  →  Stage 2 (Goal)
     ✅                     ⚠️                      🎯
   Works              Has bug               Not achieved
```

### The Bug

When Stage 1 compiles `x is 42`, it generates:
```llvm
❌ %1 = fadd double 0.0, 0.0
```

Instead of:
```llvm
✅ %1 = fadd double 0.0, 42.0
```

**Impact:** Stage 1 cannot compile any real programs with numeric literals.

### Root Cause

The bug is in the **Python reference compiler** (`llvm_backend.py`) when it compiles the self-hosted compiler modules. Specifically, it generates incorrect code for list access operations like `ast_num_value[arr_idx]`.

---

## Quick Navigation

### I want to...

**Understand the problem:**
→ Read [BOOTSTRAP_ROADMAP.md](./BOOTSTRAP_ROADMAP.md) first

**Start investigating:**
→ Follow [BOOTSTRAP_INVESTIGATION_CHECKLIST.md](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)

**Deep dive into technical details:**
→ Study [BOOTSTRAP_FIX_PLAN.md](./BOOTSTRAP_FIX_PLAN.md)

**Look up a command quickly:**
→ Reference [BOOTSTRAP_DEBUG_QUICKREF.md](./BOOTSTRAP_DEBUG_QUICKREF.md)

**Learn about self-hosting in general:**
→ See [COMPILER_SELF_HOSTING.md](./COMPILER_SELF_HOSTING.md)

**Get started with the self-hosted compiler:**
→ Try [SELF_HOSTING_QUICKSTART.md](./SELF_HOSTING_QUICKSTART.md)

---

## Investigation Workflow

### Recommended sequence:

1. **Day 1: Setup and Understanding**
   - Read BOOTSTRAP_ROADMAP.md
   - Read COMPILER_SELF_HOSTING.md sections on the bug
   - Run `scripts/bootstrap_test.sh` to see current behavior
   - Reproduce the bug manually

2. **Day 2-3: Initial Investigation**
   - Follow Phase 1 of BOOTSTRAP_INVESTIGATION_CHECKLIST.md
   - Create minimal test cases
   - Examine LLVM IR outputs
   - Document findings

3. **Day 4-7: Deep Investigation**
   - Follow Phase 2-3 of BOOTSTRAP_INVESTIGATION_CHECKLIST.md
   - Test hypotheses from BOOTSTRAP_FIX_PLAN.md
   - Add debug logging to reference compiler
   - Narrow down root cause

4. **Day 8-14: Fix Implementation**
   - Follow Phase 4-5 of BOOTSTRAP_INVESTIGATION_CHECKLIST.md
   - Implement fix based on findings
   - Test thoroughly
   - Validate with full test suite

5. **Day 15-21: Validation**
   - Attempt full bootstrap
   - Update documentation
   - Prepare release

---

## Key Files to Understand

### Source Code
- `src/eigenscript/compiler/codegen/llvm_backend.py` - Reference compiler (**bug is here**)
- `src/eigenscript/compiler/selfhost/codegen.eigs` - Self-hosted codegen (victim of bug)
- `src/eigenscript/compiler/selfhost/parser.eigs` - Parser creating AST
- `src/eigenscript/compiler/runtime/eigenvalue.c` - Runtime library

### Tests and Scripts
- `scripts/bootstrap_test.sh` - Full bootstrap test script
- `tests/test_*.py` - Existing test suite (665 tests)

### Build Artifacts
- `build/bootstrap/*.ll` - Generated LLVM IR
- `build/bootstrap/eigensc` - Stage 1 compiler binary

---

## Contributing

### How to Help

1. **Investigation:**
   - Test hypotheses from the fix plan
   - Analyze LLVM IR patterns
   - Document findings

2. **Fix Implementation:**
   - Modify reference compiler
   - Create test cases
   - Validate changes

3. **Documentation:**
   - Update investigation notes
   - Add findings to documents
   - Improve clarity

### Reporting Progress

**When you find something:**
1. Update the relevant checklist
2. Document in investigation notes
3. Open GitHub issue if needed
4. Share with team

**When you make changes:**
1. Test thoroughly
2. Update documentation
3. Create pull request
4. Reference this documentation

---

## Success Criteria

The bootstrap investigation succeeds when:

1. ✅ Root cause identified and documented
2. ✅ Fix implemented in reference compiler
3. ✅ Stage 1 compiles programs with correct numeric values
4. ✅ All 665 tests pass
5. ✅ Stage 1 compiles itself (Stage 2 created)
6. ✅ Stage 1 and Stage 2 produce identical output

---

## Timeline

- **Optimistic:** 4-6 weeks
- **Realistic:** 8-10 weeks  
- **Conservative:** 12-16 weeks

See [BOOTSTRAP_ROADMAP.md](./BOOTSTRAP_ROADMAP.md) for detailed timeline.

---

## Resources

### Documentation
- [EigenScript Specification](../spec/specification.md)
- [Compiler Architecture](./architecture.md)
- [Contributing Guidelines](../CONTRIBUTING.md)
- [Known Issues](./KNOWN_ISSUES.md)

### External Resources
- [LLVM IR Reference](https://llvm.org/docs/LangRef.html)
- [Compiler Design Principles](https://www.amazon.com/Engineering-Compiler-Keith-Cooper/dp/012088478X)
- [Self-Hosting Compilers](https://en.wikipedia.org/wiki/Self-hosting_(compilers))

### Tools
- LLVM toolchain: `llvm-as`, `llc`, `opt`, `llvm-dis`
- Debuggers: `gdb`, `lldb`, `valgrind`
- Analysis: `nm`, `objdump`, `readelf`

---

## Version History

### 2025-12-03 - Initial Release (v1.0)
- Created comprehensive documentation structure
- Four main documents totaling 60+ pages
- Established investigation framework
- Defined success criteria and timeline

---

## Questions?

**For technical questions:**
- Open GitHub issue with tag `bootstrap`
- Reference specific document sections
- Include reproduction steps

**For contributing:**
- See [CONTRIBUTING.md](../CONTRIBUTING.md)
- Join discussion on GitHub
- Submit pull requests

---

## Next Steps

1. **Read:** [BOOTSTRAP_ROADMAP.md](./BOOTSTRAP_ROADMAP.md)
2. **Prepare:** Set up development environment
3. **Start:** Follow [BOOTSTRAP_INVESTIGATION_CHECKLIST.md](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)
4. **Debug:** Use [BOOTSTRAP_DEBUG_QUICKREF.md](./BOOTSTRAP_DEBUG_QUICKREF.md)
5. **Fix:** Apply lessons from [BOOTSTRAP_FIX_PLAN.md](./BOOTSTRAP_FIX_PLAN.md)

---

**Let's achieve full self-hosting! 🚀**

---

**Document Owner:** Development Team  
**Last Updated:** 2025-12-03  
**Status:** Active
