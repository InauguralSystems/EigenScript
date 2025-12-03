# Continue Statement Implementation Proposal

## Overview

This document proposes adding a `continue` statement to EigenScript, inspired by the blank line handling pattern implemented in the parser fix (PR #[number]).

## Current State

EigenScript currently supports:
- ✅ `break` - Exit from loop early
- ❌ `continue` - Skip to next iteration (not implemented)

## Motivation

The blank line handling fix in `parser.eigs` demonstrates exactly how `continue` would work:

### Current Pattern (Blank Line Handling)
```eigenscript
loop while 1:
    tok is current_token_type of 0
    
    if tok = TT_NEWLINE:
        result is advance_token of 0  # Skip and continue to next iteration
    else:
        stmt is parse_statement of 0  # Process statement
```

This is equivalent to:
```python
while True:
    tok = current_token_type()
    
    if tok == TT_NEWLINE:
        advance_token()
        continue  # Skip to next iteration
    
    stmt = parse_statement()
```

## Proposed Implementation

### 1. Lexer Changes

Add `CONTINUE` token type to `src/eigenscript/lexer/tokenizer.py`:

```python
class TokenType(Enum):
    # ... existing tokens ...
    BREAK = "BREAK"
    CONTINUE = "CONTINUE"  # NEW
    # ... rest ...
```

Add to keyword mapping:
```python
KEYWORDS = {
    # ... existing keywords ...
    "break": TokenType.BREAK,
    "continue": TokenType.CONTINUE,  # NEW
    # ... rest ...
}
```

### 2. Parser Changes

#### Self-Hosted Parser (`parser.eigs`)

Add token constant:
```eigenscript
TT_CONTINUE is 11  # Next available token number
```

Add AST node type:
```eigenscript
AST_CONTINUE is 26  # Next available AST type
```

Add to `parse_statement`:
```eigenscript
# CONTINUE - continue statement
if tok = TT_CONTINUE:
    result is advance_token of 0
    # Skip optional newline
    tok is current_token_type of 0
    if tok = TT_NEWLINE:
        result is advance_token of 0
    
    node is create_node of AST_CONTINUE
    return node
```

#### Reference Parser (`ast_builder.py`)

Add AST node class:
```python
@dataclass
class Continue(ASTNode):
    """
    Represents a continue statement.
    
    Example:
        continue
    """
    
    def __repr__(self) -> str:
        return "Continue()"
```

Add to `parse_statement`:
```python
elif self.current_token().type == TokenType.CONTINUE:
    self.advance()
    # Skip optional newline
    if self.current_token() and self.current_token().type == TokenType.NEWLINE:
        self.advance()
    return Continue()
```

### 3. Interpreter Changes

Add to `src/eigenscript/evaluator/interpreter.py`:

```python
# Add Continue exception for control flow
class ContinueException(Exception):
    """Raised when continue statement is encountered."""
    pass

# In _eval_statement method
elif isinstance(node, Continue):
    raise ContinueException()

# In _eval_loop method, wrap body execution:
try:
    # Execute loop body
    for stmt in node.body:
        self._eval_statement(stmt)
except ContinueException:
    continue  # Skip to next iteration
except BreakException:
    break  # Exit loop
```

### 4. Compiler (LLVM) Changes

Add to `src/eigenscript/compiler/codegen/llvm_backend.py`:

```python
def emit_continue(self, node: Continue) -> None:
    """Emit LLVM IR for continue statement."""
    if not self.current_loop_continue_label:
        raise CompilerError("Continue statement outside of loop")
    
    # Branch to the loop condition check (continue label)
    self.builder.branch(self.current_loop_continue_label)
    
    # Create unreachable block after continue
    unreachable_block = self.builder.append_basic_block("after_continue")
    self.builder.position_at_end(unreachable_block)
```

Track continue labels in loop emission:
```python
def emit_loop(self, node: Loop) -> None:
    # ... existing code ...
    
    # Store continue label for nested continues
    old_continue_label = self.current_loop_continue_label
    self.current_loop_continue_label = cond_block  # Or start of next iteration
    
    # ... emit loop body ...
    
    # Restore old continue label
    self.current_loop_continue_label = old_continue_label
```

### 5. Semantic Analysis

Add to `src/eigenscript/compiler/analysis/resolver.py`:

```python
def visit_continue(self, node: Continue) -> None:
    """Validate continue statement is inside a loop."""
    if not self.in_loop:
        self.error(node, "Continue statement outside of loop")
```

## Usage Examples

### Basic Continue
```eigenscript
i is 0
sum is 0

loop while i < 10:
    i is i + 1
    
    if i = 5:
        continue  # Skip when i is 5
    
    sum is sum + i

print of sum  # Output: 50 (1+2+3+4+6+7+8+9+10)
```

### With Blank Lines (Thanks to Parser Fix!)
```eigenscript
define process of items as:
    result is []
    i is 0
    
    loop while i < length of items:
        item is items[i]
        i is i + 1
        
        if item < 0:
            continue  # Skip negative items
        
        append of result of item
    
    return result
```

### Nested Loops
```eigenscript
x is 0
loop while x < 3:
    y is 0
    loop while y < 3:
        y is y + 1
        
        if y = 2:
            continue  # Continue inner loop only
        
        print of [x, y]
    
    x is x + 1
```

## Benefits

1. **More Expressive**: Natural way to skip iterations
2. **Cleaner Code**: Avoid nested if-else or flag variables
3. **Pattern Match**: Already proven by blank line handling fix
4. **Consistency**: Python, C, Java, etc. all have `continue`
5. **Self-Hosting**: Makes parser code more readable

## Implementation Effort

- **Lexer**: ~10 lines (token type + keyword)
- **Parser (Python)**: ~15 lines (AST node + parse logic)
- **Parser (EigenScript)**: ~20 lines (constants + parse logic)
- **Interpreter**: ~20 lines (exception + handling)
- **Compiler**: ~30 lines (LLVM IR emission)
- **Semantic**: ~10 lines (validation)
- **Tests**: ~50 lines (unit + integration)

**Total**: ~155 lines of code, ~2-4 hours of work

## Testing Plan

1. **Unit Tests**:
   - Continue in simple loop
   - Continue in nested loop
   - Continue with conditions
   - Error: Continue outside loop

2. **Integration Tests**:
   - Continue with interrogatives
   - Continue with blank lines (parser fix!)
   - Continue in compiled code (LLVM)
   - Continue in interpreted code

3. **Self-Hosting Test**:
   - Use continue in parser.eigs to simplify logic
   - Verify bootstrap still works

## Connection to Parser Fix

The blank line handling pattern IS continue:

```eigenscript
# Current workaround (if-else)
if condition:
    advance_and_skip_to_next_iteration of 0
else:
    process_normal_case of 0
```

```eigenscript
# With continue (cleaner)
if condition:
    continue

process_normal_case of 0
```

The parser fix proves the control flow pattern works correctly in EigenScript!

## Recommendation

Implement `continue` statement using the blank line handling pattern as a template. The parser fix demonstrates the pattern works correctly and provides a solid foundation for this feature.

## References

- Parser fix PR: Blank line handling in `parse_block`
- Similar implementations: Python, C, Java, JavaScript
- EigenScript break statement: Already implemented
