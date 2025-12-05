# Bootstrap Roadmap - Path to Full Self-Hosting

**Version:** 1.0  
**Created:** 2025-12-03  
**Status:** Active Development  
**Priority:** Critical

---

## Overview

This document provides a high-level roadmap for achieving **full self-hosting** in EigenScript, where the self-hosted compiler can compile itself without relying on the Python reference compiler.

**Current State:** ⚠️ Partial Self-Hosting  
**Target State:** ✅ Full Self-Hosting  
**Blocking Issue:** Numeric literal bug in Stage 1 compiler

---

## The Three Stages of Bootstrap

```
┌─────────────────────────────────────────────────────────┐
│ Stage 0: Python Reference Compiler                     │
│ - Written in Python (3,126 lines)                      │
│ - Production-ready and tested                          │
│ - Generates LLVM IR from EigenScript                   │
│ ✅ STATUS: Complete and working                        │
└────────────────┬────────────────────────────────────────┘
                 │
                 │ compiles
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Stage 1: Self-Hosted Compiler (eigensc)                │
│ - Written in EigenScript (5,642 lines)                 │
│ - Compiled by Stage 0                                  │
│ - Should generate LLVM IR from EigenScript             │
│ ⚠️ STATUS: Runs but has critical bug                   │
│ 🐛 BUG: All numeric literals generate as 0.0           │
└────────────────┬────────────────────────────────────────┘
                 │
                 │ should compile (BLOCKED)
                 ▼
┌─────────────────────────────────────────────────────────┐
│ Stage 2: Self-Compiled Compiler                        │
│ - Same source as Stage 1                               │
│ - Compiled by Stage 1                                  │
│ - Should produce identical output to Stage 1           │
│ 🎯 STATUS: Target state (not yet achieved)            │
└─────────────────────────────────────────────────────────┘
```

---

## Current Status

### ✅ Achievements

1. **Self-Hosted Compiler Implementation**
   - Lexer: 578 lines
   - Parser: 1,612 lines
   - Semantic analyzer: 758 lines
   - Code generator: 2,372 lines
   - Main pipeline: 322 lines
   - **Total:** 5,642 lines of EigenScript

2. **Stage 0 → Stage 1 Compilation**
   - All modules compile successfully
   - LLVM IR is valid
   - Modules link correctly
   - Binary executes without errors

3. **Stage 1 Basic Functionality**
   - Parses EigenScript source
   - Generates LLVM IR structure
   - Calls runtime functions correctly
   - Produces valid, compilable output

### ❌ Critical Issue: Numeric Literal Bug

**Problem:**  
When Stage 1 compiles a program like `x is 42`, it generates:
```llvm
%1 = fadd double 0.0, 0.0  ❌
```

Instead of:
```llvm
%1 = fadd double 0.0, 42.0  ✅
```

**Impact:**
- Stage 1 cannot compile any program with numeric literals
- Full bootstrap is blocked
- Self-hosting milestone incomplete

**Root Cause:**  
The bug originates in the **Python reference compiler** when it compiles the self-hosted modules. The generated code for list access (`ast_num_value[arr_idx]`) always returns 0.0 instead of the actual stored value.

---

## The Path Forward

### Phase 1: Fix the Numeric Literal Bug ⏳

**Duration:** 2-3 weeks  
**Priority:** CRITICAL  
**Blocking:** Full bootstrap

**Approach:**
1. Investigate how reference compiler generates code for list access
2. Identify why values are read as 0.0
3. Fix the code generation in `llvm_backend.py`
4. Validate Stage 1 works correctly

**Resources:**
- 📋 [Detailed Investigation Plan](./BOOTSTRAP_FIX_PLAN.md)
- ✅ [Investigation Checklist](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)

**Success Criteria:**
- [ ] Stage 1 compiles programs with correct numeric values
- [ ] Simple test: `x is 42; print of x` outputs 42 (not 0)
- [ ] All 665 existing tests still pass

### Phase 2: Fix Parser Blank Line Issue ⏸️

**Duration:** 1-2 weeks  
**Priority:** HIGH  
**Blocked by:** Phase 1

**Problem:**  
The self-hosted parser cannot handle blank lines inside function bodies. This prevents Stage 1 from compiling the self-hosted compiler source (which has blank lines).

**Example:**
```eigenscript
define foo as:
    x is 10
    ← blank line here causes parse error
    y is 20
    return x + y
```

**Workaround:**  
Currently, we can test Stage 1 on programs without blank lines.

**Solution:**  
Enhance `parser.eigs` to handle blank lines (EMPTY_LINE tokens) inside function bodies.

**Success Criteria:**
- [ ] Parser handles blank lines in functions
- [ ] Can parse complex multi-function programs
- [ ] Self-hosted compiler source parses correctly

### Phase 3: Achieve Full Bootstrap 🎯

**Duration:** 1-2 weeks  
**Priority:** HIGH  
**Blocked by:** Phase 1 + Phase 2

**Goal:**  
Stage 1 compiles itself to produce Stage 2

**Process:**
1. Run Stage 1 on self-hosted compiler source
2. Generate LLVM IR for all modules
3. Link into Stage 2 executable
4. Verify Stage 2 also works

**Success Criteria:**
- [ ] Stage 1 successfully compiles itself
- [ ] Stage 2 executable is created
- [ ] Stage 2 can compile simple programs
- [ ] Stage 1 and Stage 2 produce identical output (bit-for-bit)

### Phase 4: Validation and Documentation ✍️

**Duration:** 1 week  
**Priority:** MEDIUM  
**Blocked by:** Phase 3

**Activities:**
1. Comprehensive testing of Stage 1 and Stage 2
2. Performance benchmarking
3. Update documentation
4. Prepare release (v0.5.0)

**Deliverables:**
- [ ] Updated COMPILER_SELF_HOSTING.md
- [ ] Bootstrap verification script
- [ ] Performance comparison report
- [ ] Release notes and changelog

---

## Timeline

### Optimistic (4-6 weeks)

```
Week 1-2:  Phase 1 - Fix numeric literal bug
Week 3-4:  Phase 2 - Fix parser blank lines
Week 5:    Phase 3 - Achieve full bootstrap
Week 6:    Phase 4 - Validation and docs
```

### Realistic (8-10 weeks)

```
Week 1-3:  Phase 1 - Fix numeric literal bug (complex investigation)
Week 4-5:  Phase 2 - Fix parser blank lines
Week 6-8:  Phase 3 - Achieve full bootstrap (with iterations)
Week 9-10: Phase 4 - Validation and docs
```

### Conservative (12-16 weeks)

```
Week 1-5:  Phase 1 - Fix numeric literal bug (complex refactoring)
Week 6-8:  Phase 2 - Fix parser blank lines (redesign needed)
Week 9-13: Phase 3 - Achieve full bootstrap (multiple attempts)
Week 14-16: Phase 4 - Validation and docs
```

---

## Risk Assessment

### High Risks

1. **Numeric literal bug is deeply rooted**
   - Impact: Long investigation time
   - Mitigation: Systematic approach, multiple hypotheses
   - Contingency: Refactor affected code section

2. **Fix breaks other functionality**
   - Impact: Regression in reference compiler
   - Mitigation: Comprehensive test suite
   - Contingency: Phased rollout, feature flags

3. **Parser redesign required**
   - Impact: Extended timeline
   - Mitigation: Start with minimal changes
   - Contingency: Accept blank line limitation temporarily

### Medium Risks

1. **Performance degradation**
   - Impact: Slower compilation
   - Mitigation: Benchmarking before/after
   - Contingency: Profile and optimize

2. **Memory issues in Stage 1**
   - Impact: Crashes on large programs
   - Mitigation: Test with various input sizes
   - Contingency: Increase limits, optimize allocations

### Low Risks

1. **Platform-specific issues**
   - Impact: Works on some systems, not others
   - Mitigation: Test on Linux, macOS, Windows
   - Contingency: Document known limitations

---

## Success Metrics

### Milestone 1: Numeric Literal Bug Fixed

**Criteria:**
- [ ] Stage 1 compiles `x is 42` correctly (generates `fadd double 0.0, 42.0`)
- [ ] All test cases pass (665/665)
- [ ] No regressions in reference compiler
- [ ] Performance within 10% of baseline

**Verification:**
```bash
cd build/bootstrap
cat > test.eigs << 'EOF'
x is 42
y is 100
z is x + y
print of z
EOF

./eigensc test.eigs > test.ll
grep "fadd double" test.ll | head -1
# Should show: fadd double 0.0, 42.0 or similar with correct values
```

### Milestone 2: Parser Handles Blank Lines

**Criteria:**
- [ ] Parser accepts blank lines in function bodies
- [ ] Self-hosted compiler source parses completely
- [ ] No breaking changes to parser API
- [ ] Existing programs still parse correctly

**Verification:**
```bash
cd build/bootstrap
./eigensc ../../src/eigenscript/compiler/selfhost/main.eigs > main_stage2.ll
# Should succeed without parse errors
```

### Milestone 3: Full Bootstrap Achieved

**Criteria:**
- [ ] Stage 1 compiles itself (produces Stage 2)
- [ ] Stage 2 executable works
- [ ] Stage 1 and Stage 2 outputs are identical
- [ ] Bootstrap process is reproducible

**Verification:**
```bash
# Compile test program with both
./eigensc test.eigs > test_stage1.ll
./eigensc2 test.eigs > test_stage2.ll

# Compare outputs
diff test_stage1.ll test_stage2.ll
# Should have no differences (or only timestamps)
```

---

## Documentation Structure

The bootstrap investigation is documented in multiple files:

```
docs/
├── BOOTSTRAP_ROADMAP.md            ← You are here (high-level overview)
├── BOOTSTRAP_FIX_PLAN.md           ← Detailed investigation plan
├── BOOTSTRAP_INVESTIGATION_CHECKLIST.md  ← Actionable checklists
├── COMPILER_SELF_HOSTING.md        ← User guide for self-hosting
└── SELF_HOSTING_QUICKSTART.md      ← Quick start guide
```

**Use this structure:**
- Start here for overview and timeline
- Go to FIX_PLAN for detailed technical investigation
- Use CHECKLIST for day-to-day investigation work
- Refer to SELF_HOSTING guide for user-facing documentation

---

## Contributing

### How to Help

**Priority tasks:**
1. 🔥 Investigate numeric literal bug (Phase 1)
2. 🔍 Test hypotheses in investigation checklist
3. 📊 Analyze LLVM IR patterns
4. 🛠️ Implement fixes to reference compiler
5. ✅ Validate fixes with test cases

**Getting started:**
1. Read [BOOTSTRAP_FIX_PLAN.md](./BOOTSTRAP_FIX_PLAN.md)
2. Follow [BOOTSTRAP_INVESTIGATION_CHECKLIST.md](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)
3. Set up debug environment
4. Pick a hypothesis to test
5. Document findings

**Communication:**
- Open GitHub issues with tag `bootstrap`
- Reference this roadmap in discussions
- Share investigation findings
- Propose fixes via pull requests

---

## Questions and Answers

### Why is this important?

Full self-hosting demonstrates language maturity and compiler correctness. It's a significant milestone that proves EigenScript is powerful enough to implement its own tools.

### What if the bug is too hard to fix?

We have a working reference compiler, so EigenScript development continues. But fixing this unblocks a major milestone and validates the language design.

### Can I use EigenScript now?

Yes! The Python reference compiler is production-ready. Use `eigenscript-compile` for real projects. The self-hosted compiler is currently a proof-of-concept.

### How can I test my changes?

Run `bash scripts/bootstrap_test.sh` to test the full pipeline. See the investigation checklist for detailed testing commands.

### Where do I report findings?

Open a GitHub issue or update the investigation documents directly via pull request.

---

## References

**Technical Documentation:**
- [LLVM IR Language Reference](https://llvm.org/docs/LangRef.html)
- [Compiler Design Principles](https://en.wikipedia.org/wiki/Compiler)
- [Self-Hosting Compilers](https://en.wikipedia.org/wiki/Self-hosting_(compilers))

**EigenScript Resources:**
- [Language Specification](../spec/specification.md)
- [Compiler Architecture](./architecture.md)
- [Contributing Guide](../CONTRIBUTING.md)

**Classic Papers:**
- "Reflections on Trusting Trust" by Ken Thompson
- "The Art of the Metaobject Protocol" by Kiczales et al.

---

## Changelog

### 2025-12-03 - Initial Version

- Created roadmap document
- Defined three phases toward full bootstrap
- Established success criteria and timelines
- Created supporting documentation
- Set up investigation framework

---

**Next Review:** After Phase 1 completion  
**Owner:** Development Team  
**Status:** Active Development

---

## Quick Links

- 📋 [Detailed Investigation Plan](./BOOTSTRAP_FIX_PLAN.md)
- ✅ [Investigation Checklist](./BOOTSTRAP_INVESTIGATION_CHECKLIST.md)
- 📖 [Self-Hosting Guide](./COMPILER_SELF_HOSTING.md)
- 🚀 [Quick Start](./SELF_HOSTING_QUICKSTART.md)
- 🏗️ [Project Roadmap](../ROADMAP.md)

**Let's achieve full self-hosting! 🚀**
