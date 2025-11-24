# Math Functions

Mathematical operations for scientific and engineering computations in EigenScript.

---

## Basic Math

### sqrt

Calculate square root.

**Syntax:**
```eigenscript
root is sqrt of n
```

**Parameters:**
- `n`: Non-negative number

**Returns:** Square root

**Example:**
```eigenscript
result is sqrt of 16
print of result  # 4.0

root is sqrt of 2
print of root  # 1.41421356...
```

**Error:** Raises error for negative numbers.

---

### abs

Calculate absolute value.

**Syntax:**
```eigenscript
magnitude is abs of n
```

**Parameters:**
- `n`: Any number

**Returns:** Absolute value

**Example:**
```eigenscript
pos is abs of 5
print of pos  # 5

neg is abs of -5
print of neg  # 5

zero is abs of 0
print of zero  # 0
```

---

### pow

Raise number to a power.

**Syntax:**
```eigenscript
result is pow of [base, exponent]
```

**Parameters:**
- `base`: Number
- `exponent`: Power to raise to

**Returns:** base^exponent

**Example:**
```eigenscript
# 2^8
result is pow of [2, 8]
print of result  # 256

# 10^3
thousand is pow of [10, 3]
print of thousand  # 1000

# Fractional exponents (roots)
sqrt_via_pow is pow of [16, 0.5]
print of sqrt_via_pow  # 4.0
```

---

## Exponential and Logarithmic

### exp

Calculate e^x (exponential function).

**Syntax:**
```eigenscript
result is exp of x
```

**Parameters:**
- `x`: Exponent

**Returns:** e^x

**Example:**
```eigenscript
e is exp of 1
print of e  # 2.71828...

big is exp of 10
print of big  # 22026.465...
```

---

### log

Calculate natural logarithm (base e).

**Syntax:**
```eigenscript
result is log of n
```

**Parameters:**
- `n`: Positive number

**Returns:** ln(n)

**Example:**
```eigenscript
# ln(e) = 1
one is log of 2.71828
print of one  # ~1.0

# ln(10)
result is log of 10
print of result  # 2.302585...
```

**Error:** Raises error for non-positive numbers.

---

## Trigonometric

### sin

Calculate sine (in radians).

**Syntax:**
```eigenscript
result is sin of angle
```

**Parameters:**
- `angle`: Angle in radians

**Returns:** sin(angle)

**Example:**
```eigenscript
# sin(0) = 0
zero is sin of 0
print of zero  # 0.0

# sin(π/2) ≈ 1
half_pi is 1.5708
one is sin of half_pi
print of one  # ~1.0

# sin(π) ≈ 0
pi is 3.14159
zero_again is sin of pi
print of zero_again  # ~0.0
```

---

### cos

Calculate cosine (in radians).

**Syntax:**
```eigenscript
result is cos of angle
```

**Parameters:**
- `angle`: Angle in radians

**Returns:** cos(angle)

**Example:**
```eigenscript
# cos(0) = 1
one is cos of 0
print of one  # 1.0

# cos(π/2) ≈ 0
half_pi is 1.5708
zero is cos of half_pi
print of zero  # ~0.0

# cos(π) ≈ -1
pi is 3.14159
neg_one is cos of pi
print of neg_one  # ~-1.0
```

---

### tan

Calculate tangent (in radians).

**Syntax:**
```eigenscript
result is tan of angle
```

**Parameters:**
- `angle`: Angle in radians

**Returns:** tan(angle)

**Example:**
```eigenscript
# tan(0) = 0
zero is tan of 0
print of zero  # 0.0

# tan(π/4) ≈ 1
quarter_pi is 0.7854
one is tan of quarter_pi
print of one  # ~1.0
```

---

## Rounding

### floor

Round down to nearest integer.

**Syntax:**
```eigenscript
result is floor of n
```

**Parameters:**
- `n`: Number to round

**Returns:** Largest integer ≤ n

**Example:**
```eigenscript
down is floor of 3.7
print of down  # 3

down2 is floor of 3.2
print of down2  # 3

negative is floor of -2.3
print of negative  # -3
```

---

### ceil

Round up to nearest integer.

**Syntax:**
```eigenscript
result is ceil of n
```

**Parameters:**
- `n`: Number to round

**Returns:** Smallest integer ≥ n

**Example:**
```eigenscript
up is ceil of 3.2
print of up  # 4

up2 is ceil of 3.7
print of up2  # 4

negative is ceil of -2.7
print of negative  # -2
```

---

### round

Round to nearest integer or specified decimal places.

**Syntax:**
```eigenscript
# Round to nearest integer
result is round of n

# Round to specific decimal places
result is round of [n, decimals]
```

**Parameters:**
- `n`: Number to round
- `decimals`: Number of decimal places (optional)

**Returns:** Rounded number

**Example:**
```eigenscript
# Round to integer
near is round of 3.5
print of near  # 4

near2 is round of 3.4
print of near2  # 3

# Round to 2 decimal places
precise is round of [3.14159, 2]
print of precise  # 3.14

# Round to 1 decimal place
one_place is round of [2.678, 1]
print of one_place  # 2.7
```

---

## Complete Examples

### Distance Formula

```eigenscript
# Calculate Euclidean distance between two points
define distance as:
    x1 is p1 of 0
    y1 is p1 of 1
    x2 is p2 of 0
    y2 is p2 of 1
    
    dx is x2 - x1
    dy is y2 - y1
    
    dx_sq is pow of [dx, 2]
    dy_sq is pow of [dy, 2]
    
    sum is dx_sq + dy_sq
    dist is sqrt of sum
    
    return dist

point1 is [0, 0]
point2 is [3, 4]
dist is distance of [point1, point2]
print of dist  # 5.0
```

### Circle Area

```eigenscript
# Calculate area of circle
define circle_area as:
    pi is 3.14159
    r_squared is pow of [radius, 2]
    area is pi * r_squared
    return area

area is circle_area of 5
print of area  # ~78.54
```

### Quadratic Formula

```eigenscript
# Solve ax^2 + bx + c = 0
define quadratic as:
    # b^2 - 4ac
    b_sq is pow of [b, 2]
    four_ac is 4 * a
    four_ac is four_ac * c
    discriminant is b_sq - four_ac
    
    # sqrt(discriminant)
    sqrt_d is sqrt of discriminant
    
    # (-b ± sqrt(d)) / 2a
    neg_b is 0 - b
    two_a is 2 * a
    
    x1 is (neg_b + sqrt_d) / two_a
    x2 is (neg_b - sqrt_d) / two_a
    
    return [x1, x2]

# Solve x^2 - 5x + 6 = 0
roots is quadratic of [1, -5, 6]
print of roots  # [3, 2]
```

### Wave Function

```eigenscript
# Generate sine wave values
define wave_value as:
    pi is 3.14159
    two_pi is 2 * pi
    angle is (t * two_pi) / period
    value is amplitude * (sin of angle)
    return value

# Sample wave at different times
amplitude is 10
period is 4

t1 is wave_value of 0
t2 is wave_value of 1
t3 is wave_value of 2

print of "Wave values:"
print of t1
print of t2
print of t3
```

### Statistical Functions

```eigenscript
# Calculate mean
define mean as:
    define add as:
        return a + b
    
    total is reduce of [add, numbers, 0]
    count is len of numbers
    average is total / count
    return average

data is [2, 4, 6, 8, 10]
avg is mean of data
print of avg  # 6.0

# Calculate standard deviation (simplified)
define std_dev as:
    avg is mean of numbers
    
    define squared_diff as:
        diff is n - avg
        return pow of [diff, 2]
    
    sq_diffs is map of [squared_diff, numbers]
    
    define add as:
        return a + b
    
    sum_sq is reduce of [add, sq_diffs, 0]
    count is len of numbers
    variance is sum_sq / count
    std is sqrt of variance
    return std

sd is std_dev of data
print of sd  # ~2.83
```

### Degree/Radian Conversion

```eigenscript
# Convert degrees to radians
define deg_to_rad as:
    pi is 3.14159
    return (degrees * pi) / 180

# Convert radians to degrees
define rad_to_deg as:
    pi is 3.14159
    return (radians * 180) / pi

# Example: sin(90°)
ninety_deg is 90
ninety_rad is deg_to_rad of ninety_deg
result is sin of ninety_rad
print of result  # ~1.0
```

---

## Constants

Common mathematical constants:

```eigenscript
pi is 3.14159265358979
e is 2.71828182845905
tau is 6.28318530717959  # 2π
phi is 1.61803398874989  # Golden ratio
```

---

## Summary

Math functions provide:

- **Basic**: `sqrt`, `abs`, `pow`
- **Exponential/Log**: `exp`, `log`
- **Trigonometric**: `sin`, `cos`, `tan`
- **Rounding**: `floor`, `ceil`, `round`

**Total: 11 functions**

All angles are in **radians**. To use degrees, convert first.

---

**Next:** [Language Constructs](constructs.md) →
