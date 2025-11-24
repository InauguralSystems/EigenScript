# Tutorial 1: Your First Program

**⏱️ Time: 30 minutes** | **Difficulty: Beginner**

Welcome to EigenScript! In this tutorial, you'll learn the basics and write your first programs.

## What You'll Learn

- How to run EigenScript programs
- Variables and assignment with `IS`
- Input and output with `print` and `input`
- Basic arithmetic operations
- Simple control flow with `IF/ELSE`

## Prerequisites

Make sure EigenScript is installed. Test by running:

```bash
eigenscript --version
```

## Your First Line of Code

Create a file called `hello.eigs`:

```eigenscript
print of "Hello, EigenScript!"
```

Run it:

```bash
eigenscript hello.eigs
```

Output:
```
Hello, EigenScript!
```

**Congratulations!** You just ran your first EigenScript program! 🎉

## Variables and Assignment

In EigenScript, we use **IS** to assign values to variables:

```eigenscript
# Numbers
x is 42
y is 3.14

# Strings
name is "Alice"
greeting is "Hello"

# Booleans
flag is true
done is false

# Lists
numbers is [1, 2, 3, 4, 5]
```

**Try it:**

```eigenscript
# save as variables.eigs
age is 25
name is "Bob"

print of "Name: "
print of name
print of "Age: "
print of age
```

## The OF Operator

**OF** is how we apply functions and access list elements:

```eigenscript
# Print a value
print of "Hello"

# Get list length
size is len of [1, 2, 3]  # 3

# Access list element
numbers is [10, 20, 30]
first is numbers of 0  # 10
second is numbers of 1  # 20
```

## Basic Arithmetic

```eigenscript
# Addition and subtraction
sum is 10 + 5  # 15
diff is 10 - 5  # 5

# Multiplication and division
product is 10 * 5  # 50
quotient is 10 / 5  # 2

# Modulo (remainder)
remainder is 10 % 3  # 1

# Exponentiation
power is pow of [2, 8]  # 256
```

## Input and Output

### Output with print

```eigenscript
print of "Hello"
print of 42
print of [1, 2, 3]

# Multiple prints (no automatic newline)
print of "Hello, "
print of "World!"
```

### Input from user

```eigenscript
# Ask for input
name is input of "What's your name? "
print of "Hello, "
print of name
```

## Control Flow

### IF/ELSE

```eigenscript
age is 18

if age >= 18:
    print of "You are an adult"
else:
    print of "You are a minor"
```

### Comparison Operators

```eigenscript
x is 10
y is 20

# Greater than
if x > y:
    print of "x is greater"

# Less than
if x < y:
    print of "x is less"

# Equal
if x is y:
    print of "x equals y"

# Not equal (using comparison)
if x > y or x < y:
    print of "x not equal to y"
```

## Exercise 1: Temperature Converter

Write a program that converts Celsius to Fahrenheit.

Formula: F = C × 9/5 + 32

**Your turn:**

```eigenscript
# Get temperature in Celsius
celsius_str is input of "Enter temperature in Celsius: "

# Note: In EigenScript, you'd parse the string to number
# For this exercise, assume input is stored correctly
celsius is 25  # Replace with actual parsing

# Calculate Fahrenheit
fahrenheit is (celsius * 9) / 5
fahrenheit is fahrenheit + 32

# Display result
print of celsius
print of "°C is "
print of fahrenheit
print of "°F"
```

## Exercise 2: Simple Calculator

Create a calculator that adds two numbers:

```eigenscript
# Get first number
num1 is input of "Enter first number: "

# Get second number
num2 is input of "Enter second number: "

# For simplicity, use fixed values
a is 10
b is 5

# Calculate
sum is a + b
difference is a - b
product is a * b
quotient is a / b

# Display results
print of "Sum: "
print of sum
print of "Difference: "
print of difference
print of "Product: "
print of product
print of "Quotient: "
print of quotient
```

## Exercise 3: Number Guessing Game

```eigenscript
# Secret number
secret is 42

# Get guess
guess_str is input of "Guess the number (1-100): "

# Use a test value
guess is 30

# Check guess
if guess is secret:
    print of "Correct! You win!"
else:
    if guess < secret:
        print of "Too low!"
    else:
        print of "Too high!"
```

## Complete Example: Personalized Greeting

```eigenscript
# Get user info
name is input of "What's your name? "
age is 25  # Simulated

# Create greeting
print of "Hello, "
print of name
print of "!"

# Check age
if age >= 18:
    print of "Welcome, adult user!"
else:
    print of "Welcome, young user!"

# Calculate birth year (simplified)
current_year is 2024
birth_year is current_year - age

print of "You were born around "
print of birth_year
```

## Key Takeaways

✅ Use **IS** for assignment  
✅ Use **OF** for function application  
✅ `print of value` outputs to console  
✅ `input of prompt` reads from user  
✅ `IF/ELSE` for conditional logic  
✅ Standard arithmetic operators work as expected  

## Common Mistakes

❌ Using `=` instead of `IS`  
❌ Using `()` instead of `OF`  
❌ Forgetting indentation in IF blocks  
❌ Not ending strings with quotes  

## Next Steps

Great job! You've learned the basics of EigenScript. 

**Continue to [Tutorial 2: Recursive Functions](recursive-functions.md)** to learn about functions and recursion, one of EigenScript's most powerful features.

Or explore:
- [API Reference](../api/index.md) - See all available functions
- [Examples](../examples/index.md) - Study more code
- [Quick Start](../quickstart.md) - Review basics
