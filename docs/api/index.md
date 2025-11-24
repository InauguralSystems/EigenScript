# API Reference

Complete documentation for all EigenScript functions, operators, and language constructs.

## Overview

EigenScript provides **48 builtin functions** organized into the following categories:

| Category | Functions | Description |
|----------|-----------|-------------|
| [Core Functions](core-functions.md) | 18 functions | I/O, collections, strings, type operations |
| [File I/O](file-io.md) | 10 functions | File operations and path utilities |
| [JSON](json.md) | 2 functions | JSON parsing and serialization |
| [Date/Time](datetime.md) | 3 functions | Time operations and formatting |
| [List Operations](lists.md) | 4 functions | Advanced list manipulation |
| [Math Functions](math.md) | 11 functions | Mathematical operations |
| [Language Constructs](constructs.md) | 6 constructs | IS, OF, IF, LOOP, DEFINE, RETURN |
| [Interrogatives](interrogatives.md) | 6 keywords | WHO, WHAT, WHEN, WHERE, WHY, HOW |
| [Predicates](predicates.md) | 6 predicates | converged, stable, improving, etc. |

**Total: 60+ documented elements**

## Quick Reference

### Core Functions

```eigenscript
print of value              # Output to console
input of prompt             # Read user input
len of collection          # Get length
type of value              # Get type name
norm of vector             # Get norm/magnitude
range of [start, end]      # Create range
```

### List Operations

```eigenscript
append of [list, item]     # Add item to list
pop of list                # Remove last item
min of list                # Find minimum
max of list                # Find maximum
sort of list               # Sort list
reverse of list            # Reverse list
```

### Higher-Order Functions

```eigenscript
map of [func, list]        # Transform each element
filter of [pred, list]     # Select matching elements
reduce of [func, list, init] # Fold to single value
```

### String Operations

```eigenscript
upper of string            # Convert to uppercase
lower of string            # Convert to lowercase
split of [string, delim]   # Split into list
join of [delim, list]      # Join list into string
```

### File Operations

```eigenscript
file_open of [path, mode]  # Open file
file_read of handle        # Read from file
file_write of [handle, data] # Write to file
file_close of handle       # Close file
file_exists of path        # Check if file exists
list_dir of path           # List directory contents
```

### Math Functions

```eigenscript
sqrt of n                  # Square root
abs of n                   # Absolute value
pow of [base, exp]         # Power
sin of angle               # Sine (radians)
cos of angle               # Cosine (radians)
log of n                   # Natural logarithm
exp of n                   # Exponential
floor of n                 # Round down
ceil of n                  # Round up
round of [n, digits]       # Round to digits
```

### JSON Operations

```eigenscript
json_parse of json_string  # Parse JSON to data
json_stringify of data     # Convert data to JSON
```

### Date/Time Operations

```eigenscript
time_now of 0              # Current Unix timestamp
time_format of [timestamp, format] # Format timestamp
time_parse of [string, format]     # Parse time string
```

## Function Signature Conventions

All EigenScript functions follow these patterns:

### Unary Functions

```eigenscript
result is function_name of argument
```

Example: `length is len of [1, 2, 3]`

### Binary Functions (using lists)

```eigenscript
result is function_name of [arg1, arg2]
```

Example: `power is pow of [2, 8]`

### Higher-Order Functions

```eigenscript
result is function_name of [function, list]
result is function_name of [function, list, initial]
```

Example: `doubled is map of [double, numbers]`

## Error Handling

EigenScript functions raise errors in the following cases:

- **TypeError**: Wrong argument type
- **ValueError**: Invalid argument value
- **RuntimeError**: Operation failed
- **FileNotFoundError**: File does not exist
- **JSONDecodeError**: Invalid JSON

Example error handling:

```eigenscript
# The language handles errors gracefully
handle is file_open of ["missing.txt", "r"]
# Error: FileNotFoundError: File 'missing.txt' not found
```

## Parameter Types

Common parameter types in EigenScript:

| Type | Description | Example |
|------|-------------|---------|
| `number` | Integer or float | `42`, `3.14` |
| `string` | Text value | `"hello"`, `"world"` |
| `list` | Collection of values | `[1, 2, 3]` |
| `bool` | Boolean value | `true`, `false` |
| `function` | Function reference | `double`, `is_even` |
| `handle` | File handle | (from `file_open`) |

## Return Values

All functions return LRVMVector objects, but they represent different Python types:

- Numbers → `number`
- Strings → `string`
- Lists → `list`
- Booleans → `bool`
- None → special null value

## Navigation

### By Category

- [Core Functions](core-functions.md) - Essential operations
- [File I/O](file-io.md) - Working with files
- [JSON](json.md) - Data serialization
- [Date/Time](datetime.md) - Time operations
- [List Operations](lists.md) - Advanced list features
- [Math Functions](math.md) - Mathematical operations
- [Language Constructs](constructs.md) - Syntax elements
- [Interrogatives](interrogatives.md) - Self-awareness
- [Predicates](predicates.md) - State checking

### Alphabetical Index

<div style="column-count: 3; column-gap: 20px;">

- `abs`
- `absolute_path`
- `append`
- `basename`
- `ceil`
- `converged`
- `cos`
- `DEFINE`
- `dirname`
- `diverging`
- `enumerate`
- `equilibrium`
- `exp`
- `file_close`
- `file_exists`
- `file_open`
- `file_read`
- `file_size`
- `file_write`
- `filter`
- `flatten`
- `floor`
- `HOW`
- `IF`
- `improving`
- `input`
- `IS`
- `join`
- `json_parse`
- `json_stringify`
- `len`
- `list_dir`
- `log`
- `LOOP`
- `lower`
- `map`
- `max`
- `min`
- `norm`
- `OF`
- `oscillating`
- `pop`
- `pow`
- `print`
- `range`
- `reduce`
- `RETURN`
- `reverse`
- `round`
- `sin`
- `sort`
- `split`
- `sqrt`
- `stable`
- `tan`
- `time_format`
- `time_now`
- `time_parse`
- `type`
- `upper`
- `WHAT`
- `WHEN`
- `WHERE`
- `WHO`
- `WHY`
- `zip`

</div>

## Examples

Each function page includes:

1. **Syntax** - How to call the function
2. **Parameters** - What arguments it takes
3. **Return Value** - What it returns
4. **Description** - What it does
5. **Examples** - Working code samples
6. **Notes** - Special considerations
7. **Errors** - Possible error conditions

Start exploring with [Core Functions](core-functions.md) →
