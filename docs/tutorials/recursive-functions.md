# Tutorial 2: Recursive Functions

**⏱️ Time: 45 minutes** | **Difficulty: Beginner-Intermediate**

Learn to write recursive functions in EigenScript with automatic convergence detection.

## Topics Covered

- Defining functions with `DEFINE`
- Recursive thinking
- Base and recursive cases
- Return values
- Automatic convergence

## Function Definition

```eigenscript
define greet as:
    print of "Hello, "
    print of name
    print of "!"

greet of "World"
```

## Factorial

```eigenscript
define factorial as:
    if n is 0:
        return 1
    else:
        prev is n - 1
        return n * (factorial of prev)

result is factorial of 5
print of result  # 120
```

## Fibonacci

```eigenscript
define fibonacci as:
    if n is 0:
        return 0
    if n is 1:
        return 1
    
    f1 is fibonacci of (n - 1)
    f2 is fibonacci of (n - 2)
    return f1 + f2

fib10 is fibonacci of 10
print of fib10  # 55
```

## Key Takeaways

✅ Use `DEFINE` to create functions
✅ Always have a base case
✅ Use `RETURN` to exit functions
✅ EigenScript detects convergence automatically

**Next:** [Tutorial 3: List Manipulation](list-manipulation.md) →
