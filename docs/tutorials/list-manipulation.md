# Tutorial 3: List Manipulation

**⏱️ Time: 45 minutes** | **Difficulty: Intermediate**

Master functional programming with lists in EigenScript.

## Topics Covered

- Creating and accessing lists
- Higher-order functions (map, filter, reduce)
- List operations
- Functional patterns

## Higher-Order Functions

### Map

```eigenscript
define square as:
    return n * n

numbers is [1, 2, 3, 4, 5]
squared is map of [square, numbers]
print of squared  # [1, 4, 9, 16, 25]
```

### Filter

```eigenscript
define is_even as:
    return (n % 2) is 0

numbers is [1, 2, 3, 4, 5, 6]
evens is filter of [is_even, numbers]
print of evens  # [2, 4, 6]
```

### Reduce

```eigenscript
define add as:
    a is args of 0
    b is args of 1
    return a + b

numbers is [1, 2, 3, 4, 5]
total is reduce of [add, numbers, 0]
print of total  # 15
```

## Advanced Operations

```eigenscript
# Zip
names is ["Alice", "Bob"]
ages is [30, 25]
paired is zip of [names, ages]
# [["Alice", 30], ["Bob", 25]]

# Enumerate
fruits is ["apple", "banana"]
indexed is enumerate of fruits
# [[0, "apple"], [1, "banana"]]

# Flatten
nested is [[1, 2], [3, 4]]
flat is flatten of nested
# [1, 2, 3, 4]

# Reverse
numbers is [1, 2, 3]
reversed is reverse of numbers
# [3, 2, 1]
```

**Next:** [Tutorial 4: File Processing](file-processing.md) →
