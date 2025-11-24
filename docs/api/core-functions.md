# Core Functions

The fundamental building blocks of EigenScript: I/O, collections, strings, and type operations.

---

## I/O Functions

### print

Output a value to the console.

**Syntax:**
```eigenscript
print of value
```

**Parameters:**
- `value`: Any value to print

**Returns:** `null`

**Example:**
```eigenscript
print of "Hello, World!"
print of 42
print of [1, 2, 3]
```

**Output:**
```
Hello, World!
42
[1, 2, 3]
```

---

### input

Read a line of input from the user.

**Syntax:**
```eigenscript
result is input of prompt
```

**Parameters:**
- `prompt`: String to display before reading input

**Returns:** String entered by user

**Example:**
```eigenscript
name is input of "Enter your name: "
print of "Hello, "
print of name
```

**Output:**
```
Enter your name: Alice
Hello, Alice
```

---

## Collection Functions

### len

Get the length of a collection.

**Syntax:**
```eigenscript
length is len of collection
```

**Parameters:**
- `collection`: List or string

**Returns:** Number representing length

**Example:**
```eigenscript
numbers is [1, 2, 3, 4, 5]
count is len of numbers
print of count  # 5

text is "hello"
chars is len of text
print of chars  # 5
```

---

### range

Create a list of numbers in a range.

**Syntax:**
```eigenscript
# Single argument: range from 0 to n-1
numbers is range of n

# Two arguments: range from start to end-1
numbers is range of [start, end]

# Three arguments: range from start to end-1 by step
numbers is range of [start, end, step]
```

**Parameters:**
- `n`: End value (exclusive)
- `start`: Starting value (inclusive)
- `end`: Ending value (exclusive)
- `step`: Step size (default: 1)

**Returns:** List of numbers

**Example:**
```eigenscript
# 0 to 4
a is range of 5
print of a  # [0, 1, 2, 3, 4]

# 1 to 5
b is range of [1, 6]
print of b  # [1, 2, 3, 4, 5]

# Even numbers 0 to 8
c is range of [0, 10, 2]
print of c  # [0, 2, 4, 6, 8]
```

---

### append

Add an item to the end of a list.

**Syntax:**
```eigenscript
result is append of [list, item]
```

**Parameters:**
- `list`: List to append to
- `item`: Value to add

**Returns:** New list with item appended

**Example:**
```eigenscript
numbers is [1, 2, 3]
result is append of [numbers, 4]
print of result  # [1, 2, 3, 4]
```

**Note:** Returns a new list; does not modify original.

---

### pop

Remove and return the last item from a list.

**Syntax:**
```eigenscript
item is pop of list
```

**Parameters:**
- `list`: List to pop from

**Returns:** The removed item

**Example:**
```eigenscript
numbers is [1, 2, 3, 4, 5]
last is pop of numbers
print of last     # 5
print of numbers  # [1, 2, 3, 4]
```

**Note:** Modifies the original list.

**Error:** Raises error if list is empty.

---

### min

Find the minimum value in a list.

**Syntax:**
```eigenscript
smallest is min of list
```

**Parameters:**
- `list`: List of numbers

**Returns:** Minimum value

**Example:**
```eigenscript
numbers is [5, 2, 8, 1, 9]
smallest is min of numbers
print of smallest  # 1
```

**Error:** Raises error if list is empty.

---

### max

Find the maximum value in a list.

**Syntax:**
```eigenscript
largest is max of list
```

**Parameters:**
- `list`: List of numbers

**Returns:** Maximum value

**Example:**
```eigenscript
numbers is [5, 2, 8, 1, 9]
largest is max of numbers
print of largest  # 9
```

**Error:** Raises error if list is empty.

---

### sort

Sort a list in ascending order.

**Syntax:**
```eigenscript
sorted_list is sort of list
```

**Parameters:**
- `list`: List of comparable values

**Returns:** New sorted list

**Example:**
```eigenscript
numbers is [5, 2, 8, 1, 9]
sorted is sort of numbers
print of sorted  # [1, 2, 5, 8, 9]

words is ["zebra", "apple", "mango"]
sorted_words is sort of words
print of sorted_words  # ["apple", "mango", "zebra"]
```

**Note:** Returns a new list; does not modify original.

---

## Higher-Order Functions

### map

Transform each element of a list using a function.

**Syntax:**
```eigenscript
result is map of [function, list]
```

**Parameters:**
- `function`: Function to apply to each element
- `list`: List to transform

**Returns:** New list with transformed elements

**Example:**
```eigenscript
define square as:
    return n * n

numbers is [1, 2, 3, 4, 5]
squared is map of [square, numbers]
print of squared  # [1, 4, 9, 16, 25]
```

**See Also:** [Higher-Order Functions Guide](../higher_order_functions.md)

---

### filter

Select elements from a list that match a predicate.

**Syntax:**
```eigenscript
result is filter of [predicate, list]
```

**Parameters:**
- `predicate`: Function returning true/false
- `list`: List to filter

**Returns:** New list with matching elements

**Example:**
```eigenscript
define is_even as:
    return (n % 2) is 0

numbers is [1, 2, 3, 4, 5, 6]
evens is filter of [is_even, numbers]
print of evens  # [2, 4, 6]
```

---

### reduce

Combine all elements of a list into a single value.

**Syntax:**
```eigenscript
result is reduce of [function, list, initial]
```

**Parameters:**
- `function`: Binary function to combine elements
- `list`: List to reduce
- `initial`: Initial accumulator value

**Returns:** Single combined value

**Example:**
```eigenscript
define add as:
    a is args of 0
    b is args of 1
    return a + b

numbers is [1, 2, 3, 4, 5]
total is reduce of [add, numbers, 0]
print of total  # 15

define multiply as:
    a is args of 0
    b is args of 1
    return a * b

product is reduce of [multiply, numbers, 1]
print of product  # 120
```

---

## String Functions

### upper

Convert a string to uppercase.

**Syntax:**
```eigenscript
result is upper of string
```

**Parameters:**
- `string`: String to convert

**Returns:** Uppercase string

**Example:**
```eigenscript
text is "hello world"
loud is upper of text
print of loud  # "HELLO WORLD"
```

---

### lower

Convert a string to lowercase.

**Syntax:**
```eigenscript
result is lower of string
```

**Parameters:**
- `string`: String to convert

**Returns:** Lowercase string

**Example:**
```eigenscript
text is "HELLO WORLD"
quiet is lower of text
print of quiet  # "hello world"
```

---

### split

Split a string into a list of substrings.

**Syntax:**
```eigenscript
# Split on whitespace
parts is split of string

# Split on delimiter
parts is split of [string, delimiter]
```

**Parameters:**
- `string`: String to split
- `delimiter`: String to split on (optional, defaults to whitespace)

**Returns:** List of substrings

**Example:**
```eigenscript
# Split on whitespace
sentence is "hello world foo bar"
words is split of sentence
print of words  # ["hello", "world", "foo", "bar"]

# Split on comma
csv is "apple,banana,cherry"
fruits is split of [csv, ","]
print of fruits  # ["apple", "banana", "cherry"]
```

---

### join

Join a list of strings into a single string.

**Syntax:**
```eigenscript
result is join of [delimiter, list]
```

**Parameters:**
- `delimiter`: String to insert between elements
- `list`: List of strings to join

**Returns:** Combined string

**Example:**
```eigenscript
words is ["hello", "world"]
sentence is join of [" ", words]
print of sentence  # "hello world"

fruits is ["apple", "banana", "cherry"]
csv is join of [",", fruits]
print of csv  # "apple,banana,cherry"
```

---

## Type and Introspection Functions

### type

Get the type name of a value.

**Syntax:**
```eigenscript
type_name is type of value
```

**Parameters:**
- `value`: Any value

**Returns:** String with type name

**Example:**
```eigenscript
print of (type of 42)        # "number"
print of (type of "hello")   # "string"
print of (type of [1, 2])    # "list"
print of (type of true)      # "bool"
```

**Possible Types:**
- `"number"` - Integer or float
- `"string"` - Text
- `"list"` - Collection
- `"bool"` - Boolean
- `"function"` - Function reference
- `"null"` - Null value

---

### norm

Calculate the norm (magnitude) of a vector.

**Syntax:**
```eigenscript
magnitude is norm of vector
```

**Parameters:**
- `vector`: Numeric value or list

**Returns:** Norm value

**Example:**
```eigenscript
# Scalar norm (absolute value)
n is norm of -5
print of n  # 5

# Vector norm (Euclidean)
v is [3, 4]
magnitude is norm of v
print of magnitude  # 5.0 (sqrt(3²+4²))
```

**Note:** For scalars, equivalent to absolute value. For lists, computes Euclidean norm.

---

## Summary

The 18 core functions provide:

- **I/O**: `print`, `input`
- **Collections**: `len`, `range`, `append`, `pop`, `min`, `max`, `sort`
- **Higher-Order**: `map`, `filter`, `reduce`
- **Strings**: `upper`, `lower`, `split`, `join`
- **Introspection**: `type`, `norm`

These form the foundation of EigenScript programming. Combined with [File I/O](file-io.md), [JSON](json.md), and [Math](math.md) functions, you have a complete toolkit for practical programming.

---

**Next:** [File I/O Functions](file-io.md) →
