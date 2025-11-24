# Quick Start Guide

Get up and running with EigenScript in 5 minutes!

## Installation

### Via pip (Recommended)

```bash
pip install eigenscript
```

### From Source

```bash
git clone https://github.com/InauguralPhysicist/EigenScript.git
cd EigenScript
pip install -e .
```

## Verify Installation

```bash
eigenscript --version
```

You should see: `EigenScript 0.1.0-alpha`

## Your First Program

Create a file called `hello.eigs`:

```eigenscript
message is "Hello, EigenScript!"
print of message
```

Run it:

```bash
eigenscript hello.eigs
```

Output:
```
Hello, EigenScript!
```

## Interactive REPL

Launch the interactive shell:

```bash
eigenscript
```

Try some commands:

```eigenscript
>>> x is 42
>>> print of x
42

>>> numbers is [1, 2, 3, 4, 5]
>>> print of numbers
[1, 2, 3, 4, 5]

>>> total is numbers of 0
>>> print of total
1
```

Type `exit` or press Ctrl+D to quit.

## Basic Syntax

### Variables

Use **IS** to bind values:

```eigenscript
x is 42
name is "Alice"
numbers is [1, 2, 3]
flag is true
```

### Functions

Use **OF** to apply functions:

```eigenscript
# Built-in functions
print of "Hello"
result is sqrt of 16

# Custom functions
define double as:
    return n * 2

answer is double of 21
```

### Control Flow

```eigenscript
# If/Else
if x > 10:
    print of "Big number"
else:
    print of "Small number"

# Loops
count is 0
loop while count < 5:
    print of count
    count is count + 1
```

### Lists

```eigenscript
# Create lists
numbers is [1, 2, 3, 4, 5]

# Access elements
first is numbers of 0
last is numbers of 4

# List operations
length is len of numbers
doubled is map of [double, numbers]
filtered is filter of [is_positive, numbers]
```

## Common Patterns

### Function Definition

```eigenscript
define greet as:
    print of "Hello, "
    print of name
    print of "!"

greet of "World"
```

### Recursive Functions

```eigenscript
define factorial as:
    if n < 2:
        return 1
    else:
        prev is n - 1
        sub_result is factorial of prev
        return n * sub_result

result is factorial of 5
print of result  # 120
```

### Higher-Order Functions

```eigenscript
# Map: transform each element
define square as:
    return n * n

numbers is [1, 2, 3, 4, 5]
squared is map of [square, numbers]
# Result: [1, 4, 9, 16, 25]

# Filter: select elements
define is_even as:
    return (n % 2) is 0

evens is filter of [is_even, numbers]
# Result: [2, 4]

# Reduce: combine elements
define add as:
    a is args of 0
    b is args of 1
    return a + b

total is reduce of [add, numbers, 0]
# Result: 15
```

## Working with Files

### Reading Files

```eigenscript
# Read entire file
handle is file_open of ["data.txt", "r"]
content is file_read of handle
file_close of handle
print of content
```

### Writing Files

```eigenscript
# Write to file
handle is file_open of ["output.txt", "w"]
file_write of [handle, "Hello, file!"]
file_close of handle
```

## Working with JSON

```eigenscript
# Parse JSON
json_str is '{"name": "Alice", "age": 30}'
data is json_parse of json_str
print of data

# Create JSON
person is ["name", "Bob", "age", 25]
json_output is json_stringify of person
print of json_output
```

## Self-Aware Features

### Predicates

Check computation state:

```eigenscript
define fibonacci as:
    if n < 2:
        return 0
    if n is 1:
        return 1
    
    prev1 is fibonacci of (n - 1)
    prev2 is fibonacci of (n - 2)
    return prev1 + prev2

result is fibonacci of 10

# Check if computation converged
if converged:
    print of "Success!"

# Check if it's improving
if improving:
    print of "Making progress!"
```

### Interrogatives

Query execution context:

```eigenscript
define example as:
    print of WHO    # Current function name
    print of WHAT   # Current value being computed
    print of WHEN   # Current timestamp
    
example of 42
```

## Next Steps

Now that you've got the basics:

1. **[Tutorial Series](tutorials/index.md)** - Learn in depth
2. **[Examples](examples/index.md)** - See real programs
3. **[API Reference](api/index.md)** - Explore all functions
4. **[Language Spec](specification.md)** - Understand the details

## Getting Help

- Check the [examples](examples/index.md) for working code
- Read the [API reference](api/index.md) for function details
- Review the [tutorials](tutorials/index.md) for step-by-step guides
- Ask questions on [GitHub Issues](https://github.com/InauguralPhysicist/EigenScript/issues)

## Common Issues

### Command Not Found

If `eigenscript` command is not found after installation:

```bash
# Try with python -m
python -m eigenscript hello.eigs

# Or add ~/.local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"
```

### Import Errors

Make sure you installed the package:

```bash
pip install -e .
```

### Syntax Errors

Remember:
- Use **IS** for assignment (not `=`)
- Use **OF** for function application (not `()`)
- Indentation matters (like Python)

---

**Ready to learn more?** Continue to [Tutorial 1: Your First Program](tutorials/first-program.md) →
