# What's Left To Do - Quick Reference

**Last Updated**: 2025-11-19  
**Current Status**: Phase 4 Complete (100%), Phase 5 In Progress (20%)

---

## TL;DR

EigenScript is **95% complete** with self-hosting working and 315 passing tests! 

**Main gaps**: CLI needs testing, standard library needs expansion, documentation website needed.

**Estimated time to production-ready**: 3-4 weeks

---

## Critical Issues (Fix First) 🔴

### 1. CLI Has No Test Coverage (Priority 1)
- **File**: `src/eigenscript/__main__.py` (132 lines, 0% coverage)
- **Problem**: CLI implementation exists but is completely untested
- **Impact**: Users can't confidently use EigenScript from command line
- **Fix**: Write 15-20 CLI tests covering:
  - File execution
  - REPL mode
  - Command-line arguments
  - Error handling
  - --measure-fs flag
- **Estimated time**: 2-3 days

### 2. Three Unused Modules (Priority 2)
- **Files**:
  - `src/eigenscript/runtime/builtins.py` (51 lines, 0%)
  - `src/eigenscript/runtime/eigencontrol.py` (88 lines, 0%)
  - `src/eigenscript/evaluator/unified_interpreter.py` (160 lines, 0%)
- **Problem**: 299 lines of code with no tests or usage
- **Fix**: For each module, either:
  - (A) Integrate and test, OR
  - (B) Remove if redundant/experimental
- **Estimated time**: 1-2 days per module (3-6 days total)

---

## Important Issues (Do Next) 🟡

### 3. Error Messages Need Improvement (Priority 3)
- **Current**: Basic error tracking exists
- **Needed**: More helpful messages with suggestions
- **Example**: "Unknown keyword 'og'. Did you mean 'of'?"
- **Estimated time**: 2-3 days

### 4. Test Coverage Below 70% (Priority 4)
- **Current**: 65% overall coverage
- **Target**: 70%+ for production
- **Focus areas**:
  - `interpreter.py` - 73% (needs 2% more)
  - `builtins.py` - 74% (needs 1% more)
- **Estimated time**: 1 day

### 5. Standard Library Missing Features (Priority 5)
- **Missing**:
  - File I/O (open, read, write, close)
  - JSON parsing/serialization
  - Date/time operations
  - Regular expressions
- **Reference**: See `docs/library_expansion_plan.md`
- **Estimated time**: 7-10 days total

---

## Nice-to-Have (Do Later) 🟢

### 6. Documentation Website (Priority 6)
- **Current**: Markdown docs in repo
- **Needed**: 
  - MkDocs or Sphinx site
  - Hosted on GitHub Pages
  - API reference
  - Interactive tutorials
- **Estimated time**: 5-7 days

### 7. Address TODO Comments (Priority 7)
- Found 3 TODOs in code:
  - `interpreter.py`: Lightlike vector construction
  - `unified_interpreter.py`: Function objects
  - `metric.py`: Parallel transport
- **Action**: Implement, document, or remove
- **Estimated time**: 1-2 days

---

## What's Already Complete ✅

### Core Language (100%)
- ✅ Lexer (251 lines, 96% coverage)
- ✅ Parser (401 lines, 81% coverage)
- ✅ LRVM backend (129 lines, 85% coverage)
- ✅ Interpreter (580 lines, 73% coverage)
- ✅ Control flow (IF/ELSE, LOOP)
- ✅ Arithmetic operators
- ✅ Function definitions and recursion
- ✅ Framework Strength (87% coverage)

### Advanced Features (100%)
- ✅ Interrogatives (WHO, WHAT, WHEN, WHERE, WHY, HOW)
- ✅ Semantic predicates (converged, stable, diverging, etc.)
- ✅ Self-aware computation
- ✅ Turing completeness
- ✅ Self-hosting (meta-circular evaluator)

### Standard Library (80%)
- ✅ 18 built-in functions
- ✅ Math library (11 functions)
- ✅ Higher-order functions (map, filter, reduce)
- ✅ List operations
- ✅ String operations

### Testing (100%)
- ✅ 315 passing tests
- ✅ 65% overall coverage
- ✅ 16 test modules

---

## Timeline

### Week 1: Critical Issues
- Day 1-2: Resolve documentation conflicts ✅
- Day 3-4: Test CLI thoroughly
- Day 5: Begin unused module cleanup

### Week 2: Quality
- Day 1-2: Finish unused module cleanup
- Day 3-4: Improve error messages
- Day 5: Increase test coverage

### Week 3: Features
- Day 1-2: File I/O
- Day 3: JSON support
- Day 4-5: Date/time operations

### Week 4: Documentation
- Day 1-3: Documentation website
- Day 4-5: Tutorials and guides

**Total**: 3-4 weeks to production-ready

---

## How to Help

### For New Contributors
Start with:
1. Write CLI tests (high priority, clear scope)
2. Add standard library functions (independent tasks)
3. Improve error messages (UX focused)

### For Experienced Contributors
Help with:
1. Investigate unused modules
2. Optimize interpreter performance
3. Design documentation website

### For Documentation Writers
Focus on:
1. API reference documentation
2. Tutorial content
3. Example programs
4. Getting started guide

---

## Success Metrics

Phase 5 complete when:
- [ ] CLI has >75% test coverage
- [ ] All unused modules resolved
- [ ] Overall coverage >70%
- [ ] File I/O working
- [ ] JSON support added
- [ ] Documentation website live

---

## Questions?

See `COMPLETION_PLAN.md` for comprehensive analysis and detailed task breakdown.

---

**Note**: Core language is stable and production-ready. Remaining work is polish, testing, and ecosystem development.
