# EigenScript Consistency Issues - Quick Reference

**Total Issues Found:** 47  
**Files Requiring Changes:** 54  
**Estimated Time:** 8-12 hours

---

## 🔴 CRITICAL Issues (Do First)

1. **Version Mismatch**
   - `__init__.py`: 0.3.23 → 0.4.0
   - `docs/index.md`: 0.1.0-alpha → 0.4.0

2. **Repository URLs**
   - Replace `InauguralPhysicist` → `InauguralSystems` (all files)

3. **Missing File**
   - Create `requirements-dev.txt`

4. **Python Version**
   - Update all docs: 3.9 → 3.10

---

## 🟡 HIGH Priority Issues (Do Next)

5. **Duplicate Files**
   - `docs/contributing.md` → Reference to root

6. **Multiple Roadmaps**
   - Move `IMPROVEMENT_ROADMAP.md` → `docs/archive/`
   - Update `docs/roadmap.md` to reference

7. **Root Directory Clutter**
   - Move 9 files from root to `docs/` or `docs/archive/`

8. **Example Naming**
   - Rename 23 example files to consistent pattern
   - Update all references

---

## 🟢 MEDIUM Priority Issues (Do Later)

9. **Import Patterns**
   - Standardize across ~15 Python files

10. **Missing __all__**
    - Add to 3 __init__.py files

11. **Test Documentation**
    - Create `tests/README.md`

---

## 🔵 LOW Priority Issues (Nice to Have)

12. **Project Descriptions**
    - Unify across 3 files

13. **Badge Styles**
    - Standardize in 2 files

14. **Style Guide**
    - Create `docs/STYLE_GUIDE.md`

15. **Pre-commit Hooks**
    - Add `.pre-commit-config.yaml`

---

## Files by Category

### Version Files (2)
- `src/eigenscript/__init__.py`
- `docs/index.md`

### URL Changes (10+)
- `mkdocs.yml`
- All `*.md` files with GitHub links

### New Files (4)
- `requirements-dev.txt`
- `docs/archive/README.md`
- `tests/README.md`
- `docs/STYLE_GUIDE.md`

### Files to Move (9)
- `IMPROVEMENT_ROADMAP.md` → archive
- `PHASE3_3_COMPLETION.md` → archive
- `PHASE3_COMPLETION_STATUS.md` → archive
- `AI_DEVELOPMENT_SUMMARY.md` → archive
- `WORK_SESSION_SUMMARY.md` → archive
- `REVIEW_SUMMARY.md` → archive
- `QUICK_FIXES.md` → docs
- `KNOWN_ISSUES.md` → docs
- `ISSUE_REPORT.md` → docs
- `TEST_RESULTS.md` → docs

### Files to Rename (23 examples)
- `datetime_demo.eigs` → `demo_datetime.eigs`
- `math_showcase.eigs` → `demo_math.eigs`
- `factorial_simple.eigs` → `tutorial_factorial.eigs`
- (+ 20 more)

### Import Updates (~15 Python files)
- Various files in `src/eigenscript/`

---

## Quick Commands

### Check Version Consistency
```bash
grep -h "version" src/eigenscript/__init__.py pyproject.toml README.md
```

### Find Repository URL Issues
```bash
grep -r "InauguralPhysicist" --include="*.md" --include="*.yml" .
```

### Count Root MD Files
```bash
ls -1 *.md | wc -l
```

### Test After Changes
```bash
pytest tests/ -v
python -c "import eigenscript; print(eigenscript.__version__)"
```

---

## Priority Order

1. ✅ Fix versions (5 minutes)
2. ✅ Fix URLs (10 minutes with sed)
3. ✅ Create requirements-dev.txt (5 minutes)
4. ✅ Update Python version refs (10 minutes)
5. ✅ Reorganize root directory (1 hour)
6. ✅ Rename examples (2 hours with references)
7. ✅ Standardize imports (1 hour)
8. ✅ Add documentation (2 hours)
9. ✅ Polish and style guide (2 hours)

---

**Total Estimated Time:** 8-12 hours over 5 days

**Risk Level:** Low (mechanical changes, good test coverage)

**Confidence:** High (clear plan, incremental commits)
