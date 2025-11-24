# EigenScript Syntax Demonstrations

This directory contains EigenScript code examples that demonstrate **syntax features** that are not yet fully implemented in the runtime.

These files are used to:
- Test parser correctness
- Document planned language features
- Demonstrate the syntax for future implementations

**Note**: These examples may not execute successfully with the current interpreter, but they should parse correctly.

## Current Demos

### module_demo.eigs
Demonstrates the Module System syntax (Phase 4):
- `import` statements
- Module member access with `.` operator
- Import aliases with `as` keyword

This syntax is **parser-ready** but awaits compiler/interpreter implementation.
