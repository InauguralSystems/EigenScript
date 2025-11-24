# List Operations

Advanced list manipulation functions in EigenScript.

---

## zip

Combine multiple lists element-wise.

**Syntax:**
```eigenscript
paired is zip of [list1, list2]
```

**Parameters:**
- List of lists to combine

**Returns:** List of tuples (sublists)

**Example:**
```eigenscript
names is ["Alice", "Bob", "Charlie"]
ages is [30, 25, 35]
paired is zip of [names, ages]
print of paired
# [["Alice", 30], ["Bob", 25], ["Charlie", 35]]
```

**Note:** Stops at shortest list length.

---

## enumerate

Add indices to list elements.

**Syntax:**
```eigenscript
indexed is enumerate of list
```

**Parameters:**
- `list`: List to enumerate

**Returns:** List of [index, value] pairs

**Example:**
```eigenscript
fruits is ["apple", "banana", "cherry"]
indexed is enumerate of fruits
print of indexed
# [[0, "apple"], [1, "banana"], [2, "cherry"]]

# Use in iteration
define print_indexed as:
    idx is item of 0
    val is item of 1
    print of idx
    print of ": "
    print of val

result is map of [print_indexed, indexed]
```

---

## flatten

Flatten nested lists into a single list.

**Syntax:**
```eigenscript
flat is flatten of nested_list
```

**Parameters:**
- `nested_list`: List containing sublists

**Returns:** Flattened list

**Example:**
```eigenscript
nested is [[1, 2], [3, 4], [5, 6]]
flat is flatten of nested
print of flat  # [1, 2, 3, 4, 5, 6]

mixed is [[1, 2, 3], [4], [5, 6]]
result is flatten of mixed
print of result  # [1, 2, 3, 4, 5, 6]
```

**Note:** Only flattens one level.

---

## reverse

Reverse the order of list elements.

**Syntax:**
```eigenscript
reversed is reverse of list
```

**Parameters:**
- `list`: List to reverse

**Returns:** New reversed list

**Example:**
```eigenscript
numbers is [1, 2, 3, 4, 5]
backwards is reverse of numbers
print of backwards  # [5, 4, 3, 2, 1]

words is ["first", "second", "third"]
reversed_words is reverse of words
print of reversed_words  # ["third", "second", "first"]
```

---

## Complete Examples

### Parallel Iteration

```eigenscript
# Process multiple lists together
names is ["Alice", "Bob", "Charlie"]
ages is [30, 25, 35]
cities is ["Boston", "NYC", "LA"]

# Combine all three
data is zip of [names, ages]
data is zip of [data, cities]

# Now process combined data
define print_person as:
    name_age is person of 0
    name is name_age of 0
    age is name_age of 1
    city is person of 1
    
    print of name
    print of " is "
    print of age
    print of " years old from "
    print of city

result is map of [print_person, data]
```

### Matrix Transposition

```eigenscript
# Transpose a matrix using zip
matrix is [[1, 2, 3], [4, 5, 6]]
transposed is zip of matrix
print of transposed
# [[1, 4], [2, 5], [3, 6]]
```

### Enumerated Filtering

```eigenscript
# Keep only even-indexed elements
values is ["a", "b", "c", "d", "e"]
indexed is enumerate of values

define keep_even_index as:
    idx is item of 0
    return (idx % 2) is 0

filtered_indexed is filter of [keep_even_index, indexed]

# Extract just the values
define get_value as:
    return item of 1

result is map of [get_value, filtered_indexed]
print of result  # ["a", "c", "e"]
```

### Flatten and Process

```eigenscript
# Flatten nested data for processing
groups is [[1, 2, 3], [4, 5], [6, 7, 8, 9]]
all_numbers is flatten of groups

# Now calculate total
define add as:
    return n + m

total is reduce of [add, all_numbers, 0]
print of total  # 45
```

### Palindrome Check

```eigenscript
# Check if list is palindrome
numbers is [1, 2, 3, 2, 1]
reversed is reverse of numbers

# Compare (conceptual - would need equality check)
print of "Original: "
print of numbers
print of "Reversed: "
print of reversed
```

### Create Pairs

```eigenscript
# Create consecutive pairs
numbers is [1, 2, 3, 4, 5]

# Shift list by 1
shifted is [2, 3, 4, 5]
original is [1, 2, 3, 4]

pairs is zip of [original, shifted]
print of pairs
# [[1, 2], [2, 3], [3, 4], [4, 5]]
```

---

## Combining Operations

### Pipeline Example

```eigenscript
# Complex data transformation pipeline
data is [[1, 2], [3, 4], [5, 6]]

# 1. Flatten
flat is flatten of data
# [1, 2, 3, 4, 5, 6]

# 2. Reverse
rev is reverse of flat
# [6, 5, 4, 3, 2, 1]

# 3. Enumerate
indexed is enumerate of rev
# [[0, 6], [1, 5], [2, 4], [3, 3], [4, 2], [5, 1]]

print of indexed
```

### Data Restructuring

```eigenscript
# Split list into chunks, then flatten back
original is [1, 2, 3, 4, 5, 6]

# Create chunks (conceptual)
chunk1 is [1, 2]
chunk2 is [3, 4]
chunk3 is [5, 6]
chunks is [chunk1, chunk2, chunk3]

# Process chunks individually
define process_chunk as:
    total is chunk of 0
    total is total + (chunk of 1)
    return total

processed is map of [process_chunk, chunks]
print of processed  # [3, 7, 11]
```

---

## Summary

Enhanced list operations provide:

- `zip` - Combine lists element-wise
- `enumerate` - Add indices to elements
- `flatten` - Flatten nested lists
- `reverse` - Reverse list order

**Total: 4 functions**

These functions enable sophisticated list transformations and functional programming patterns.

---

**Next:** [Math Functions](math.md) →
