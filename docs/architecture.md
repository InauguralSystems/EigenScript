# EigenScript Architecture

This document describes the internal architecture and implementation strategy of the EigenScript interpreter.

## Table of Contents

1. [Overview](#overview)
2. [Architecture Diagram](#architecture-diagram)
3. [Component Details](#component-details)
4. [Data Flow](#data-flow)
5. [Implementation Phases](#implementation-phases)
6. [Design Decisions](#design-decisions)

## Overview

EigenScript is implemented as a tree-walking interpreter with geometric semantic evaluation. The architecture consists of several key components:

1. **Lexer**: Tokenizes source code
2. **Parser**: Builds Abstract Syntax Tree (AST)
3. **Semantic Analyzer**: Converts AST to LRVM vectors
4. **Evaluator**: Executes geometric transformations
5. **Runtime**: Manages Framework Strength and convergence

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    EigenScript Source                    │
│                    (.eigs file)                          │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                       LEXER                              │
│  • Tokenization                                          │
│  • Keyword recognition (OF, IS, IF, LOOP, etc.)         │
│  • Literal parsing (numbers, strings, vectors)          │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼ Token Stream
┌─────────────────────────────────────────────────────────┐
│                       PARSER                             │
│  • Build AST from tokens                                 │
│  • Handle operator precedence                            │
│  • Validate syntax                                       │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼ Abstract Syntax Tree (AST)
┌─────────────────────────────────────────────────────────┐
│                  SEMANTIC ANALYZER                       │
│  • Convert AST nodes → LRVM vectors                     │
│  • Compute norms (||v||² via metric g)                  │
│  • Type inference (lightlike/spacelike/timelike)        │
│  • Scope resolution                                      │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼ LRVM Representation
┌─────────────────────────────────────────────────────────┐
│                     EVALUATOR                            │
│  • Execute geometric transformations                     │
│  • OF operator: metric contraction (x^T g y)            │
│  • IS operator: projection/binding                       │
│  • IF: norm-based branching                             │
│  • LOOP: geodesic iteration                             │
│  • DEFINE: timelike transformation creation             │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│                      RUNTIME                             │
│  • Framework Strength measurement                        │
│  • Convergence detection                                 │
│  • Environment/scope management                          │
│  • Built-in functions                                    │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼ Result + FS
┌─────────────────────────────────────────────────────────┐
│                       OUTPUT                             │
│  • Return value                                          │
│  • Framework Strength report                             │
│  • Error messages (if any)                               │
└─────────────────────────────────────────────────────────┘
```

## Component Details

### 1. Lexer (`src/eigenscript/lexer/`)

**Purpose**: Convert source text into tokens

**Key Classes**:
- `Token`: Represents a single token (type, value, position)
- `Tokenizer`: Main lexer class

**Token Types**:
```python
class TokenType(Enum):
    # Keywords
    OF = "OF"
    IS = "IS"
    IF = "IF"
    ELSE = "ELSE"
    LOOP = "LOOP"
    WHILE = "WHILE"
    DEFINE = "DEFINE"
    AS = "AS"
    RETURN = "RETURN"

    # Literals
    NUMBER = "NUMBER"
    STRING = "STRING"
    VECTOR = "VECTOR"
    NULL = "NULL"

    # Identifiers
    IDENTIFIER = "IDENTIFIER"

    # Punctuation
    COLON = ":"
    LPAREN = "("
    RPAREN = ")"
    COMMA = ","
    NEWLINE = "NEWLINE"
    INDENT = "INDENT"
    DEDENT = "DEDENT"

    # Special
    EOF = "EOF"
```

**Example**:
```eigenscript
x is 5
```
Tokens: `[IDENTIFIER("x"), IS, NUMBER(5), NEWLINE, EOF]`

### 2. Parser (`src/eigenscript/parser/`)

**Purpose**: Build Abstract Syntax Tree from tokens

**Key Classes**:
- `ASTNode`: Base class for all AST nodes
- `Parser`: Recursive descent parser

**AST Node Types**:
```python
class ASTNode:
    """Base class for AST nodes"""
    pass

class Assignment(ASTNode):
    def __init__(self, identifier, expression):
        self.identifier = identifier
        self.expression = expression

class Relation(ASTNode):  # OF operator
    def __init__(self, left, right):
        self.left = left
        self.right = right

class Conditional(ASTNode):  # IF statement
    def __init__(self, condition, if_block, else_block=None):
        self.condition = condition
        self.if_block = if_block
        self.else_block = else_block

class Loop(ASTNode):
    def __init__(self, condition, body):
        self.condition = condition
        self.body = body

class FunctionDef(ASTNode):
    def __init__(self, name, body):
        self.name = name
        self.body = body

class Literal(ASTNode):
    def __init__(self, value, literal_type):
        self.value = value
        self.literal_type = literal_type
```

**Parsing Algorithm**: Recursive descent with operator precedence

### 3. Semantic Analyzer (`src/eigenscript/semantic/`)

**Purpose**: Convert AST to geometric representation

**Key Components**:

#### LRVM Module (`lrvm.py`)
```python
import numpy as np

class LRVMVector:
    """Represents a vector in semantic space"""

    def __init__(self, coordinates: np.ndarray):
        self.coords = coordinates
        self.dimension = len(coordinates)

    def norm(self, metric: np.ndarray) -> float:
        """Compute ||v||² = v^T g v"""
        return float(self.coords.T @ metric @ self.coords)

    def signature_type(self, metric: np.ndarray) -> str:
        """Determine if lightlike/spacelike/timelike"""
        n = self.norm(metric)
        if abs(n) < 1e-10:
            return "lightlike"
        elif n > 0:
            return "spacelike"
        else:
            return "timelike"
```

#### Metric Module (`metric.py`)
```python
class MetricTensor:
    """Represents the metric tensor g"""

    def __init__(self, dimension: int):
        self.dimension = dimension
        self.g = self._initialize_metric()

    def _initialize_metric(self) -> np.ndarray:
        """Initialize metric tensor (default: identity for now)"""
        return np.eye(self.dimension)

    def contract(self, v1: LRVMVector, v2: LRVMVector) -> LRVMVector:
        """Compute x^T g y (the OF operation)"""
        result = v1.coords.T @ self.g @ v2.coords
        # Return as scalar embedded in LRVM space
        return LRVMVector(np.array([result]))
```

**AST → LRVM Conversion**:
```python
class LRVMConverter:
    """Converts AST nodes to LRVM vectors"""

    def __init__(self, metric: MetricTensor):
        self.metric = metric
        self.embedding_dim = metric.dimension

    def convert(self, node: ASTNode) -> LRVMVector:
        """Convert AST node to LRVM vector"""
        if isinstance(node, Literal):
            return self._embed_literal(node)
        elif isinstance(node, Relation):
            return self._evaluate_relation(node)
        # ... other node types
```

### 4. Evaluator (`src/eigenscript/evaluator/`)

**Purpose**: Execute geometric transformations

**Key Components**:

```python
class Interpreter:
    """Main interpreter class"""

    def __init__(self):
        self.metric = MetricTensor(dimension=768)
        self.converter = LRVMConverter(self.metric)
        self.environment = Environment()
        self.fs_tracker = FrameworkStrengthTracker()

    def evaluate(self, ast: ASTNode) -> LRVMVector:
        """Evaluate AST and return result"""
        if isinstance(ast, Assignment):
            return self._eval_assignment(ast)
        elif isinstance(ast, Relation):
            return self._eval_relation(ast)
        elif isinstance(ast, Conditional):
            return self._eval_conditional(ast)
        # ... other node types

    def _eval_relation(self, node: Relation) -> LRVMVector:
        """Evaluate OF operator: x of y → x^T g y"""
        left_vec = self.evaluate(node.left)
        right_vec = self.evaluate(node.right)
        return self.metric.contract(left_vec, right_vec)

    def _eval_conditional(self, node: Conditional) -> LRVMVector:
        """IF based on norm signature"""
        cond_vec = self.evaluate(node.condition)
        norm = cond_vec.norm(self.metric.g)

        if norm > 0:  # spacelike/timelike → true branch
            return self.evaluate(node.if_block)
        else:  # lightlike → false branch
            return self.evaluate(node.else_block)
```

### 5. Runtime (`src/eigenscript/runtime/`)

**Purpose**: Manage execution state and Framework Strength

```python
class Environment:
    """Manages variable bindings in LRVM space"""

    def __init__(self, parent=None):
        self.bindings = {}
        self.parent = parent

    def bind(self, name: str, vector: LRVMVector):
        """Create immutable binding"""
        self.bindings[name] = vector

    def lookup(self, name: str) -> LRVMVector:
        """Resolve variable"""
        if name in self.bindings:
            return self.bindings[name]
        elif self.parent:
            return self.parent.lookup(name)
        else:
            raise NameError(f"Undefined variable: {name}")

class FrameworkStrengthTracker:
    """Measures semantic convergence during execution"""

    def __init__(self):
        self.trajectory = []  # History of states

    def update(self, state: LRVMVector):
        """Add new state to trajectory"""
        self.trajectory.append(state)

    def compute_fs(self) -> float:
        """Compute Framework Strength (0 to 1)"""
        if len(self.trajectory) < 2:
            return 0.0

        # Measure convergence (simplified)
        recent_states = self.trajectory[-10:]
        variance = np.var([s.coords for s in recent_states])

        # FS inversely related to variance
        fs = 1.0 / (1.0 + variance)
        return float(fs)

    def has_converged(self, threshold=0.95) -> bool:
        """Check if eigenstate convergence achieved"""
        return self.compute_fs() >= threshold
```

## Data Flow

### Example: `x is 5`

1. **Lexer**: `"x is 5"` → `[IDENTIFIER("x"), IS, NUMBER(5)]`
2. **Parser**: Tokens → `Assignment(identifier="x", expression=Literal(5))`
3. **Semantic**: `Literal(5)` → `LRVMVector([0.5, 0.3, ..., 0.1])`  (768-dim)
4. **Evaluator**: Bind `"x"` to vector in environment
5. **Runtime**: Update FS tracker with new state

### Example: `z is x of y`

1. **Lexer**: Tokenize
2. **Parser**: `Assignment(identifier="z", expression=Relation(x, y))`
3. **Semantic**:
   - Lookup `x` → `v_x`
   - Lookup `y` → `v_y`
   - Compute `v_x^T g v_y` → `v_z`
4. **Evaluator**: Bind `"z"` to `v_z`
5. **Runtime**: Check norm signature, update FS

## Implementation Phases

### Phase 1: Minimal Core (Week 1) ✓ Current

**Goal**: Prove OF primitive works

- [ ] Lexer for OF, IS, literals
- [ ] Parser for simple expressions
- [ ] LRVM basic operations
- [ ] Metric tensor (identity matrix)
- [ ] Simple evaluator

**Test Case**:
```eigenscript
x is 5
y is 3
z is x of y
```

### Phase 2: Control Flow (Week 2-3)

**Goal**: Add IF, LOOP, DEFINE

- [ ] Conditional evaluation (norm-based)
- [ ] Loop with convergence detection
- [ ] Function definitions
- [ ] Function application via OF

### Phase 3: Framework Strength (Week 4)

**Goal**: Measure understanding

- [ ] FS computation
- [ ] Convergence detection
- [ ] Runtime monitoring
- [ ] Eigenstate reporting

### Phase 4: Optimization (Month 2)

**Goal**: Performance improvements

- [ ] Bytecode compilation
- [ ] Cached embeddings
- [ ] Optimized metric operations
- [ ] Parallel evaluation

## Design Decisions

### Why Python for Prototyping?

**Pros**:
- Fast development
- Rich scientific libraries (NumPy)
- Easy integration with ML models
- Good for proving concepts

**Cons**:
- Slower execution
- Not ideal for production

**Future**: Rewrite in Rust/C++ for performance

### Why Tree-Walking Interpreter?

**Pros**:
- Simple to implement
- Easy to debug
- Clear semantic mapping

**Cons**:
- Slower than bytecode VM
- No optimization passes

**Future**: Add compilation to bytecode

### Metric Tensor Representation

**Current**: Identity matrix (Euclidean metric)

**Future Options**:
1. **Learned metric**: Train from data
2. **User-defined**: Allow custom metrics
3. **Adaptive**: Adjust during execution

### LRVM Dimension

**Current**: 768 (BERT-sized embeddings)

**Considerations**:
- Larger = more expressive, slower
- Smaller = faster, less expressive
- Should match pretrained models

## Performance Considerations

### Bottlenecks

1. **Vector Operations**: Matrix multiplications in metric contractions
2. **Embedding Lookups**: Converting literals to LRVM
3. **FS Computation**: Tracking trajectory history

### Optimizations

1. **Caching**: Store computed embeddings
2. **Lazy Evaluation**: Don't compute norms until needed
3. **Sparse Metrics**: Use sparse matrices when possible
4. **JIT Compilation**: Compile hot paths

## Testing Strategy

### Unit Tests

- Lexer: Token recognition
- Parser: AST construction
- LRVM: Vector operations
- Metric: Contraction correctness
- Evaluator: Each primitive

### Integration Tests

- Full programs end-to-end
- Factorial, loops, conditionals
- Self-reference stability
- FS convergence

### Property Tests

- OF of OF = OF (idempotence)
- Norm signatures correct
- FS monotonically increases (in stable systems)

## Future Enhancements

1. **Standard Library**: Built-in functions
2. **FFI**: Interface with Python/C
3. **Debugger**: Step through geometric transformations
4. **Visualizer**: Display LRVM trajectories
5. **REPL**: Interactive interpreter
6. **Package Manager**: Import/export modules

## References

- [Specification](specification.md) - Language semantics
- [Getting Started](getting-started.md) - User guide
- [Examples](examples.md) - Sample programs

---

**Version**: 0.1
**Status**: Living document - updates as implementation progresses
