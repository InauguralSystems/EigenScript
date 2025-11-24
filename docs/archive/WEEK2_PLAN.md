# Week 2 Implementation Plan

**Date**: 2025-11-19  
**Status**: Ready to Execute  
**Focus**: Quality Improvements and Code Cleanup

---

## Overview

Week 1 has been successfully completed with all targets exceeded:
- ✅ CLI Testing: 80% coverage (target: 75%+)
- ✅ Module Cleanup: 211 lines removed
- ✅ Overall Coverage: 78% (target: 70%+)
- ✅ All 351 tests passing

Week 2 focuses on **quality improvements** to make the codebase production-ready.

---

## Tasks for Week 2

### Task 2.1: TODO Resolution ⚡ STARTING WITH THIS
**Priority**: HIGH  
**Effort**: 1-2 days  
**Value**: MEDIUM - Code quality, clarity

**Remaining TODOs**: 2 (down from 3)

#### TODO #1: `interpreter.py` line 220
```python
# TODO: Properly construct lightlike vector for the chosen metric
```

**Context**: In `_get_lightlike_operator()` method
- Current implementation works for Minkowski metric (timelike coords)
- Uses placeholder zero vector for Euclidean metric
- Default metric is **Euclidean** (used in 100% of examples and most tests)

**Analysis**:
1. The function computes the OF operator which must be lightlike (||OF||² = 0)
2. For Minkowski metric (-,+,+,+): (1,1,0,...) gives norm = -1+1 = 0 ✅
3. For Euclidean metric (+,+,+,+): Only zero vector has norm = 0
4. Current implementation uses zero vector for Euclidean, which is correct

**Decision**: **RESOLVED - Document that current implementation is correct**
- For Euclidean metric, zero vector IS the only lightlike vector
- For Minkowski metric, (1,1,0,...) is correct
- No code change needed, just improve comments

**Action**:
- Update comment to explain why zero vector is used for Euclidean
- Remove TODO marker
- Add explanatory comment about lightlike vectors in each metric
- Estimated time: 15 minutes

---

#### TODO #2: `metric.py` line 195
```python
# TODO: Implement proper parallel transport for curved metrics
```

**Context**: In `parallel_transport()` method
- Used for transporting vectors along geodesics in curved space
- Current implementation returns unchanged vector (works for flat spaces)
- EigenScript currently only uses flat metrics (Euclidean and Minkowski)

**Analysis**:
1. Parallel transport is only needed for **curved** metrics
2. All current usage is with **flat** metrics:
   - Euclidean: Flat, positive definite
   - Minkowski: Flat, Lorentzian signature
3. For flat metrics, vectors remain unchanged under parallel transport ✅
4. Curved metrics (Schwarzschild, FLRW, etc.) are **not implemented** and **not planned** for Phase 5

**Decision**: **RESOLVED - Document as future enhancement (Phase 6+)**
- Current implementation is correct for all flat metrics
- Curved metrics are research/advanced feature, not needed for production
- Remove TODO, replace with explanatory comment
- Create GitHub issue for future tracking (Phase 6+)

**Action**:
- Update comment to explain flat vs curved metrics
- Remove TODO marker
- Document that curved metrics are future enhancement
- Add note about which metrics are currently supported
- Estimated time: 15 minutes

---

### Task 2.2: Documentation Consistency ⚡ DOING NEXT
**Priority**: HIGH  
**Effort**: 1 day  
**Value**: HIGH - Accuracy, professionalism

**Areas to Review**:

1. **Version Numbers**:
   - [ ] Check README.md version
   - [ ] Check pyproject.toml version
   - [ ] Check __init__.py __version__
   - [ ] Ensure all match

2. **Status Reporting**:
   - [ ] Update all docs to say: "Phase 4: 100% ✅, Phase 5: 30%+ ⚠️" (up from 20% after Week 1)
   - [ ] Test counts: 351 passing tests (up from 315)
   - [ ] Coverage: 78% (up from 65%)

3. **Feature Lists**:
   - [ ] Verify all claimed features work
   - [ ] Remove "coming soon" items that are done
   - [ ] Update roadmap with Week 1 completion

4. **Example Code**:
   - [ ] Test all examples in README (spot check)
   - [ ] Verify examples/ directory files work (they do - covered by tests)

**Success Criteria**:
- [ ] All version numbers consistent
- [ ] Status consistent across all docs
- [ ] Feature lists accurate
- [ ] Week 1 achievements documented in roadmap
- [ ] No outdated information

**Estimated Time**: 4-6 hours

---

### Task 2.3: Enhanced Error Messages (ASSESS FIRST)
**Priority**: MEDIUM  
**Effort**: 2-3 days IF needed  
**Value**: HIGH - Better UX

**Strategy**: 
1. First, **assess current error messages** by examining:
   - Error classes in the codebase
   - Test cases that check error messages
   - Example error outputs
2. Determine if enhancement is **actually needed** or if current errors are sufficient
3. If needed, prioritize most impactful improvements

**Will assess after completing Tasks 2.1 and 2.2**

---

## Implementation Order

### Day 1 (Today): Quick Wins
- [x] Analyze Week 1 completion status
- [x] Create Week 2 plan
- [ ] Resolve TODO #1 (interpreter.py) - 15 min
- [ ] Resolve TODO #2 (metric.py) - 15 min
- [ ] Create Week 2 progress document
- [ ] Update documentation consistency - version numbers
- [ ] Update documentation consistency - status reporting

### Day 2: Documentation Polish
- [ ] Finish documentation consistency checks
- [ ] Update roadmap with Week 1 achievements
- [ ] Assess error message quality
- [ ] Decision: Do we need error message enhancements?

### Day 3 (if needed): Error Messages
- [ ] Only if assessment shows clear gaps
- [ ] Focus on highest-impact improvements
- [ ] Add helpful suggestions for common mistakes

---

## Success Metrics

Week 2 complete when:
- [x] Week 1 completion documented
- [ ] All TODO comments resolved or tracked
- [ ] Documentation is accurate and consistent
- [ ] Error messages assessed (enhanced if needed)
- [ ] All 351 tests still passing
- [ ] Code quality high

---

## Notes

### Why Prioritizing TODO Resolution First
1. **Quick wins**: Only 2 TODOs, both can be resolved in 30 minutes
2. **Low risk**: Just documentation improvements, no code changes
3. **High confidence**: Clear analysis shows current implementation is correct
4. **Immediate impact**: Clean up code quality markers

### Why Documentation Next
1. **Important for users**: Accurate docs build trust
2. **Reflects Week 1 achievements**: Update metrics to show progress
3. **Moderate effort**: 4-6 hours of systematic checking
4. **Low risk**: Just text updates

### Why Error Messages Last
1. **Need assessment first**: May not need enhancement
2. **Higher risk**: Could affect UX if done wrong
3. **More effort**: 2-3 days if we do enhance
4. **Can defer to Week 3**: Not critical blocker

---

## Risk Assessment

**Low Risk Items** ✅:
- TODO resolution: Just improving comments
- Documentation updates: Text only
- All changes are non-functional

**Medium Risk Items** ⚠️:
- Error message enhancement: Could affect UX
- Mitigation: Assess carefully before implementing

**High Risk Items** ❌:
- None identified

---

## Timeline

- **Day 1**: TODO resolution + doc version updates (4-5 hours)
- **Day 2**: Finish doc updates + error message assessment (4-6 hours)
- **Day 3**: Error enhancements if needed (optional, 6-8 hours)

**Total**: 1-3 days depending on error message decision

---

## Next Steps

1. ✅ Complete this plan document
2. Resolve TODO #1 in interpreter.py
3. Resolve TODO #2 in metric.py  
4. Update documentation for consistency
5. Assess error message quality
6. Report progress

---

**Plan Status**: ✅ READY  
**Start Date**: 2025-11-19  
**Expected Completion**: 2025-11-21 (2-3 days)
