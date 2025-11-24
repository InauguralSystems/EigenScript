# EigenScript Library Expansion Plan

**Created**: 2025-11-18  
**Status**: Planning Document  
**Version**: 1.0

---

## Executive Summary

This document provides a comprehensive analysis and prioritized plan for expanding EigenScript's standard library. Based on analysis of the current implementation, roadmap, and the geometric/semantic nature of the language, we identify critical gaps and propose a structured approach to library development.

---

## 1. Current State Analysis

### 1.1 Existing Built-in Functions (18 total)

**I/O Functions (2)**
- `print` - Output to stdout
- `input` - Read from stdin

**Collection Operations (9)**
- `len` - Get length/magnitude
- `range` - Generate sequences
- `append` - Add element to list
- `pop` - Remove last element
- `min` - Find minimum value
- `max` - Find maximum value
- `sort` - Sort list
- `split` - Split string into list
- `join` - Join list into string

**Higher-Order Functions (3)**
- `map` - Transform each element
- `filter` - Select matching elements
- `reduce` - Fold/accumulate values

**Type/Introspection (2)**
- `type` - Get type information
- `norm` - Get geometric norm

**String Operations (2)**
- `upper` - Convert to uppercase
- `lower` - Convert to lowercase

### 1.2 Current Capabilities

✅ **Strong Areas**:
- Higher-order functional programming (map, filter, reduce)
- Basic list operations
- String manipulation basics
- Type introspection
- Geometric primitives

❌ **Missing Areas**:
- Mathematical operations (beyond basic arithmetic)
- File I/O
- Advanced string operations
- Collection manipulation
- Error handling utilities
- Geometric/semantic utilities
- Date/time operations
- Regular expressions

---

## 2. What "Expand Libraries" Means for EigenScript

Given EigenScript's unique positioning as a **geometric programming language with semantic spacetime**, library expansion must consider:

### 2.1 Dual Nature Requirements

**Traditional Programming Needs**:
- Users need familiar standard library functions (math, strings, I/O)
- Common patterns should be easy to express
- Interoperability with existing ecosystems

**Geometric/Semantic Extensions**:
- Functions that leverage LRVM space
- Geometric operations (distances, norms, projections)
- Semantic queries and introspection
- Framework Strength utilities
- Convergence detection helpers

### 2.2 Design Philosophy

Libraries should:
1. **Feel Natural**: Use EigenScript's `of` syntax idiomatically
2. **Embrace Geometry**: Expose geometric properties where meaningful
3. **Support Self-Awareness**: Enable programs to inspect their own execution
4. **Be Composable**: Work well with map/filter/reduce patterns
5. **Maintain Stability**: Leverage the language's convergence properties

---

## 3. Gap Analysis

### 3.1 Critical Missing Functions

**Mathematical Operations** (Priority: CRITICAL)
- No trigonometric functions (sin, cos, tan)
- No logarithmic/exponential functions (log, exp, sqrt)
- No rounding functions (round, floor, ceil)
- No absolute value
- No power function (beyond manual multiplication)
- No random number generation

**String Manipulation** (Priority: HIGH)
- No substring extraction
- No string search/find
- No string replacement
- No character access
- No string formatting
- No padding/trimming

**Collection Utilities** (Priority: HIGH)
- No list slicing
- No list concatenation
- No list reversal
- No list search/find
- No set operations (union, intersection)
- No zip/unzip functions

**File I/O** (Priority: MEDIUM)
- No file reading
- No file writing
- No file system operations

**Type Conversion** (Priority: HIGH)
- No explicit str() conversion
- No int() conversion
- No float() conversion

**Error Handling** (Priority: MEDIUM)
- No try/catch mechanism
- No assertion utilities
- No validation helpers

### 3.2 Geometric/Semantic Gaps

**Framework Strength Utilities** (Priority: MEDIUM)
- No FS threshold checking
- No convergence prediction
- No trajectory analysis

**LRVM Operations** (Priority: LOW)
- No explicit vector operations
- No distance computations
- No projection utilities
- No metric manipulation

---

## 4. Prioritized Implementation Plan

### Phase 1: Essential Mathematics (Week 1-2)
**Goal**: Enable scientific and numeric computation

**Priority: CRITICAL** - Blocks most real-world programs

#### Functions to Add:
```eigenscript
# Arithmetic extensions
abs of x           # Absolute value
pow of [x, y]      # Power (x^y)
sqrt of x          # Square root
round of x         # Round to nearest integer
floor of x         # Round down
ceil of x          # Round up

# Trigonometry
sin of x           # Sine
cos of x           # Cosine
tan of x           # Tangent
asin of x          # Arc sine
acos of x          # Arc cosine
atan of x          # Arc tangent
atan2 of [y, x]    # Two-argument arctangent

# Exponential/Logarithmic
exp of x           # e^x
log of x           # Natural logarithm
log10 of x         # Base-10 logarithm
log2 of x          # Base-2 logarithm

# Random
random of null     # Random float [0, 1)
randint of [a, b]  # Random integer [a, b]
choice of list     # Random element from list
shuffle of list    # Randomly shuffle list

# Constants
pi                 # 3.14159...
e                  # 2.71828...
tau                # 2π
inf                # Infinity
nan                # Not a number
```

**Implementation Notes**:
- Use NumPy backend for performance
- Maintain geometric semantics (embed results as LRVM vectors)
- Consider making `pi`, `e`, etc. special built-in values

**Test Cases**:
```eigenscript
# Scientific computation
angle is pi / 4
result is sin of angle      # Should be ≈ 0.707

# Statistics
data is [1, 2, 3, 4, 5]
mean is sum of data / len of data
variance is ...             # Needs sum of squares
```

---

### Phase 2: String Operations (Week 3)
**Goal**: Enable text processing and manipulation

**Priority: HIGH** - Common in most programs

#### Functions to Add:
```eigenscript
# String manipulation
substring of [str, start, end]  # Extract substring
slice of [str, start, end]      # Alias for substring
find of [str, sub]              # Find substring position
replace of [str, old, new]      # Replace substring
starts_with of [str, prefix]    # Check prefix
ends_with of [str, suffix]      # Check suffix
contains of [str, sub]          # Check if contains

# Character operations
char_at of [str, index]         # Get character at index
chars of str                    # Convert to list of chars
ord of char                     # Character to ASCII code
chr of code                     # ASCII code to character

# String formatting
format of [template, args]      # String formatting
pad_left of [str, width, char]  # Left pad
pad_right of [str, width, char] # Right pad
trim of str                     # Remove whitespace
strip of str                    # Alias for trim
lstrip of str                   # Strip left
rstrip of str                   # Strip right

# Case conversion (already have upper/lower)
capitalize of str               # First letter uppercase
title of str                    # Title Case
swapcase of str                 # Swap upper/lower

# String testing
is_alpha of str                 # All alphabetic
is_digit of str                 # All digits
is_alnum of str                 # Alphanumeric
is_space of str                 # All whitespace
is_upper of str                 # All uppercase
is_lower of str                 # All lowercase
```

**Implementation Notes**:
- String operations should preserve metadata in LRVM vectors
- Consider Unicode support from the start
- `split` already exists, add variants (split by delimiter)

**Test Cases**:
```eigenscript
# Text processing
text is "Hello, World!"
greeting is substring of [text, 0, 5]    # "Hello"
found is find of [text, "World"]         # 7
clean is trim of "  spaces  "            # "spaces"

# Validation
email is "user@example.com"
has_at is contains of [email, "@"]       # true
```

---

### Phase 3: Collection Utilities (Week 4)
**Goal**: Comprehensive list/collection operations

**Priority: HIGH** - Essential for data manipulation

#### Functions to Add:
```eigenscript
# List slicing and indexing
slice of [list, start, end]     # Get sublist
first of list                   # First element
last of list                    # Last element
nth of [list, n]                # Nth element (alias for [n])
take of [list, n]               # First n elements
drop of [list, n]               # Skip first n elements
tail of list                    # All but first

# List construction
concat of [list1, list2]        # Concatenate lists
flatten of nested_list          # Flatten nested lists
repeat of [elem, n]             # Create list of n copies
zip of [list1, list2]           # Zip two lists
unzip of list_of_pairs          # Unzip paired list

# List manipulation
reverse of list                 # Reverse list
rotate of [list, n]             # Rotate list n positions
unique of list                  # Remove duplicates
count of [list, elem]           # Count occurrences
remove of [list, elem]          # Remove all occurrences
insert of [list, index, elem]   # Insert at position

# List searching
index of [list, elem]           # Find first index
find_all of [list, elem]        # Find all indices
any of [predicate, list]        # Any element matches
all of [predicate, list]        # All elements match
none of [predicate, list]       # No elements match

# Set operations (on lists)
union of [list1, list2]         # Set union
intersection of [list1, list2]  # Set intersection
difference of [list1, list2]    # Set difference
symmetric_diff of [list1, list2] # Symmetric difference

# Sorting and ordering
sort_by of [list, key_func]     # Sort by key function
group_by of [list, key_func]    # Group by key
partition of [list, predicate]  # Split by condition

# Aggregation (some already exist)
sum of list                     # Sum elements
product of list                 # Product of elements
mean of list                    # Average
median of list                  # Median value
mode of list                    # Most common value
```

**Implementation Notes**:
- Many operations can be implemented using map/filter/reduce
- Consider lazy evaluation for efficiency
- Set operations should handle duplicates intelligently

**Test Cases**:
```eigenscript
# Data processing
nums is [3, 1, 4, 1, 5, 9, 2, 6]
first_three is take of [nums, 3]         # [3, 1, 4]
no_dups is unique of nums                # [3, 1, 4, 5, 9, 2, 6]
sorted_nums is sort of nums              # [1, 1, 2, 3, 4, 5, 6, 9]

# Statistical analysis
data is [10, 20, 30, 40, 50]
avg is mean of data                      # 30
total is sum of data                     # 150
```

---

### Phase 4: Type Conversion & Validation (Week 5)
**Goal**: Robust type handling and validation

**Priority: HIGH** - Needed for user input and data processing

#### Functions to Add:
```eigenscript
# Type conversion
str of x                        # Convert to string
int of x                        # Convert to integer
float of x                      # Convert to float
bool of x                       # Convert to boolean
list of x                       # Convert to list

# Type checking (beyond existing 'type')
is_int of x                     # Check if integer
is_float of x                   # Check if float
is_str of x                     # Check if string
is_list of x                    # Check if list
is_null of x                    # Check if null
is_function of x                # Check if function

# Validation
assert of [condition, message]  # Runtime assertion
validate of [value, predicate]  # Validate with predicate
require of [value, message]     # Require non-null

# Safe conversions
try_int of x                    # Try convert, null on failure
try_float of x                  # Try convert, null on failure
parse_int of x                  # Parse string to int
parse_float of x                # Parse string to float

# Range checking
clamp of [value, min, max]      # Clamp to range
in_range of [value, min, max]   # Check if in range
```

**Implementation Notes**:
- Type conversions should handle edge cases gracefully
- Consider returning null/error vectors for failed conversions
- Validation should integrate with geometric properties

**Test Cases**:
```eigenscript
# User input handling
input_str is input of "Enter a number: "
num is try_int of input_str
if is_null of num:
    print of "Invalid number!"
else:
    print of num

# Data validation
age is 25
valid is in_range of [age, 0, 120]
assert of [valid, "Invalid age"]
```

---

### Phase 5: File I/O (Week 6)
**Goal**: Enable file system interaction

**Priority: MEDIUM** - Important for real applications

#### Functions to Add:
```eigenscript
# File reading
read of filename                # Read entire file as string
read_lines of filename          # Read as list of lines
read_bytes of filename          # Read as bytes

# File writing
write of [filename, content]    # Write string to file
append_to of [filename, content] # Append to file
write_lines of [filename, lines] # Write list of lines

# File operations
exists of filename              # Check if file exists
delete of filename              # Delete file
rename of [old, new]            # Rename file
copy of [src, dst]              # Copy file

# Directory operations
list_dir of dirname             # List directory contents
make_dir of dirname             # Create directory
remove_dir of dirname           # Remove directory
is_dir of path                  # Check if directory
is_file of path                 # Check if file

# Path utilities
join_path of [parts]            # Join path components
basename of path                # Get filename
dirname of path                 # Get directory name
extension of path               # Get file extension
```

**Implementation Notes**:
- Use Python's pathlib/os for implementation
- Handle permissions and errors gracefully
- Consider sandboxing for security

**Test Cases**:
```eigenscript
# Configuration file
config is read of "config.txt"
lines is read_lines of "data.csv"

# Log writing
log_msg is "Application started"
append_to of ["app.log", log_msg]

# File processing
files is list_dir of "data"
csv_files is filter of [is_csv, files]
```

---

### Phase 6: Geometric/Semantic Utilities (Week 7-8)
**Goal**: Leverage EigenScript's unique geometric features

**Priority: MEDIUM** - Differentiating features

#### Functions to Add:
```eigenscript
# Framework Strength utilities
fs of expr                      # Get Framework Strength
converged of expr               # Check if converged
trajectory_of of expr           # Get execution trajectory
stability of expr               # Get stability metric

# Geometric operations
distance of [x, y]              # Semantic distance
project of [x, y]               # Project x onto y
angle_between of [x, y]         # Angle in semantic space
closest of [x, list]            # Find closest vector

# Semantic queries (leveraging interrogatives)
identity of x                   # Get WHO
magnitude of x                  # Get WHAT (alias for 'what')
position of x                   # Get WHERE
direction of x                  # Get WHY
quality of x                    # Get HOW
temporal of x                   # Get WHEN

# Convergence utilities
wait_converged of [expr, timeout] # Wait for convergence
watch of expr                   # Monitor execution
threshold_fs of value           # Set FS threshold

# Vector operations (advanced)
embed of value                  # Explicit LRVM embedding
decode of vector                # Decode vector to value
coordinates of vector           # Get raw coordinates
metric of space                 # Get metric tensor
```

**Implementation Notes**:
- These are EigenScript-specific and showcase its unique features
- Should expose LRVM internals in a controlled way
- Useful for meta-programming and self-aware programs

**Test Cases**:
```eigenscript
# Self-aware computation
x is 42
y is 43
semantic_dist is distance of [x, y]

# Convergence monitoring
define converging_func as:
    # ... iterative computation
    if converged:
        return result

# Geometric reasoning
vec_a is embed of "hello"
vec_b is embed of "world"
similarity is angle_between of [vec_a, vec_b]
```

---

### Phase 7: Advanced Features (Week 9+)
**Goal**: Complete the standard library

**Priority: LOW** - Nice to have

#### Functions to Add:
```eigenscript
# Date/Time (if needed)
now of null                     # Current timestamp
today of null                   # Current date
time of null                    # Current time
format_time of [time, format]   # Format timestamp

# Regular expressions (if needed)
match of [str, pattern]         # Match regex
search of [str, pattern]        # Search for pattern
replace_regex of [str, pattern, replacement]
split_regex of [str, pattern]   # Split by regex

# Functional utilities
compose of [f, g]               # Function composition
curry of [f, arg]               # Partial application
pipe of [value, funcs]          # Pipeline operator

# Data structures
dict of pairs                   # Create dictionary
set of list                     # Create set
stack of list                   # Create stack
queue of list                   # Create queue

# Serialization
json_parse of str               # Parse JSON
json_stringify of obj           # Convert to JSON
```

---

## 5. Implementation Strategy

### 5.1 Architecture

**Location**: `/home/runner/work/EigenScript/EigenScript/src/eigenscript/builtins.py`

**Structure**:
```python
# Organize by category
def builtin_math_sin(arg, space, metric):
    """Sine function..."""
    pass

def builtin_string_substring(arg, space, metric):
    """Extract substring..."""
    pass

# Update get_builtins() to include all new functions
def get_builtins(space: LRVMSpace) -> dict:
    return {
        # Existing functions...
        
        # Phase 1: Math
        "sin": BuiltinFunction("sin", builtin_math_sin, ...),
        "cos": BuiltinFunction("cos", builtin_math_cos, ...),
        # ...
        
        # Phase 2: Strings
        "substring": BuiltinFunction("substring", builtin_string_substring, ...),
        # ...
    }
```

### 5.2 Testing Strategy

For each new function:
1. **Unit tests** in `tests/test_builtins.py`
2. **Integration tests** with example programs
3. **Documentation** with usage examples
4. **Performance benchmarks** for critical functions

### 5.3 Documentation

Update:
- `docs/specification.md` - Language spec with all functions
- `docs/getting-started.md` - Tutorial examples
- `README.md` - Quick reference
- Create `docs/standard-library.md` - Complete library reference

### 5.4 Backwards Compatibility

- Never remove or change behavior of existing functions
- Add new functions incrementally
- Deprecate carefully with warnings
- Version the standard library

---

## 6. Success Metrics

### 6.1 Coverage Metrics

Target: **80+ core functions** by end of implementation

Current: **18 functions**

- Phase 1: +21 functions (Math) → **39 total**
- Phase 2: +24 functions (Strings) → **63 total**
- Phase 3: +30 functions (Collections) → **93 total**
- Phase 4: +12 functions (Types) → **105 total**
- Phase 5: +15 functions (File I/O) → **120 total**
- Phase 6: +16 functions (Geometric) → **136 total**

### 6.2 Usage Metrics

- **Example programs**: Each phase should include 3-5 example programs
- **Test coverage**: Maintain >85% coverage
- **Performance**: No function should degrade interpreter performance

### 6.3 Quality Metrics

- All functions documented with:
  - Purpose and description
  - Parameter types and meanings
  - Return value
  - Example usage
  - Edge cases and error handling
- All functions tested with:
  - Happy path tests
  - Edge case tests
  - Error condition tests

---

## 7. Alternative Approaches

### 7.1 Module System

Instead of adding everything to builtins:
- Create separate modules (math, string, file, etc.)
- Import like: `use math` or `from math import sin`
- Pros: Cleaner namespace, better organization
- Cons: More complex language design

**Recommendation**: Add to builtins first, consider modules in v0.2

### 7.2 Standard Library in EigenScript

Some functions could be implemented in EigenScript itself:
```eigenscript
define mean as:
    total is sum of list
    count is len of list
    return total / count
```

**Recommendation**: Start with Python implementations, migrate performance-critical ones later

### 7.3 Plugin Architecture

Allow users to register custom builtins:
```python
from eigenscript import register_builtin

@register_builtin("my_func")
def my_custom_function(arg, space, metric):
    return ...
```

**Recommendation**: Good for v0.3+, not critical now

---

## 8. Risk Assessment

### 8.1 Risks

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Breaking changes to existing functions | LOW | HIGH | Comprehensive testing, semver |
| Performance degradation | MEDIUM | MEDIUM | Benchmark each function |
| Scope creep | HIGH | MEDIUM | Stick to phased plan |
| Incomplete documentation | MEDIUM | HIGH | Doc requirements per phase |
| Geometric semantics violated | LOW | HIGH | Review each function for LRVM compliance |

### 8.2 Dependencies

- NumPy (already used) - for math functions
- Python stdlib - for file I/O, strings
- No new external dependencies needed

---

## 9. Timeline

### Conservative Estimate (2 months)

| Phase | Duration | Cumulative |
|-------|----------|------------|
| Phase 1: Math | 2 weeks | 2 weeks |
| Phase 2: Strings | 1 week | 3 weeks |
| Phase 3: Collections | 1 week | 4 weeks |
| Phase 4: Types | 1 week | 5 weeks |
| Phase 5: File I/O | 1 week | 6 weeks |
| Phase 6: Geometric | 2 weeks | 8 weeks |
| Documentation & Polish | 1 week | 9 weeks |

### Aggressive Estimate (1 month)

- Focus on Phases 1-4 only
- Parallel development
- Minimal documentation
- Less comprehensive testing

**Recommendation**: Conservative approach for quality

---

## 10. Next Steps

### Immediate Actions (This Week)

1. **Review this plan** with stakeholders
2. **Create GitHub issues** for each phase
3. **Set up project board** to track progress
4. **Write detailed specs** for Phase 1 functions
5. **Begin implementation** of Phase 1 (Math)

### First Pull Request (Next Week)

Implement subset of Phase 1:
- Basic math: `abs`, `sqrt`, `pow`, `round`, `floor`, `ceil`
- Constants: `pi`, `e`
- Tests for all functions
- Documentation updates

---

## 11. Conclusion

"Expand libraries" for EigenScript means building a comprehensive standard library that serves dual purposes:

1. **Traditional Functionality**: Providing the math, string, collection, and I/O functions users expect from any modern programming language

2. **Geometric Extensions**: Leveraging EigenScript's unique LRVM foundation to offer semantic distance, Framework Strength, and convergence utilities that make programs self-aware

The **most critical gap** is mathematical operations (Phase 1), which blocks most real-world programming. Following that, string operations, collection utilities, and type conversion round out the core needs.

The geometric/semantic utilities (Phase 6) are what make EigenScript unique and should be developed to showcase the language's innovative features, but they're not blocking basic usability.

**Recommended Action**: Begin with Phase 1 (Mathematics) immediately, as it provides the highest value and unblocks the most use cases.

---

## Appendices

### Appendix A: Function Signatures Reference

See detailed specifications in the phase descriptions above.

### Appendix B: Comparison with Other Languages

| Feature | Python | JavaScript | EigenScript (Current) | EigenScript (Target) |
|---------|--------|------------|----------------------|---------------------|
| Math functions | ✅ | ✅ | ❌ | ✅ (Phase 1) |
| String operations | ✅ | ✅ | 🔶 Limited | ✅ (Phase 2) |
| Collections | ✅ | ✅ | 🔶 Limited | ✅ (Phase 3) |
| Type conversion | ✅ | ✅ | ❌ | ✅ (Phase 4) |
| File I/O | ✅ | ✅ | ❌ | ✅ (Phase 5) |
| Geometric utilities | ❌ | ❌ | 🔶 Limited | ✅ (Phase 6) |
| Higher-order functions | ✅ | ✅ | ✅ | ✅ |

### Appendix C: Example Programs with Expanded Library

**Scientific Computing**:
```eigenscript
# Calculate projectile motion
angle is pi / 4
velocity is 20
g is 9.8

vx is velocity * cos of angle
vy is velocity * sin of angle

# Time of flight
t_flight is 2 * vy / g

# Maximum height
h_max is pow of [vy, 2] / (2 * g)

print of "Time of flight:"
print of t_flight
print of "Maximum height:"
print of h_max
```

**Text Processing**:
```eigenscript
# Word frequency counter
text is read of "document.txt"
words is split of text
unique_words is unique of words

# Count each word
define count_word as:
    return count of [words, word]

counts is map of [count_word, unique_words]
print of counts
```

**Data Analysis**:
```eigenscript
# Statistical analysis
data is [23, 45, 12, 67, 34, 89, 15, 56]

avg is mean of data
std_dev is sqrt of (variance of data)
sorted_data is sort of data
median_val is median of data

print of "Mean: " + str of avg
print of "Std Dev: " + str of std_dev
print of "Median: " + str of median_val
```

---

**Document End**
