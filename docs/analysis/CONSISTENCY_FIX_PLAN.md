# EigenScript Consistency Fix Plan

**Date:** December 3, 2025  
**Status:** Ready for Implementation  
**Estimated Effort:** 8-12 hours  
**Files to Modify:** 54 files

---

## Phase 1: Critical Fixes (Priority: IMMEDIATE)

### 1.1 Fix Version Number Inconsistencies 🔴

**Issue:** Version mismatch between pyproject.toml (0.4.0) and __init__.py (0.3.23)

**Files to Change:**
1. `/home/runner/work/EigenScript/EigenScript/src/eigenscript/__init__.py`
   - **Line 8:** Change `__version__ = "0.3.23"` to `__version__ = "0.4.0"`

2. `/home/runner/work/EigenScript/EigenScript/docs/index.md`
   - **Line 6:** Change version badge from `0.1.0-alpha` to `0.4.0`
   - Change: `[![Version](https://img.shields.io/badge/version-0.1.0--alpha-blue.svg)]`
   - To: `[![Version](https://img.shields.io/badge/version-0.4.0-blue.svg)]`

**Verification:**
```bash
# Run these commands to verify version consistency
grep -r "version.*=.*['\"]0\." src/eigenscript/__init__.py
grep -r "version.*0\." pyproject.toml
grep -r "Version.*badge.*version" README.md docs/index.md
```

**Expected Result:** All version references show `0.4.0`

---

### 1.2 Fix Repository URL Inconsistencies 🔴

**Issue:** Mixed use of InauguralPhysicist vs InauguralSystems organization name

**Decision:** Use `InauguralSystems` consistently (matches pyproject.toml and CHANGELOG.md)

**Files to Change:**

1. `/home/runner/work/EigenScript/EigenScript/mkdocs.yml`
   - **Line 6:** Change `repo_name: InauguralPhysicist/EigenScript`
   - To: `repo_name: InauguralSystems/EigenScript`
   - **Line 7:** Change `repo_url: https://github.com/InauguralPhysicist/EigenScript`
   - To: `repo_url: https://github.com/InauguralSystems/EigenScript`

2. `/home/runner/work/EigenScript/EigenScript/docs/index.md`
   - **Line 6:** Update repository URL in badge
   - **Line 192:** Change link from `InauguralPhysicist/EigenScript` to `InauguralSystems/EigenScript`

**Search and Replace Pattern:**
```bash
# Find all occurrences
grep -r "InauguralPhysicist" --include="*.md" --include="*.yml" --include="*.toml" .

# Recommended: Use sed for bulk replacement
find . -type f \( -name "*.md" -o -name "*.yml" -o -name "*.toml" \) -exec sed -i 's/InauguralPhysicist/InauguralSystems/g' {} +
```

**Verification:**
```bash
# Should return no results
grep -r "InauguralPhysicist" --include="*.md" --include="*.yml" --include="*.toml" .
```

---

### 1.3 Create Missing requirements-dev.txt 🔴

**Issue:** CONTRIBUTING.md references `requirements-dev.txt` but file doesn't exist

**Solution:** Create requirements-dev.txt with dev dependencies from pyproject.toml

**New File:** `/home/runner/work/EigenScript/EigenScript/requirements-dev.txt`

**Content:**
```text
# Development dependencies for EigenScript
# Install with: pip install -r requirements-dev.txt

# Testing
pytest>=7.4.0
pytest-cov>=4.1.0

# Code quality
black>=23.0.0
flake8>=6.0.0
mypy>=1.5.0

# Typing
typing-extensions>=4.7.0

# Pre-commit hooks (optional)
pre-commit>=3.0.0

# Documentation
mkdocs>=1.5.0
mkdocs-material>=9.0.0
```

**Also Update:** `/home/runner/work/EigenScript/EigenScript/CONTRIBUTING.md`
- **Line 49-50:** Keep references to requirements-dev.txt (now valid)

**Verification:**
```bash
pip install -r requirements-dev.txt
# Should install without errors
```

---

### 1.4 Update Python Version Requirements Consistently 🔴

**Issue:** Inconsistent minimum Python version (3.9 vs 3.10)

**Decision:** Use Python 3.10+ (matches pyproject.toml and numpy>=1.24.0 requirement)

**Files to Change:**

1. `/home/runner/work/EigenScript/EigenScript/CONTRIBUTING.md`
   - **Line 31:** Change "Python 3.9 or higher" to "Python 3.10 or higher"

2. `/home/runner/work/EigenScript/EigenScript/docs/contributing.md`
   - **Line 31:** Change "Python 3.9 or higher" to "Python 3.10 or higher"

3. `/home/runner/work/EigenScript/EigenScript/README.md`
   - Add explicit Python version requirement in Installation section
   - After line 66, add: `**Requires Python 3.10 or higher**`

**Verification:**
```bash
grep -r "Python 3\." --include="*.md" . | grep -i "require\|prerequisite"
```

---

## Phase 2: High Priority Fixes (Priority: SHORT-TERM)

### 2.1 Document Canonical vs Duplicate Files 🟡

**Issue:** CONTRIBUTING.md exists in both root and docs/ with identical content

**Solution:** Make root version canonical, docs version a symlink or reference

**Decision:** 
- Keep `/CONTRIBUTING.md` as canonical (GitHub convention)
- Make `/docs/contributing.md` reference the root file

**Files to Change:**

1. `/home/runner/work/EigenScript/EigenScript/docs/contributing.md`
   - Replace entire content with:
   ```markdown
   # Contributing to EigenScript

   Please see the main [CONTRIBUTING.md](../CONTRIBUTING.md) file in the repository root for contribution guidelines.

   This file is maintained at the repository root to follow GitHub conventions.
   ```

**Verification:**
```bash
# Check files are now different
diff CONTRIBUTING.md docs/contributing.md
```

---

### 2.2 Consolidate Roadmap Documents 🟡

**Issue:** Multiple roadmap files with unclear hierarchy

**Solution:** Establish clear hierarchy and purpose

**Recommended Structure:**
- `/ROADMAP.md` - Current, canonical roadmap (keep as-is, it's up to date)
- `/IMPROVEMENT_ROADMAP.md` - **MOVE TO** `/docs/archive/IMPROVEMENT_ROADMAP.md`
- `/docs/roadmap.md` - Should redirect to root ROADMAP.md

**Files to Change:**

1. Move improvement roadmap to archive:
   ```bash
   git mv IMPROVEMENT_ROADMAP.md docs/archive/IMPROVEMENT_ROADMAP.md
   ```

2. `/home/runner/work/EigenScript/EigenScript/docs/roadmap.md`
   - Replace content with:
   ```markdown
   # EigenScript Roadmap

   Please see the main [ROADMAP.md](../ROADMAP.md) file in the repository root for the current roadmap.

   For historical roadmaps and planning documents, see [docs/archive/](archive/).
   ```

**Create Archive Index:**

3. `/home/runner/work/EigenScript/EigenScript/docs/archive/README.md`
   - Create new file explaining archive organization:
   ```markdown
   # Documentation Archive

   This directory contains historical planning documents and outdated roadmaps for reference.

   ## Current Status

   For current documentation, see the main docs/ directory and repository root.

   ## Archive Contents

   ### Roadmaps and Planning
   - `CONSOLIDATED_ROADMAP.md` - Historical consolidated planning
   - `HONEST_ROADMAP.md` - Early project planning
   - `IMPROVEMENT_ROADMAP.md` - Moved from root (historical)
   - `PRODUCTION_ROADMAP.md` - Production readiness planning
   - `ROADMAP_*.md` - Various historical roadmap versions

   ### Week-by-Week Reports
   - `WEEK1_COMPLETION_SUMMARY.md`
   - `WEEK2_*.md` - Week 2 planning and completion
   - `WEEK3_*.md` - Week 3 implementation
   - `WEEK4_*.md` - Week 4 completion

   ### Technical Analysis
   - `BENCHMARK_RESULTS.md` - Performance benchmarks
   - `COMPILER_REVIEW.md` - Compiler architecture review
   - `SECURITY_AUDIT.md` - Security analysis
   - `STACK_OPTIMIZATION_SUMMARY.md` - Optimization work

   ### Other
   - `ANALYSIS_SUMMARY.md`
   - `COMPLETION_PLAN.md`
   - `ERROR_MESSAGE_ASSESSMENT.md`
   - `FINISHING_WORK.md`
   - `INTEGRATION_SUMMARY.md`
   - `PLANNING_INDEX.md`
   - `PROJECT_STATUS_SUMMARY.md`
   - `QUICK_FIX_GUIDE.md`
   - `THEORETICAL_FOUNDATIONS.md`
   - `UNUSED_MODULES_CLEANUP.md`
   ```

**Verification:**
```bash
ls -la docs/archive/ | wc -l  # Should show 32 files (31 + README)
```

---

### 2.3 Reorganize Root Directory Markdown Files 🟡

**Issue:** 16 MD files in root with no clear organization

**Current Root MD Files:**
- `AI_DEVELOPMENT_SUMMARY.md`
- `CHANGELOG.md`
- `CODE_OF_CONDUCT.md`
- `CONTRIBUTING.md`
- `IMPROVEMENT_ROADMAP.md` ← Move to archive
- `ISSUE_REPORT.md`
- `KNOWN_ISSUES.md`
- `PHASE3_3_COMPLETION.md` ← Move to docs/
- `PHASE3_COMPLETION_STATUS.md` ← Move to docs/
- `QUICK_FIXES.md` ← Move to docs/
- `README.md`
- `REVIEW_SUMMARY.md` ← Move to docs/
- `ROADMAP.md`
- `SECURITY.md`
- `TEST_RESULTS.md` ← Move to docs/
- `WORK_SESSION_SUMMARY.md` ← Move to docs/

**Recommended Final Root Structure (GitHub Standard):**
- `README.md` ✅ Keep
- `CHANGELOG.md` ✅ Keep
- `CONTRIBUTING.md` ✅ Keep
- `CODE_OF_CONDUCT.md` ✅ Keep
- `SECURITY.md` ✅ Keep
- `ROADMAP.md` ✅ Keep
- `LICENSE` ✅ Keep

**Files to Move:**

```bash
# Move phase completion docs
git mv PHASE3_3_COMPLETION.md docs/archive/
git mv PHASE3_COMPLETION_STATUS.md docs/archive/

# Move development summaries
git mv AI_DEVELOPMENT_SUMMARY.md docs/archive/
git mv WORK_SESSION_SUMMARY.md docs/archive/
git mv REVIEW_SUMMARY.md docs/archive/

# Move operational docs to docs/
git mv QUICK_FIXES.md docs/
git mv KNOWN_ISSUES.md docs/
git mv ISSUE_REPORT.md docs/
git mv TEST_RESULTS.md docs/
```

**Update References:**

After moving, search and update any internal links:
```bash
grep -r "PHASE3_COMPLETION_STATUS.md" --include="*.md" .
grep -r "QUICK_FIXES.md" --include="*.md" .
grep -r "KNOWN_ISSUES.md" --include="*.md" .
```

---

### 2.4 Standardize Example File Naming 🟡

**Issue:** Inconsistent naming patterns for example files

**Current Patterns:**
- `*_demo.eigs` (8 files)
- `*_showcase.eigs` (3 files)
- `*_complete.eigs` (2 files)
- `*_simple.eigs` (2 files)
- `*_v2.eigs`, `*_v3.eigs` (versioned)
- Plain names (many files)

**Recommended Standard:**
- **Tutorial/Learning:** `tutorial_<name>.eigs` (for step-by-step learning)
- **Feature Demo:** `demo_<feature>.eigs` (for showing specific features)
- **Complete Example:** `example_<name>.eigs` (for real-world examples)
- **Basic/Simple:** No suffix, just the name
- **Versions:** Keep `_v2`, `_v3` for evolutionary examples

**Proposed Renames:**

```bash
# In examples/
cd /home/runner/work/EigenScript/EigenScript/examples

# Demos - standardize to demo_ prefix
mv datetime_demo.eigs demo_datetime.eigs
mv json_demo.eigs demo_json.eigs
mv file_io_demo.eigs demo_file_io.eigs
mv statistics_demo.eigs demo_statistics.eigs
mv temporal_demo.eigs demo_temporal.eigs
mv ai_ml_demo.eigs demo_ai_ml.eigs
mv enhanced_lists_demo.eigs demo_enhanced_lists.eigs

# Showcases - convert to demo_
mv math_showcase.eigs demo_math.eigs
mv interrogatives_showcase.eigs demo_interrogatives.eigs
mv smart_iteration_showcase.eigs demo_smart_iteration.eigs

# Complete versions - add example_ prefix
mv if_then_else_complete.eigs example_if_then_else.eigs
mv meta_eval_complete.eigs example_meta_eval.eigs

# Simple versions - add tutorial_ prefix
mv factorial_simple.eigs tutorial_factorial.eigs
mv meta_eval_simple.eigs tutorial_meta_eval.eigs

# Keep these as-is (good names):
# - hello_world.eigs
# - factorial.eigs
# - core_operators.eigs
# - higher_order_functions.eigs
# - list_operations.eigs
# - matrix_operations.eigs
# - transformer_basics.eigs
# - cnn_basics.eigs
# - advanced_ai_integration.eigs

# Keep versioned files as-is:
# - meta_eval_v2.eigs
# - semantic_llm_v2.eigs
# - semantic_llm_v3.eigs
```

**Update Documentation References:**

After renaming, update references in:
- `README.md`
- `docs/examples/*.md`
- `tests/test_examples.py`
- Any tutorial files

```bash
# Find all references
grep -r "datetime_demo.eigs" --include="*.md" --include="*.py" .
grep -r "math_showcase.eigs" --include="*.md" --include="*.py" .
# ... etc for each renamed file
```

---

## Phase 3: Medium Priority Fixes (Priority: MEDIUM-TERM)

### 3.1 Standardize Import Patterns 🟢

**Issue:** Mixed import styles across codebase

**Recommended Standard:**
```python
# 1. Standard library imports
import os
import sys
from typing import Optional, List

# 2. Third-party imports
import numpy as np
from llvmlite import ir

# 3. Local application imports (absolute)
from eigenscript.lexer import Tokenizer, Token, TokenType
from eigenscript.parser import Parser, ASTNode
from eigenscript.evaluator import Interpreter

# 4. Type-checking imports
from typing import TYPE_CHECKING
if TYPE_CHECKING:
    from eigenscript.semantic.lrvm import LRVMVector
```

**Files Requiring Import Standardization:**

Run this to identify files with non-standard imports:
```bash
# Find files importing from eigenscript.lexer.tokenizer (should use eigenscript.lexer)
grep -r "from eigenscript\\.lexer\\.tokenizer import" --include="*.py" src/

# Find files with relative imports
grep -r "from \\.\\. import" --include="*.py" src/
```

**Automated Fix Script:**

Create `/tmp/fix_imports.py`:
```python
#!/usr/bin/env python3
"""Fix import patterns in EigenScript codebase."""

import os
import re
from pathlib import Path

def fix_imports(file_path):
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Fix: from eigenscript.lexer.tokenizer import -> from eigenscript.lexer import
    content = re.sub(
        r'from eigenscript\.lexer\.tokenizer import',
        'from eigenscript.lexer import',
        content
    )
    
    # Fix: from eigenscript.parser.ast_builder import Parser -> from eigenscript.parser import Parser
    content = re.sub(
        r'from eigenscript\.parser\.ast_builder import (Parser(?:, )?)',
        r'from eigenscript.parser import \1',
        content
    )
    
    with open(file_path, 'w') as f:
        f.write(content)

# Run on all Python files
for py_file in Path('src').rglob('*.py'):
    fix_imports(py_file)
    print(f"Fixed: {py_file}")
```

---

### 3.2 Add __all__ Definitions 🟢

**Issue:** Inconsistent __all__ definitions make API unclear

**Files Needing __all__:**

1. `/home/runner/work/EigenScript/EigenScript/src/eigenscript/compiler/__init__.py`
   ```python
   """
   EigenScript Compiler Module
   
   Provides LLVM-based native code generation.
   """
   
   __all__ = []  # Currently empty, compilation is done via CLI
   ```

2. `/home/runner/work/EigenScript/EigenScript/src/eigenscript/compiler/codegen/__init__.py`
   ```python
   """
   Code generation module for EigenScript compiler.
   """
   
   from eigenscript.compiler.codegen.llvm_backend import LLVMCodeGenerator
   
   __all__ = ["LLVMCodeGenerator"]
   ```

3. `/home/runner/work/EigenScript/EigenScript/src/eigenscript/compiler/cli/__init__.py`
   ```python
   """
   Command-line interface for EigenScript compiler.
   """
   
   __all__ = []  # CLI entry points are defined in compile.py
   ```

**Verification:**
```bash
# Check all __init__.py files have __all__
for file in $(find src/ -name "__init__.py"); do
    if ! grep -q "__all__" "$file"; then
        echo "Missing __all__: $file"
    fi
done
```

---

### 3.3 Standardize Test Structure Documentation 🟢

**Issue:** No clear documentation on test organization

**Create:** `/home/runner/work/EigenScript/EigenScript/tests/README.md`

```markdown
# EigenScript Test Suite

This directory contains the comprehensive test suite for EigenScript.

## Structure

### Root Tests (`/tests/`)

Main test files for core functionality:

- `test_lexer.py` - Tokenization tests
- `test_parser.py` - Parsing and AST construction
- `test_evaluator.py` - Interpreter execution tests
- `test_builtins.py` - Built-in function tests
- `test_<feature>.py` - Feature-specific tests

### Compiler Tests (`/tests/compiler/`)

Tests for the LLVM compiler:

- `test_codegen.py` - LLVM IR generation
- `test_module_vs_program.py` - Module compilation
- `test_module_init_calls.py` - Module initialization

### Test Packages (`/tests/test_packages/`)

Sample packages for module system testing:

- `mathlib/` - Math library example
- `mypackage/` - Generic package example
- `shapes/` - Geometry package example

## Running Tests

### All Tests
```bash
pytest
```

### Specific Test File
```bash
pytest tests/test_lexer.py
```

### With Coverage
```bash
pytest --cov=eigenscript --cov-report=html
```

### Verbose Output
```bash
pytest -v
```

## Test Naming Conventions

- Test files: `test_<feature>.py`
- Test classes: `Test<Feature>`
- Test methods: `test_<specific_behavior>`

## Writing New Tests

1. Create test file following naming convention
2. Use pytest fixtures for common setup
3. Add docstrings explaining test purpose
4. Test both success and error cases
5. Aim for >80% code coverage

Example:
```python
import pytest
from eigenscript.lexer import Tokenizer

class TestLexer:
    """Test suite for lexer functionality."""
    
    def test_tokenize_simple_assignment(self):
        """Simple assignment should produce correct tokens."""
        lexer = Tokenizer("x is 42")
        tokens = lexer.tokenize()
        
        assert len(tokens) == 3
        assert tokens[0].type == "IDENTIFIER"
        assert tokens[1].type == "IS"
        assert tokens[2].type == "NUMBER"
```

## Current Coverage

Run `pytest --cov=eigenscript` to see current coverage.

Target: >80% overall coverage
```

---

## Phase 4: Low Priority Fixes (Priority: LONG-TERM)

### 4.1 Unify Project Descriptions 🔵

**Issue:** Three different project descriptions

**Recommended Canonical Description:**

"EigenScript is a high-performance geometric programming language where code is treated as a trajectory through semantic spacetime, combining native compilation with geometric introspection."

**Files to Update:**

1. `/home/runner/work/EigenScript/EigenScript/pyproject.toml`
   - **Line 8:** Update description field

2. `/home/runner/work/EigenScript/EigenScript/README.md`
   - **Line 6:** Consider updating subtitle

3. `/home/runner/work/EigenScript/EigenScript/docs/index.md`
   - **Line 3:** Update description

**Keep Variations for Different Contexts:**
- **Short tagline:** "The Geometric Systems Language"
- **Medium description:** "A high-performance geometric programming language"
- **Long description:** Full description above

---

### 4.2 Standardize Badge Styles 🔵

**Issue:** Inconsistent badge formatting

**Recommended Standard:**
```markdown
![Build Status](https://img.shields.io/badge/build-passing-brightgreen)
![Version](https://img.shields.io/badge/version-v0.4.0-blue)
![License](https://img.shields.io/badge/license-MIT-yellow)
![Python](https://img.shields.io/badge/python-3.10+-blue)
```

**Files to Update:**
- `/home/runner/work/EigenScript/EigenScript/README.md` (lines 11-13)
- `/home/runner/work/EigenScript/EigenScript/docs/index.md` (line 6)

---

### 4.3 Create Comprehensive Style Guide 🔵

**Create:** `/home/runner/work/EigenScript/EigenScript/docs/STYLE_GUIDE.md`

```markdown
# EigenScript Style Guide

## Version Numbers

- Format: `X.Y.Z` (without 'v' prefix in code)
- Format: `vX.Y.Z` (with 'v' prefix in tags and user-facing text)
- Update locations: `pyproject.toml`, `src/eigenscript/__init__.py`, `README.md`

## File Naming

### Python Files
- Modules: `snake_case.py`
- Tests: `test_<feature>.py`
- Classes: `PascalCase`
- Functions: `snake_case`

### EigenScript Examples
- Demos: `demo_<feature>.eigs`
- Tutorials: `tutorial_<name>.eigs`
- Examples: `example_<name>.eigs`
- Simple: `<name>.eigs`

### Documentation
- Root docs: `ALLCAPS.md` (GitHub conventions)
- Docs folder: `lowercase-with-hyphens.md`
- Exceptions: Phase docs use `PHASE<N>_<NAME>.md`

## Import Order

1. Standard library
2. Third-party packages
3. Local application imports (absolute paths)
4. TYPE_CHECKING imports

## Documentation

### Docstrings
- Use Google style
- Include examples for complex functions
- Document all public APIs

### Markdown
- Use ATX-style headers (`#` not `===`)
- 4-space indentation for code blocks
- Use fenced code blocks with language tags

## Testing

- Use pytest
- Test classes for related tests
- Standalone functions for simple tests
- Aim for >80% coverage

## Git Commits

Format:
```
<type>(<scope>): <subject>

<body>

<footer>
```

Types: feat, fix, docs, style, refactor, test, chore
```

---

### 4.4 Add Pre-commit Hooks 🔵

**Create:** `/home/runner/work/EigenScript/EigenScript/.pre-commit-config.yaml`

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.5.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-added-large-files
      - id: check-merge-conflict
      
  - repo: https://github.com/psf/black
    rev: 23.12.1
    hooks:
      - id: black
        language_version: python3.10
        
  - repo: https://github.com/pycqa/flake8
    rev: 7.0.0
    hooks:
      - id: flake8
        args: ['--max-line-length=88', '--extend-ignore=E203']
        
  - repo: https://github.com/pre-commit/mirrors-mypy
    rev: v1.8.0
    hooks:
      - id: mypy
        additional_dependencies: [types-all]
```

**Setup Instructions in CONTRIBUTING.md:**
```bash
pip install pre-commit
pre-commit install
```

---

## Implementation Checklist

### Phase 1: Critical (Do First)
- [ ] Update `__init__.py` version to 0.4.0
- [ ] Update `docs/index.md` version to 0.4.0
- [ ] Replace all InauguralPhysicist with InauguralSystems
- [ ] Create `requirements-dev.txt`
- [ ] Update Python version to 3.10+ in all docs

### Phase 2: High Priority (Do Next)
- [ ] Make `docs/contributing.md` reference root `CONTRIBUTING.md`
- [ ] Move `IMPROVEMENT_ROADMAP.md` to archive
- [ ] Update `docs/roadmap.md` to reference root
- [ ] Create `docs/archive/README.md`
- [ ] Move phase docs to `docs/archive/`
- [ ] Move dev summary docs to `docs/archive/`
- [ ] Move operational docs to `docs/`
- [ ] Rename example files (23 files)
- [ ] Update all references to renamed files

### Phase 3: Medium Priority (Do When Time Permits)
- [ ] Standardize import patterns (run script)
- [ ] Add missing `__all__` definitions (3 files)
- [ ] Create `tests/README.md`

### Phase 4: Low Priority (Nice to Have)
- [ ] Unify project descriptions (3 files)
- [ ] Standardize badge styles (2 files)
- [ ] Create `docs/STYLE_GUIDE.md`
- [ ] Add `.pre-commit-config.yaml`
- [ ] Update CONTRIBUTING.md with pre-commit instructions

---

## Testing Strategy

After each phase:

1. **Version Check:**
   ```bash
   python -c "import eigenscript; print(eigenscript.__version__)"
   grep version pyproject.toml
   ```

2. **Link Check:**
   ```bash
   # Check for broken internal links
   grep -r "\[.*\](.*/.*\.md)" --include="*.md" . | grep -v "http"
   ```

3. **Import Check:**
   ```bash
   python -c "from eigenscript import *; print('Imports OK')"
   ```

4. **Test Suite:**
   ```bash
   pytest tests/ -v
   # Should still have 665+ passing tests
   ```

5. **Example Files:**
   ```bash
   python -m eigenscript examples/hello_world.eigs
   python -m eigenscript examples/demo_datetime.eigs
   # Test renamed files work
   ```

---

## Rollout Plan

### Day 1: Critical Fixes
- Morning: Version numbers and repository URLs (1-2 hours)
- Afternoon: Create requirements-dev.txt, update Python versions (1 hour)
- Test: Run full test suite

### Day 2: Documentation Reorganization
- Morning: Move files to archive, create index (2 hours)
- Afternoon: Update roadmap references (1 hour)
- Test: Check all internal links

### Day 3: Example File Renaming
- Morning: Rename files (30 minutes)
- Afternoon: Update all references (3-4 hours)
- Test: Run example tests

### Day 4: Import Standardization
- Morning: Run import fix script (1 hour)
- Afternoon: Add __all__ definitions (1 hour)
- Test: Full test suite and import checks

### Day 5: Polish and Verification
- Morning: Create style guide and test docs (2 hours)
- Afternoon: Pre-commit hooks, final checks (2 hours)
- Test: Complete end-to-end verification

---

## Risk Mitigation

### Backup Strategy
```bash
# Before starting, create a backup branch
git checkout -b backup-before-consistency-fixes
git push origin backup-before-consistency-fixes

# Create working branch
git checkout -b consistency-fixes
```

### Rollback Plan
If issues arise:
```bash
git checkout main
git reset --hard backup-before-consistency-fixes
```

### Incremental Commits
Make separate commits for each major change:
- "fix: update version to 0.4.0 across all files"
- "refactor: standardize repository URLs to InauguralSystems"
- "chore: create requirements-dev.txt for development setup"
- "docs: reorganize root directory markdown files"
- "refactor: rename example files to consistent naming pattern"
- "style: standardize import patterns across codebase"

---

## Success Criteria

✅ **Phase 1 Complete When:**
- All version numbers show 0.4.0
- All URLs use InauguralSystems
- requirements-dev.txt exists and works
- Python 3.10+ documented everywhere

✅ **Phase 2 Complete When:**
- Root directory has only 7 standard MD files
- Archive is organized with README
- All roadmap references point to canonical file
- All internal links work

✅ **Phase 3 Complete When:**
- Import patterns follow standard
- All __init__.py have __all__
- Test organization is documented

✅ **Phase 4 Complete When:**
- Style guide exists
- Pre-commit hooks configured
- Badge styles consistent
- Descriptions unified

✅ **Overall Success When:**
- All 665+ tests still pass
- No broken internal links
- Documentation builds without warnings
- All example files run successfully
- CI pipeline passes

---

**Plan created by:** GitHub Copilot Agent  
**Estimated completion:** 5 days (8-12 hours total)  
**Confidence:** High - Changes are mechanical and low-risk
