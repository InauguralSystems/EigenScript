"""
Built-in functions for EigenScript.

Provides standard library functions like print, input, len, etc.
"""

import math
import os
import json
import time
from datetime import datetime
import numpy as np
from typing import Callable, Any, Union, TYPE_CHECKING
from dataclasses import dataclass
from eigenscript.semantic.lrvm import LRVMVector, LRVMSpace

if TYPE_CHECKING:
    from eigenscript.evaluator.interpreter import EigenList

# Type alias for values that can flow through the interpreter
# Must match the Value type in interpreter.py
Value = Union[LRVMVector, "EigenList"]


@dataclass
class BuiltinFunction:
    """
    Represents a built-in function implemented in Python.

    Built-in functions are native code that can be called from EigenScript.
    They receive Values (LRVM vectors or lists) and context (space + metric)
    and return Values.
    """

    name: str
    func: Callable[[Value, "LRVMSpace", Any], Value]  # Takes (arg, space, metric)
    description: str = ""

    def __repr__(self) -> str:
        return f"BuiltinFunction({self.name!r})"


def builtin_print(arg, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Print a value to stdout.

    Args:
        arg: LRVM vector or EigenList to print
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Null vector (prints have no meaningful return value)
    """
    # Import here to avoid circular dependency
    from eigenscript.evaluator.interpreter import EigenList

    # Handle EigenList
    if isinstance(arg, EigenList):
        # Print list as [elem1, elem2, ...] (handles empty lists)
        if len(arg.elements) == 0:
            print("[]")
        else:
            decoded_elems = []
            for elem in arg.elements:
                decoded_elems.append(decode_vector(elem, space, metric))
            print(f"[{', '.join(str(e) for e in decoded_elems)}]")
    else:
        # Regular vector
        value = decode_vector(arg, space, metric)
        print(value)

    return space.zero_vector()


def builtin_input(
    prompt: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Read a line from stdin.

    Args:
        prompt: Prompt message as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        User input as LRVM vector
    """
    prompt_str = decode_vector(prompt, space, metric)
    user_input = input(str(prompt_str))
    return space.embed(user_input)


def builtin_len(arg, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Get the length of a value.

    For lists: returns the number of elements.
    For vectors: returns the Euclidean norm.

    Args:
        arg: LRVM vector or EigenList
        space: LRVM space for operations
        metric: Metric tensor for computing norm

    Returns:
        Length as LRVM vector
    """
    # Import here to avoid circular dependency
    from eigenscript.evaluator.interpreter import EigenList

    # Handle EigenList
    if isinstance(arg, EigenList):
        return space.embed(float(len(arg.elements)))
    else:
        # For vectors, return the Euclidean norm
        norm_value = np.linalg.norm(arg.coords)
        return space.embed(float(norm_value))


def builtin_type(arg, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Get the type of a value.

    Args:
        arg: LRVM vector or EigenList
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Type name as LRVM vector
    """
    # Import here to avoid circular dependency
    from eigenscript.evaluator.interpreter import EigenList

    # Handle EigenList
    if isinstance(arg, EigenList):
        return space.embed("list")
    else:
        value = decode_vector(arg, space, metric)
        type_name = type(value).__name__
        return space.embed(type_name)


def builtin_norm(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Get the geometric norm (magnitude) of a vector.

    Args:
        arg: LRVM vector
        space: LRVM space for operations
        metric: Metric tensor for computing norm

    Returns:
        Norm as LRVM vector
    """
    # Use Euclidean norm for simplicity
    norm_value = np.linalg.norm(arg.coords)
    return space.embed(float(norm_value))


def builtin_range(arg: LRVMVector, space: LRVMSpace, metric: Any = None):
    """
    Generate a range of numbers from 0 to n-1.

    Creates a list containing integers [0, 1, 2, ..., n-1].

    Example:
        range of 5  # Creates [0, 1, 2, 3, 4]

    Args:
        arg: Upper limit as LRVM vector (will be converted to integer)
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        EigenList containing numbers [0, 1, ..., n-1]
    """
    # Import here to avoid circular dependency
    from eigenscript.evaluator.interpreter import EigenList

    # Properly decode the vector to get the actual number
    decoded_value = decode_vector(arg, space, metric)

    # Handle both int and float results
    if isinstance(decoded_value, (int, float)):
        n = int(decoded_value)
    else:
        # Fallback: try to parse as string or use default
        try:
            n = int(decoded_value)
        except (ValueError, TypeError):
            n = 0

    # Generate list elements as LRVM vectors
    elements = []
    for i in range(n):
        elements.append(space.embed_scalar(float(i)))

    return EigenList(elements)


def decode_vector(vector: Value, space: LRVMSpace, metric: Any = None) -> Any:
    """
    Attempt to decode a Value (LRVM vector or list) back to a Python value.

    This is a best-effort heuristic decoder. Since LRVM embeddings
    are lossy, we can't always perfectly reconstruct the original value.

    Args:
        vector: LRVM vector or EigenList to decode
        space: LRVM space for context
        metric: Metric tensor (optional)

    Returns:
        Decoded Python value (str, float, list, or vector representation)
    """
    # Import here to avoid circular dependency
    from eigenscript.evaluator.interpreter import EigenList

    # Handle EigenList - return the list itself
    if isinstance(vector, EigenList):
        # Decode each element in the list recursively
        return [decode_vector(elem, space, metric) for elem in vector.elements]

    # Check for string metadata first (strings preserve their original value)
    if "string_value" in vector.metadata:
        return vector.metadata["string_value"]

    # Check if it's approximately the zero vector
    if np.allclose(vector.coords, 0.0, atol=1e-6):
        return "null"

    # For scalar embeddings, the first coordinate contains the actual value
    # Check coords[0] and coords[1] - if they're both close to the same value,
    # it's likely a scalar embedding
    first_coord = vector.coords[0]
    second_coord = vector.coords[1] if len(vector.coords) > 1 else 0.0

    # Scalar embeddings have coords[0] and coords[1] set to the value
    # Handle zero specially
    if abs(first_coord) < 1e-9 and abs(second_coord) < 1e-9:
        # Check if this looks like zero (coords[2] should also be small for zero)
        third_coord = vector.coords[2] if len(vector.coords) > 2 else 0.0
        if abs(third_coord) < 1.5:  # Zero has coords[2] ≈ 1
            return 0

    # Check for scalar embedding: coords[0] = value, coords[1] = value (or abs(value) in some cases)
    # Handle both cases: coords[1] = value (same as coords[0]) or coords[1] = abs(value)
    if abs(first_coord) > 1e-9:
        # Case 1: coords[0] and coords[1] are the same (including negative numbers)
        if abs(first_coord - second_coord) < 1e-6:
            # Likely a scalar - return as int if close to integer
            if abs(first_coord - round(first_coord)) < 1e-6:
                return int(round(first_coord))
            else:
                return first_coord
        # Case 2: coords[0] = value, coords[1] = abs(value)
        elif abs(abs(first_coord) - second_coord) < 1e-6:
            # Likely a scalar (positive or negative) - return as int if close to integer
            if abs(first_coord - round(first_coord)) < 1e-6:
                return int(round(first_coord))
            else:
                return first_coord

    # Check if only first coordinate is non-zero (alternative scalar encoding)
    rest_norm = np.linalg.norm(vector.coords[1:])
    if rest_norm < 1e-3 and abs(first_coord) > 1e-9:
        # Return as int or float
        if abs(first_coord - round(first_coord)) < 1e-6:
            return int(round(first_coord))
        else:
            return first_coord

    # Otherwise return a vector representation
    norm_value = np.linalg.norm(vector.coords)
    return f"Vector(norm={norm_value:.3f})"


def builtin_upper(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Convert string to uppercase.

    Example:
        upper of "hello"  -> "HELLO"
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, str):
        return space.embed_string(decoded.upper())
    else:
        raise TypeError(f"upper requires a string argument")


def builtin_lower(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Convert string to lowercase.

    Example:
        lower of "HELLO"  -> "hello"
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, str):
        return space.embed_string(decoded.lower())
    else:
        raise TypeError(f"lower requires a string argument")


def builtin_split(arg: LRVMVector, space: LRVMSpace, metric: Any = None):
    """
    Split string into list of words.

    Example:
        split of "hello world"  -> ["hello", "world"]
    """
    from eigenscript.evaluator.interpreter import EigenList

    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, str):
        # Split by whitespace
        words = decoded.split()
        # Convert each word to an LRVM vector
        word_vectors = [space.embed_string(word) for word in words]
        return EigenList(word_vectors)
    else:
        raise TypeError(f"split requires a string argument")


def builtin_join(arg, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Join list of strings into a single string.

    Example:
        join of ["hello", "world"]  -> "hello world"
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(arg, EigenList):
        raise TypeError(f"join requires a list argument")

    # Decode each element as a string
    strings = []
    for elem in arg.elements:
        decoded = decode_vector(elem, space, metric)
        if isinstance(decoded, str):
            strings.append(decoded)
        else:
            # Convert to string representation
            strings.append(str(decoded))

    # Join with space separator
    result = " ".join(strings)
    return space.embed_string(result)


def builtin_append(list_and_value, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Append an element to a list (mutates the list in place).

    Args:
        list_and_value: Two-element list [target_list, value_to_append]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Null vector (append has no meaningful return value)
    """
    from eigenscript.evaluator.interpreter import EigenList

    # Expect list_and_value to be an EigenList with 2 elements: [list, value]
    if not isinstance(list_and_value, EigenList):
        raise TypeError("append requires a list and a value")

    if len(list_and_value.elements) != 2:
        raise TypeError("append requires exactly 2 arguments: list and value")

    target_list = list_and_value.elements[0]
    value = list_and_value.elements[1]

    # First element must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("First argument to append must be a list")

    # Append the value to the list
    target_list.append(value)

    return space.zero_vector()


def builtin_min(target_list, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Find the minimum value in a list.

    Args:
        target_list: The list to find minimum from
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        The minimum element as an LRVM vector
    """
    from eigenscript.evaluator.interpreter import EigenList

    # Must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("min requires a list")

    if len(target_list.elements) == 0:
        raise ValueError("min of empty list is undefined")

    # Find minimum by decoding values and comparing
    min_elem = target_list.elements[0]
    min_value = decode_vector(min_elem, space, metric)

    for elem in target_list.elements[1:]:
        value = decode_vector(elem, space, metric)
        if value < min_value:
            min_value = value
            min_elem = elem

    return min_elem


def builtin_max(target_list, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Find the maximum value in a list.

    Args:
        target_list: The list to find maximum from
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        The maximum element as an LRVM vector
    """
    from eigenscript.evaluator.interpreter import EigenList

    # Must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("max requires a list")

    if len(target_list.elements) == 0:
        raise ValueError("max of empty list is undefined")

    # Find maximum by decoding values and comparing
    max_elem = target_list.elements[0]
    max_value = decode_vector(max_elem, space, metric)

    for elem in target_list.elements[1:]:
        value = decode_vector(elem, space, metric)
        if value > max_value:
            max_value = value
            max_elem = elem

    return max_elem


def builtin_sort(target_list, space: LRVMSpace, metric: Any = None):
    """
    Sort a list in ascending order (returns a new sorted list).

    Args:
        target_list: The list to sort
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        A new sorted EigenList
    """
    from eigenscript.evaluator.interpreter import EigenList

    # Must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("sort requires a list")

    if len(target_list.elements) == 0:
        return EigenList([])

    # Create list of (decoded_value, original_vector) pairs for sorting
    pairs = []
    for elem in target_list.elements:
        value = decode_vector(elem, space, metric)
        pairs.append((value, elem))

    # Sort by the decoded values
    sorted_pairs = sorted(pairs, key=lambda x: x[0])

    # Extract the sorted vectors
    sorted_elements = [pair[1] for pair in sorted_pairs]

    return EigenList(sorted_elements)


def builtin_pop(target_list, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Remove and return the last element from a list.

    Args:
        target_list: The list to pop from
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        The popped element as an LRVM vector
    """
    from eigenscript.evaluator.interpreter import EigenList

    # Must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("pop requires a list")

    # Pop and return the element
    try:
        return target_list.pop()
    except IndexError as e:
        raise RuntimeError(str(e))


def builtin_map(args, space: LRVMSpace, metric: Any = None):
    """
    Transform each element in a list using a function.

    Map applies a function to every element in a list, returning a new list
    with the transformed values. This is a fundamental functional programming
    operation that leverages EigenScript's geometric semantics.

    Example:
        define double as:
            return arg * 2

        numbers is [1, 2, 3, 4, 5]
        doubled is map of [double, numbers]
        # doubled = [2, 4, 6, 8, 10]

    Args:
        args: Two-element list [function, target_list]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        A new EigenList with the function applied to each element
    """
    from eigenscript.evaluator.interpreter import EigenList, Function, BuiltinFunction

    # Expect args to be an EigenList with 2 elements: [function, list]
    if not isinstance(args, EigenList):
        raise TypeError("map requires a function and a list")

    if len(args.elements) != 2:
        raise TypeError("map requires exactly 2 arguments: function and list")

    func = args.elements[0]
    target_list = args.elements[1]

    # Function must be a Function or BuiltinFunction object
    if not isinstance(func, (Function, BuiltinFunction)):
        raise TypeError("First argument to map must be a function")

    # Second argument must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("Second argument to map must be a list")

    # Apply the function to each element
    result_elements = []
    for elem in target_list.elements:
        # Call the function with the element
        if isinstance(func, Function):
            # Use the interpreter stored in the function
            if func.interpreter is None:
                raise RuntimeError(
                    "Cannot call user-defined function from map without interpreter context"
                )
            result = func.interpreter._call_function_with_value(func, elem)
        elif isinstance(func, BuiltinFunction):
            result = func.func(elem, space, metric)

        result_elements.append(result)

    return EigenList(result_elements)


def builtin_filter(args, space: LRVMSpace, metric: Any = None):
    """
    Select elements from a list that match a criteria function.

    Filter applies a predicate function to each element, keeping only those
    for which the function returns a truthy value (non-zero number or non-empty string).

    Example:
        define is_positive as:
            return arg > 0

        numbers is [-2, -1, 0, 1, 2, 3]
        positives is filter of [is_positive, numbers]
        # positives = [1, 2, 3]

    Args:
        args: Two-element list [predicate_function, target_list]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        A new EigenList containing only elements where predicate returns true
    """
    from eigenscript.evaluator.interpreter import EigenList, Function, BuiltinFunction

    # Expect args to be an EigenList with 2 elements: [function, list]
    if not isinstance(args, EigenList):
        raise TypeError("filter requires a function and a list")

    if len(args.elements) != 2:
        raise TypeError("filter requires exactly 2 arguments: function and list")

    predicate = args.elements[0]
    target_list = args.elements[1]

    # Predicate must be a Function or BuiltinFunction object
    if not isinstance(predicate, (Function, BuiltinFunction)):
        raise TypeError("First argument to filter must be a function")

    # Second argument must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("Second argument to filter must be a list")

    # Apply the predicate to each element and keep truthy results
    result_elements = []
    for elem in target_list.elements:
        # Call the predicate with the element
        if isinstance(predicate, Function):
            # Use the interpreter stored in the function
            if predicate.interpreter is None:
                raise RuntimeError(
                    "Cannot call user-defined function from filter without interpreter context"
                )
            result = predicate.interpreter._call_function_with_value(predicate, elem)
        elif isinstance(predicate, BuiltinFunction):
            result = predicate.func(elem, space, metric)

        # Check if result is truthy
        # Decode the result to determine truthiness
        decoded = decode_vector(result, space, metric)

        # Consider truthy: non-zero numbers, non-empty strings, non-null
        is_truthy = False
        if isinstance(decoded, (int, float)):
            is_truthy = decoded != 0
        elif isinstance(decoded, str):
            is_truthy = decoded != "" and decoded != "null"
        elif isinstance(decoded, list):
            is_truthy = len(decoded) > 0

        if is_truthy:
            result_elements.append(elem)

    return EigenList(result_elements)


def builtin_reduce(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Fold/accumulate a list into a single value using a binary function.

    Reduce applies a binary function cumulatively to the elements of a list,
    from left to right, reducing the list to a single value. The function should
    accept two arguments: the accumulator and the current element.

    Example:
        define add as:
            # Expects a two-element list [a, b]
            a is arg[0]
            b is arg[1]
            return a + b

        numbers is [1, 2, 3, 4, 5]
        sum is reduce of [add, numbers, 0]
        # sum = 15 (0+1+2+3+4+5)

    Args:
        args: Three-element list [function, target_list, initial_value]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        The accumulated result as an LRVM vector
    """
    from eigenscript.evaluator.interpreter import EigenList, Function, BuiltinFunction

    # Expect args to be an EigenList with 3 elements: [function, list, initial]
    if not isinstance(args, EigenList):
        raise TypeError("reduce requires a function, list, and initial value")

    if len(args.elements) != 3:
        raise TypeError(
            "reduce requires exactly 3 arguments: function, list, and initial value"
        )

    func = args.elements[0]
    target_list = args.elements[1]
    accumulator = args.elements[2]

    # Function must be a Function or BuiltinFunction object
    if not isinstance(func, (Function, BuiltinFunction)):
        raise TypeError("First argument to reduce must be a function")

    # Second argument must be an EigenList
    if not isinstance(target_list, EigenList):
        raise TypeError("Second argument to reduce must be a list")

    # Apply the function cumulatively
    for elem in target_list.elements:
        # Create a list [accumulator, elem] to pass to the function
        pair = EigenList([accumulator, elem])

        # Call the function with the pair
        if isinstance(func, Function):
            # Use the interpreter stored in the function
            if func.interpreter is None:
                raise RuntimeError(
                    "Cannot call user-defined function from reduce without interpreter context"
                )
            accumulator = func.interpreter._call_function_with_value(func, pair)
        elif isinstance(func, BuiltinFunction):
            accumulator = func.func(pair, space, metric)

    return accumulator


def builtin_sqrt(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate the square root of a number.

    Example:
        sqrt of 16  -> 4.0
        sqrt of 2   -> 1.414...

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Square root as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        if decoded < 0:
            raise ValueError("sqrt requires a non-negative number")
        return space.embed(math.sqrt(decoded))
    else:
        raise TypeError("sqrt requires a number argument")


def builtin_abs(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate the absolute value of a number.

    Example:
        abs of -5   -> 5
        abs of 3.14 -> 3.14

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Absolute value as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(abs(decoded))
    else:
        raise TypeError("abs requires a number argument")


def builtin_pow(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Raise a number to a power.

    Example:
        pow of [2, 3]   -> 8 (2^3)
        pow of [10, 2]  -> 100 (10^2)

    Args:
        args: Two-element list [base, exponent]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Result of base^exponent as LRVM vector
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(args, EigenList):
        raise TypeError("pow requires a list of [base, exponent]")

    if len(args.elements) != 2:
        raise TypeError("pow requires exactly 2 arguments: base and exponent")

    base = decode_vector(args.elements[0], space, metric)
    exponent = decode_vector(args.elements[1], space, metric)

    if isinstance(base, (int, float)) and isinstance(exponent, (int, float)):
        return space.embed(math.pow(base, exponent))
    else:
        raise TypeError("pow requires numeric arguments")


def builtin_log(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate the natural logarithm (base e) of a number.

    Example:
        log of 2.718281828  -> 1.0
        log of 1            -> 0.0

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Natural logarithm as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        if decoded <= 0:
            raise ValueError("log requires a positive number")
        return space.embed(math.log(decoded))
    else:
        raise TypeError("log requires a number argument")


def builtin_exp(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate e raised to the power of a number.

    Example:
        exp of 0  -> 1.0
        exp of 1  -> 2.718...

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        e^x as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(math.exp(decoded))
    else:
        raise TypeError("exp requires a number argument")


def builtin_sin(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate the sine of an angle in radians.

    Example:
        sin of 0     -> 0.0
        sin of 1.570 -> 1.0 (approximately π/2)

    Args:
        arg: Angle in radians as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Sine as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(math.sin(decoded))
    else:
        raise TypeError("sin requires a number argument")


def builtin_cos(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate the cosine of an angle in radians.

    Example:
        cos of 0     -> 1.0
        cos of 3.141 -> -1.0 (approximately π)

    Args:
        arg: Angle in radians as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Cosine as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(math.cos(decoded))
    else:
        raise TypeError("cos requires a number argument")


def builtin_tan(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Calculate the tangent of an angle in radians.

    Example:
        tan of 0     -> 0.0
        tan of 0.785 -> 1.0 (approximately π/4)

    Args:
        arg: Angle in radians as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Tangent as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(math.tan(decoded))
    else:
        raise TypeError("tan requires a number argument")


def builtin_floor(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Round a number down to the nearest integer.

    Example:
        floor of 3.7  -> 3
        floor of -2.3 -> -3

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Floor as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(float(math.floor(decoded)))
    else:
        raise TypeError("floor requires a number argument")


def builtin_ceil(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Round a number up to the nearest integer.

    Example:
        ceil of 3.2  -> 4
        ceil of -2.7 -> -2

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Ceiling as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(float(math.ceil(decoded)))
    else:
        raise TypeError("ceil requires a number argument")


def builtin_round(arg: LRVMVector, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Round a number to the nearest integer.

    Example:
        round of 3.5  -> 4
        round of 3.4  -> 3

    Args:
        arg: Number as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Rounded value as LRVM vector
    """
    decoded = decode_vector(arg, space, metric)

    if isinstance(decoded, (int, float)):
        return space.embed(float(round(decoded)))
    else:
        raise TypeError("round requires a number argument")


# ============================================================================
# File I/O Operations
# ============================================================================


def builtin_file_open(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Open a file and return a file handle.

    Args:
        args: Two-element list [filename, mode]
              mode can be "r" (read), "w" (write), "a" (append)
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        File handle as LRVM vector with file object in metadata

    Example:
        handle is file_open of ["data.txt", "r"]
        content is file_read of handle
        file_close of handle
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(args, EigenList):
        raise TypeError("file_open requires a list of [filename, mode]")

    if len(args.elements) != 2:
        raise TypeError("file_open requires exactly 2 arguments: filename and mode")

    filename = decode_vector(args.elements[0], space, metric)
    mode = decode_vector(args.elements[1], space, metric)

    if not isinstance(filename, str):
        raise TypeError("Filename must be a string")

    if not isinstance(mode, str):
        raise TypeError("Mode must be a string")

    if mode not in ["r", "w", "a", "rb", "wb", "ab"]:
        raise ValueError(
            f"Invalid mode '{mode}'. Must be 'r', 'w', or 'a' (with optional 'b' for binary)"
        )

    try:
        file_obj = open(filename, mode)
        # Store file object in vector metadata
        handle = space.zero_vector()
        handle.metadata["file_object"] = file_obj
        handle.metadata["filename"] = filename
        handle.metadata["mode"] = mode
        return handle
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {filename}")
    except PermissionError:
        raise PermissionError(f"Permission denied: {filename}")
    except Exception as e:
        raise RuntimeError(f"Error opening file {filename}: {str(e)}")


def builtin_file_read(
    handle: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Read the entire contents of a file.

    Args:
        handle: File handle from file_open
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        File contents as LRVM vector (string)

    Example:
        handle is file_open of ["data.txt", "r"]
        content is file_read of handle
        file_close of handle
    """
    if "file_object" not in handle.metadata:
        raise TypeError("file_read requires a valid file handle")

    file_obj = handle.metadata["file_object"]

    try:
        content = file_obj.read()
        if isinstance(content, bytes):
            content = content.decode("utf-8")
        return space.embed_string(content)
    except Exception as e:
        raise RuntimeError(f"Error reading file: {str(e)}")


def builtin_file_write(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Write content to a file.

    Args:
        args: Two-element list [handle, content]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Null vector

    Example:
        handle is file_open of ["output.txt", "w"]
        file_write of [handle, "Hello, world!"]
        file_close of handle
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(args, EigenList):
        raise TypeError("file_write requires a list of [handle, content]")

    if len(args.elements) != 2:
        raise TypeError("file_write requires exactly 2 arguments: handle and content")

    handle = args.elements[0]
    content = decode_vector(args.elements[1], space, metric)

    if "file_object" not in handle.metadata:
        raise TypeError("file_write requires a valid file handle")

    file_obj = handle.metadata["file_object"]

    try:
        content_str = str(content)
        file_obj.write(content_str)
        file_obj.flush()  # Ensure data is written
        return space.zero_vector()
    except Exception as e:
        raise RuntimeError(f"Error writing to file: {str(e)}")


def builtin_file_close(
    handle: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Close a file handle.

    Args:
        handle: File handle from file_open
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Null vector

    Example:
        handle is file_open of ["data.txt", "r"]
        file_close of handle
    """
    if "file_object" not in handle.metadata:
        raise TypeError("file_close requires a valid file handle")

    file_obj = handle.metadata["file_object"]

    try:
        file_obj.close()
        # Clear the file object from metadata
        del handle.metadata["file_object"]
        return space.zero_vector()
    except Exception as e:
        raise RuntimeError(f"Error closing file: {str(e)}")


def builtin_file_exists(
    path: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Check if a file or directory exists.

    Args:
        path: File path as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        1 if exists, 0 if not (as LRVM vector)

    Example:
        exists is file_exists of "data.txt"
        if exists:
            # file exists
    """
    path_str = decode_vector(path, space, metric)

    if not isinstance(path_str, str):
        raise TypeError("file_exists requires a string path")

    exists = os.path.exists(path_str)
    return space.embed(1.0 if exists else 0.0)


def builtin_list_dir(path: LRVMVector, space: LRVMSpace, metric: Any = None):
    """
    List files and directories in a directory.

    Args:
        path: Directory path as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        EigenList of filenames

    Example:
        files is list_dir of "."
        print of files
    """
    from eigenscript.evaluator.interpreter import EigenList

    path_str = decode_vector(path, space, metric)

    if not isinstance(path_str, str):
        raise TypeError("list_dir requires a string path")

    try:
        entries = os.listdir(path_str)
        # Convert each filename to an LRVM vector
        entry_vectors = [space.embed_string(entry) for entry in entries]
        return EigenList(entry_vectors)
    except FileNotFoundError:
        raise FileNotFoundError(f"Directory not found: {path_str}")
    except PermissionError:
        raise PermissionError(f"Permission denied: {path_str}")
    except Exception as e:
        raise RuntimeError(f"Error listing directory {path_str}: {str(e)}")


def builtin_file_size(
    path: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Get the size of a file in bytes.

    Args:
        path: File path as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        File size in bytes as LRVM vector

    Example:
        size is file_size of "data.txt"
        print of size
    """
    path_str = decode_vector(path, space, metric)

    if not isinstance(path_str, str):
        raise TypeError("file_size requires a string path")

    try:
        size = os.path.getsize(path_str)
        return space.embed(float(size))
    except FileNotFoundError:
        raise FileNotFoundError(f"File not found: {path_str}")
    except Exception as e:
        raise RuntimeError(f"Error getting file size for {path_str}: {str(e)}")


def builtin_dirname(
    path: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Get the directory name from a path.

    Args:
        path: File path as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Directory name as LRVM vector

    Example:
        dir is dirname of "/path/to/file.txt"  # "/path/to"
    """
    path_str = decode_vector(path, space, metric)

    if not isinstance(path_str, str):
        raise TypeError("dirname requires a string path")

    dir_name = os.path.dirname(path_str)
    return space.embed_string(dir_name if dir_name else ".")


def builtin_basename(
    path: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Get the base name from a path.

    Args:
        path: File path as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Base name as LRVM vector

    Example:
        name is basename of "/path/to/file.txt"  # "file.txt"
    """
    path_str = decode_vector(path, space, metric)

    if not isinstance(path_str, str):
        raise TypeError("basename requires a string path")

    base_name = os.path.basename(path_str)
    return space.embed_string(base_name)


def builtin_absolute_path(
    path: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Get the absolute path from a relative path.

    Args:
        path: File path as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Absolute path as LRVM vector

    Example:
        abs_path is absolute_path of "data.txt"
    """
    path_str = decode_vector(path, space, metric)

    if not isinstance(path_str, str):
        raise TypeError("absolute_path requires a string path")

    abs_path = os.path.abspath(path_str)
    return space.embed_string(abs_path)


# ============================================================================
# JSON Support
# ============================================================================


def builtin_json_parse(json_str: LRVMVector, space: LRVMSpace, metric: Any = None):
    """
    Parse a JSON string into EigenScript data structures.

    Args:
        json_str: JSON string as LRVM vector
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Parsed data as LRVM vector or EigenList

    Example:
        data is json_parse of '{"name": "Alice", "age": 30}'
    """
    json_string = decode_vector(json_str, space, metric)

    if not isinstance(json_string, str):
        raise TypeError("json_parse requires a string argument")

    try:
        parsed = json.loads(json_string)
        return _python_to_eigenscript(parsed, space)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON: {str(e)}")
    except Exception as e:
        raise RuntimeError(f"Error parsing JSON: {str(e)}")


def builtin_json_stringify(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Convert EigenScript data to a JSON string.

    Args:
        args: Either a single value or [value, indent] where indent is number of spaces
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        JSON string as LRVM vector

    Example:
        json_str is json_stringify of data
        pretty_json is json_stringify of [data, 2]
    """
    from eigenscript.evaluator.interpreter import EigenList

    # Handle both single value and [value, indent] formats
    # Need to check if second element is a scalar number (indent) vs nested list
    if isinstance(args, EigenList) and len(args.elements) == 2:
        # Check if second element is a scalar number (indent parameter)
        second_elem = args.elements[1]
        try:
            # Try to decode as a number
            if not isinstance(second_elem, EigenList):
                indent_value = decode_vector(second_elem, space, metric)
                if isinstance(indent_value, (int, float)):
                    # This is [value, indent] format
                    value = args.elements[0]
                    indent = int(indent_value)
                else:
                    # Not a number, treat whole thing as value to stringify
                    value = args
                    indent = None
            else:
                # Second element is a list, so this is a nested list, not [value, indent]
                value = args
                indent = None
        except Exception:
            # If decode fails, treat as regular value
            value = args
            indent = None
    else:
        value = args
        indent = None

    try:
        python_obj = _eigenscript_to_python(value, space, metric)
        json_str = json.dumps(python_obj, indent=indent)
        return space.embed_string(json_str)
    except Exception as e:
        raise RuntimeError(f"Error stringifying JSON: {str(e)}")


def _python_to_eigenscript(obj: Any, space: LRVMSpace):
    """Convert Python objects to EigenScript values."""
    from eigenscript.evaluator.interpreter import EigenList

    if obj is None:
        return space.zero_vector()
    elif isinstance(obj, bool):
        return space.embed(1.0 if obj else 0.0)
    elif isinstance(obj, (int, float)):
        return space.embed(float(obj))
    elif isinstance(obj, str):
        return space.embed_string(obj)
    elif isinstance(obj, list):
        elements = [_python_to_eigenscript(item, space) for item in obj]
        return EigenList(elements)
    elif isinstance(obj, dict):
        # For now, store dict as a list of [key, value] pairs
        # Future: implement proper dict type
        pairs = []
        for key, value in obj.items():
            key_vec = space.embed_string(str(key))
            value_vec = _python_to_eigenscript(value, space)
            pairs.append(EigenList([key_vec, value_vec]))
        return EigenList(pairs)
    else:
        raise TypeError(f"Cannot convert Python type {type(obj)} to EigenScript")


def _eigenscript_to_python(value: Any, space: LRVMSpace, metric: Any = None) -> Any:
    """Convert EigenScript values to Python objects."""
    from eigenscript.evaluator.interpreter import EigenList

    if isinstance(value, EigenList):
        # Check if it's a dict representation (list of [key, value] pairs)
        # A dict should have string keys (not numeric), so we need to check more carefully
        if len(value.elements) > 0:
            # Try to detect dict format: all elements are 2-element lists with string keys
            is_dict = all(
                isinstance(elem, EigenList) and len(elem.elements) == 2
                for elem in value.elements
            )

            if is_dict:
                # Check if first element of each pair is a string (dict keys should be strings)
                try:
                    first_keys_are_strings = all(
                        isinstance(decode_vector(elem.elements[0], space, metric), str)
                        for elem in value.elements
                    )
                except Exception:
                    first_keys_are_strings = False

                if first_keys_are_strings:
                    # Convert to Python dict
                    result = {}
                    for pair in value.elements:
                        key = decode_vector(pair.elements[0], space, metric)
                        val = _eigenscript_to_python(pair.elements[1], space, metric)
                        result[key] = val
                    return result

        # Otherwise, convert as a list
        return [_eigenscript_to_python(elem, space, metric) for elem in value.elements]
    else:
        decoded = decode_vector(value, space, metric)
        if decoded == "null":
            return None
        return decoded


# ============================================================================
# Date/Time Operations
# ============================================================================


def builtin_time_now(
    arg: LRVMVector, space: LRVMSpace, metric: Any = None
) -> LRVMVector:
    """
    Get the current Unix timestamp.

    Args:
        arg: Ignored (pass null)
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Current Unix timestamp as LRVM vector

    Example:
        now is time_now of null
    """
    timestamp = time.time()
    return space.embed(timestamp)


def builtin_time_format(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Format a timestamp as a string.

    Args:
        args: Two-element list [timestamp, format_string]
              Format uses strftime syntax (e.g., "%Y-%m-%d %H:%M:%S")
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Formatted time string as LRVM vector

    Example:
        formatted is time_format of [now, "%Y-%m-%d"]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(args, EigenList):
        raise TypeError("time_format requires a list of [timestamp, format]")

    if len(args.elements) != 2:
        raise TypeError(
            "time_format requires exactly 2 arguments: timestamp and format"
        )

    timestamp = decode_vector(args.elements[0], space, metric)
    format_str = decode_vector(args.elements[1], space, metric)

    if not isinstance(timestamp, (int, float)):
        raise TypeError("Timestamp must be a number")

    if not isinstance(format_str, str):
        raise TypeError("Format must be a string")

    try:
        dt = datetime.fromtimestamp(timestamp)
        formatted = dt.strftime(format_str)
        return space.embed_string(formatted)
    except Exception as e:
        raise RuntimeError(f"Error formatting time: {str(e)}")


def builtin_time_parse(args, space: LRVMSpace, metric: Any = None) -> LRVMVector:
    """
    Parse a time string into a Unix timestamp.

    Args:
        args: Two-element list [time_string, format_string]
              Format uses strftime syntax (e.g., "%Y-%m-%d %H:%M:%S")
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Unix timestamp as LRVM vector

    Example:
        timestamp is time_parse of ["2025-11-19", "%Y-%m-%d"]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(args, EigenList):
        raise TypeError("time_parse requires a list of [time_string, format]")

    if len(args.elements) != 2:
        raise TypeError(
            "time_parse requires exactly 2 arguments: time string and format"
        )

    time_str = decode_vector(args.elements[0], space, metric)
    format_str = decode_vector(args.elements[1], space, metric)

    if not isinstance(time_str, str):
        raise TypeError("Time string must be a string")

    if not isinstance(format_str, str):
        raise TypeError("Format must be a string")

    try:
        dt = datetime.strptime(time_str, format_str)
        timestamp = dt.timestamp()
        return space.embed(timestamp)
    except Exception as e:
        raise RuntimeError(f"Error parsing time: {str(e)}")


# ============================================================================
# Enhanced List Operations
# ============================================================================


def builtin_zip(args, space: LRVMSpace, metric: Any = None):
    """
    Combine multiple lists element-wise into a list of lists.

    Args:
        args: List of lists to zip together
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        EigenList of paired elements

    Example:
        list1 is [1, 2, 3]
        list2 is ["a", "b", "c"]
        zipped is zip of [list1, list2]
        # Result: [[1, "a"], [2, "b"], [3, "c"]]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(args, EigenList):
        raise TypeError("zip requires a list of lists")

    # Each element should be a list
    lists = []
    for elem in args.elements:
        if not isinstance(elem, EigenList):
            raise TypeError("zip requires a list of lists")
        lists.append(elem.elements)

    if len(lists) == 0:
        return EigenList([])

    # Zip the lists together (stop at shortest list)
    min_length = min(len(lst) for lst in lists)
    result = []

    for i in range(min_length):
        # Create a list of the i-th element from each list
        tuple_elements = [lst[i] for lst in lists]
        result.append(EigenList(tuple_elements))

    return EigenList(result)


def builtin_enumerate(target_list, space: LRVMSpace, metric: Any = None):
    """
    Add indices to list elements.

    Args:
        target_list: List to enumerate
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        EigenList of [index, element] pairs

    Example:
        items is ["apple", "banana", "cherry"]
        indexed is enumerate of items
        # Result: [[0, "apple"], [1, "banana"], [2, "cherry"]]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(target_list, EigenList):
        raise TypeError("enumerate requires a list")

    result = []
    for i, elem in enumerate(target_list.elements):
        index_vec = space.embed(float(i))
        result.append(EigenList([index_vec, elem]))

    return EigenList(result)


def builtin_flatten(target_list, space: LRVMSpace, metric: Any = None):
    """
    Flatten a nested list by one level.

    Args:
        target_list: Nested list to flatten
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Flattened EigenList

    Example:
        nested is [[1, 2], [3, 4], [5]]
        flat is flatten of nested
        # Result: [1, 2, 3, 4, 5]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(target_list, EigenList):
        raise TypeError("flatten requires a list")

    result = []
    for elem in target_list.elements:
        if isinstance(elem, EigenList):
            # Add all elements from the nested list
            result.extend(elem.elements)
        else:
            # Add the element as-is
            result.append(elem)

    return EigenList(result)


def builtin_reverse(target_list, space: LRVMSpace, metric: Any = None):
    """
    Reverse the order of elements in a list.

    Args:
        target_list: List to reverse
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Reversed EigenList

    Example:
        items is [1, 2, 3, 4, 5]
        reversed is reverse of items
        # Result: [5, 4, 3, 2, 1]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(target_list, EigenList):
        raise TypeError("reverse requires a list")

    reversed_elements = list(reversed(target_list.elements))
    return EigenList(reversed_elements)


# ============================================================================
# Matrix Operations for AI/ML
# ============================================================================


def builtin_matrix_create(arg, space: LRVMSpace, metric: Any = None):
    """
    Create a matrix from a nested list.

    Args:
        arg: Nested EigenList to convert to matrix
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix object wrapped in LRVM vector

    Example:
        m is matrix of [[1, 2], [3, 4]]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList):
        raise TypeError("matrix requires a list")

    # Convert EigenList to nested Python list
    def to_python_list(eigen_list):
        result = []
        for elem in eigen_list.elements:
            if isinstance(elem, EigenList):
                result.append(to_python_list(elem))
            else:
                # Decode LRVM vector to Python value
                decoded = decode_vector(elem, space, metric)
                result.append(
                    float(decoded) if isinstance(decoded, (int, float)) else decoded
                )
        return result

    data = to_python_list(arg)
    matrix = Matrix(data)

    # Store matrix in LRVM vector metadata
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = matrix
    return result_vec


def builtin_matrix_zeros(arg, space: LRVMSpace, metric: Any = None):
    """
    Create a matrix of zeros.

    Args:
        arg: List of [rows, cols]
        space: LRVM space
        metric: Metric tensor (optional)

    Returns:
        Zero matrix

    Example:
        m is zeros of [3, 4]  # 3x4 zero matrix
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("zeros requires a list of [rows, cols]")

    rows = int(decode_vector(arg.elements[0], space, metric))
    cols = int(decode_vector(arg.elements[1], space, metric))

    matrix = Matrix.zeros(rows, cols)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = matrix
    return result_vec


def builtin_matrix_ones(arg, space: LRVMSpace, metric: Any = None):
    """Create a matrix of ones."""
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("ones requires a list of [rows, cols]")

    rows = int(decode_vector(arg.elements[0], space, metric))
    cols = int(decode_vector(arg.elements[1], space, metric))

    matrix = Matrix.ones(rows, cols)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = matrix
    return result_vec


def builtin_matrix_identity(arg, space: LRVMSpace, metric: Any = None):
    """Create an identity matrix."""
    from eigenscript.semantic.matrix import Matrix

    size = int(decode_vector(arg, space, metric))
    matrix = Matrix.identity(size)

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = matrix
    return result_vec


def builtin_matrix_transpose(arg, space: LRVMSpace, metric: Any = None):
    """
    Transpose a matrix.

    Args:
        arg: Matrix to transpose
        space: LRVM space
        metric: Metric tensor (optional)

    Returns:
        Transposed matrix

    Example:
        mt is transpose of m
    """
    if "matrix" not in arg.metadata:
        raise TypeError("transpose requires a matrix")

    matrix = arg.metadata["matrix"]
    transposed = matrix.transpose()

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = transposed
    return result_vec


def builtin_matrix_matmul(arg, space: LRVMSpace, metric: Any = None):
    """
    Matrix multiplication.

    Args:
        arg: List of [matrix1, matrix2]
        space: LRVM space
        metric: Metric tensor (optional)

    Returns:
        Product matrix

    Example:
        c is matmul of [a, b]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("matmul requires a list of [matrix1, matrix2]")

    m1_vec = arg.elements[0]
    m2_vec = arg.elements[1]

    if "matrix" not in m1_vec.metadata or "matrix" not in m2_vec.metadata:
        raise TypeError("matmul requires two matrices")

    m1 = m1_vec.metadata["matrix"]
    m2 = m2_vec.metadata["matrix"]

    result_matrix = m1.matmul(m2)

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_det(arg, space: LRVMSpace, metric: Any = None):
    """
    Compute determinant of a matrix.

    Args:
        arg: Square matrix
        space: LRVM space
        metric: Metric tensor (optional)

    Returns:
        Determinant as scalar

    Example:
        d is det of m
    """
    if "matrix" not in arg.metadata:
        raise TypeError("det requires a matrix")

    matrix = arg.metadata["matrix"]
    determinant = matrix.det()

    return space.embed(determinant)


def builtin_matrix_inv(arg, space: LRVMSpace, metric: Any = None):
    """Compute matrix inverse."""
    if "matrix" not in arg.metadata:
        raise TypeError("inv requires a matrix")

    matrix = arg.metadata["matrix"]
    inverse = matrix.inv()

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = inverse
    return result_vec


def builtin_matrix_eigenvalues(arg, space: LRVMSpace, metric: Any = None):
    """
    Compute eigenvalues of a matrix.

    Returns a list of eigenvalues.
    """
    from eigenscript.evaluator.interpreter import EigenList

    if "matrix" not in arg.metadata:
        raise TypeError("eigenvalues requires a matrix")

    matrix = arg.metadata["matrix"]
    eigenvals, eigenvecs = matrix.eigenvalues()

    # Convert eigenvalues to EigenList
    eigen_list = []
    for val in eigenvals:
        # Handle complex eigenvalues
        if isinstance(val, complex):
            real_val = val.real
        else:
            real_val = float(val)
        eigen_list.append(space.embed(real_val))

    return EigenList(eigen_list)


# ============================================================================
# Neural Network Operations for Transformers
# ============================================================================


def builtin_softmax_matrix(arg, space: LRVMSpace, metric: Any = None):
    """
    Apply softmax along rows of a matrix.

    Softmax converts each row to a probability distribution:
    softmax(x_i) = exp(x_i) / sum(exp(x_j))

    Args:
        arg: Matrix to apply softmax to
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix with softmax applied to each row

    Example:
        scores is matmul of [query, transpose of key]
        weights is softmax_matrix of scores
    """
    if "matrix" not in arg.metadata:
        raise TypeError("softmax_matrix requires a matrix")

    from eigenscript.semantic.matrix import Matrix

    matrix = arg.metadata["matrix"]
    data = matrix.data

    # Numerical stability: subtract max from each row
    row_max = np.max(data, axis=1, keepdims=True)
    exp_shifted = np.exp(data - row_max)
    softmax_out = exp_shifted / np.sum(exp_shifted, axis=1, keepdims=True)

    result_matrix = Matrix(softmax_out)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_layer_norm_matrix(arg, space: LRVMSpace, metric: Any = None):
    """
    Apply layer normalization to a matrix.

    Normalizes each row to have mean 0 and variance 1:
    LN(x) = (x - mean(x)) / sqrt(var(x) + eps)

    Args:
        arg: Matrix to normalize
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Layer-normalized matrix

    Example:
        normalized is layer_norm_matrix of hidden_states
    """
    if "matrix" not in arg.metadata:
        raise TypeError("layer_norm_matrix requires a matrix")

    from eigenscript.semantic.matrix import Matrix

    matrix = arg.metadata["matrix"]
    data = matrix.data
    eps = 1e-5

    # Compute mean and variance along each row
    mean = np.mean(data, axis=1, keepdims=True)
    var = np.var(data, axis=1, keepdims=True)

    # Normalize
    normalized = (data - mean) / np.sqrt(var + eps)

    result_matrix = Matrix(normalized)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_random_matrix(arg, space: LRVMSpace, metric: Any = None):
    """
    Create a random matrix with Xavier/Glorot initialization.

    Xavier initialization helps with gradient flow in deep networks:
    scale = sqrt(2 / (fan_in + fan_out))

    Args:
        arg: List of [rows, cols]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Random matrix with Xavier initialization

    Example:
        weights is random_matrix of [512, 512]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("random_matrix requires a list of [rows, cols]")

    rows = int(decode_vector(arg.elements[0], space, metric))
    cols = int(decode_vector(arg.elements[1], space, metric))

    # Xavier/Glorot initialization
    scale = np.sqrt(2.0 / (rows + cols))
    data = np.random.randn(rows, cols) * scale

    result_matrix = Matrix(data)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_relu_matrix(arg, space: LRVMSpace, metric: Any = None):
    """
    Apply ReLU activation to a matrix element-wise.

    ReLU(x) = max(0, x)

    Args:
        arg: Matrix to apply ReLU to
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix with ReLU applied

    Example:
        activated is relu_matrix of hidden
    """
    if "matrix" not in arg.metadata:
        raise TypeError("relu_matrix requires a matrix")

    from eigenscript.semantic.matrix import Matrix

    matrix = arg.metadata["matrix"]
    relu_data = np.maximum(0, matrix.data)

    result_matrix = Matrix(relu_data)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_gelu_matrix(arg, space: LRVMSpace, metric: Any = None):
    """
    Apply GELU activation to a matrix element-wise.

    GELU(x) = x * Φ(x) where Φ is the CDF of standard normal.
    Approximation: 0.5 * x * (1 + tanh(sqrt(2/π) * (x + 0.044715 * x^3)))

    Args:
        arg: Matrix to apply GELU to
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix with GELU applied

    Example:
        activated is gelu_matrix of hidden
    """
    if "matrix" not in arg.metadata:
        raise TypeError("gelu_matrix requires a matrix")

    from eigenscript.semantic.matrix import Matrix

    matrix = arg.metadata["matrix"]
    x = matrix.data

    # GELU approximation
    gelu_data = 0.5 * x * (1 + np.tanh(np.sqrt(2 / np.pi) * (x + 0.044715 * x**3)))

    result_matrix = Matrix(gelu_data)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_add(arg, space: LRVMSpace, metric: Any = None):
    """
    Add two matrices element-wise.

    Args:
        arg: List of [matrix1, matrix2]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Sum of the two matrices

    Example:
        output is matrix_add of [residual, attention_output]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("matrix_add requires a list of [matrix1, matrix2]")

    m1_vec = arg.elements[0]
    m2_vec = arg.elements[1]

    if "matrix" not in m1_vec.metadata or "matrix" not in m2_vec.metadata:
        raise TypeError("matrix_add requires two matrices")

    m1 = m1_vec.metadata["matrix"]
    m2 = m2_vec.metadata["matrix"]

    result_matrix = m1 + m2

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_scale(arg, space: LRVMSpace, metric: Any = None):
    """
    Scale a matrix by a scalar value.

    Args:
        arg: List of [matrix, scalar]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Scaled matrix

    Example:
        # Scale attention scores by 1/sqrt(d_k)
        scaled is matrix_scale of [scores, 0.125]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("matrix_scale requires a list of [matrix, scalar]")

    m_vec = arg.elements[0]
    scalar = decode_vector(arg.elements[1], space, metric)

    if "matrix" not in m_vec.metadata:
        raise TypeError("First argument to matrix_scale must be a matrix")

    matrix = m_vec.metadata["matrix"]
    scaled = matrix * float(scalar)

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = scaled
    return result_vec


def builtin_matrix_shape(arg, space: LRVMSpace, metric: Any = None):
    """
    Get the shape of a matrix as [rows, cols].

    Args:
        arg: Matrix to get shape of
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        EigenList of [rows, cols]

    Example:
        shape is matrix_shape of weights
        rows is shape[0]
        cols is shape[1]
    """
    from eigenscript.evaluator.interpreter import EigenList

    if "matrix" not in arg.metadata:
        raise TypeError("matrix_shape requires a matrix")

    matrix = arg.metadata["matrix"]
    rows, cols = matrix.shape

    return EigenList([space.embed(float(rows)), space.embed(float(cols))])


def builtin_matrix_sum(arg, space: LRVMSpace, metric: Any = None):
    """
    Sum all elements in a matrix.

    Args:
        arg: Matrix to sum
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Sum as a scalar

    Example:
        total is matrix_sum of loss_matrix
    """
    if "matrix" not in arg.metadata:
        raise TypeError("matrix_sum requires a matrix")

    matrix = arg.metadata["matrix"]
    total = float(np.sum(matrix.data))

    return space.embed(total)


def builtin_matrix_mean(arg, space: LRVMSpace, metric: Any = None):
    """
    Compute the mean of all elements in a matrix.

    Args:
        arg: Matrix to compute mean of
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Mean as a scalar

    Example:
        avg_loss is matrix_mean of loss_matrix
    """
    if "matrix" not in arg.metadata:
        raise TypeError("matrix_mean requires a matrix")

    matrix = arg.metadata["matrix"]
    mean_val = float(np.mean(matrix.data))

    return space.embed(mean_val)


def builtin_matrix_sqrt(arg, space: LRVMSpace, metric: Any = None):
    """
    Element-wise square root of a matrix.

    Args:
        arg: Matrix to compute sqrt of
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix with sqrt applied element-wise

    Example:
        std is matrix_sqrt of variance
    """
    if "matrix" not in arg.metadata:
        raise TypeError("matrix_sqrt requires a matrix")

    from eigenscript.semantic.matrix import Matrix

    matrix = arg.metadata["matrix"]
    sqrt_data = np.sqrt(np.maximum(0, matrix.data))  # Clamp to avoid NaN

    result_matrix = Matrix(sqrt_data)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_exp(arg, space: LRVMSpace, metric: Any = None):
    """
    Element-wise exponential of a matrix.

    Args:
        arg: Matrix to compute exp of
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix with exp applied element-wise

    Example:
        exp_scores is matrix_exp of scores
    """
    if "matrix" not in arg.metadata:
        raise TypeError("matrix_exp requires a matrix")

    from eigenscript.semantic.matrix import Matrix

    matrix = arg.metadata["matrix"]
    # Clip to prevent overflow
    exp_data = np.exp(np.clip(matrix.data, -500, 500))

    result_matrix = Matrix(exp_data)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_sinusoidal_pe(arg, space: LRVMSpace, metric: Any = None):
    """
    Generate sinusoidal positional encoding matrix.

    Creates positional encodings using sin/cos functions as in
    "Attention Is All You Need" (Vaswani et al., 2017).

    Args:
        arg: List of [seq_len, d_model]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix of shape [seq_len, d_model] with positional encodings

    Example:
        pos_enc is sinusoidal_pe of [128, 512]
        embedded is matrix_add of [token_emb, pos_enc]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("sinusoidal_pe requires a list of [seq_len, d_model]")

    seq_len = int(decode_vector(arg.elements[0], space, metric))
    d_model = int(decode_vector(arg.elements[1], space, metric))

    # Create position and dimension indices
    position = np.arange(seq_len)[:, np.newaxis]
    div_term = np.exp(np.arange(0, d_model, 2) * -(np.log(10000.0) / d_model))

    # Compute positional encodings
    pe = np.zeros((seq_len, d_model))
    pe[:, 0::2] = np.sin(position * div_term)
    pe[:, 1::2] = np.cos(position * div_term[: d_model // 2])

    result_matrix = Matrix(pe)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_embedding_lookup(arg, space: LRVMSpace, metric: Any = None):
    """
    Look up embeddings from an embedding matrix.

    Args:
        arg: List of [embedding_matrix, indices]
              embedding_matrix: Matrix of shape [vocab_size, d_model]
              indices: List of integer indices

        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix of shape [len(indices), d_model] with embeddings

    Example:
        # Token indices: [1, 5, 3, 8]
        token_ids is [1, 5, 3, 8]
        embeddings is embedding_lookup of [embed_matrix, token_ids]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("embedding_lookup requires [embedding_matrix, indices]")

    embed_vec = arg.elements[0]
    indices = arg.elements[1]

    if "matrix" not in embed_vec.metadata:
        raise TypeError("First argument must be an embedding matrix")

    embed_matrix = embed_vec.metadata["matrix"]

    # Convert indices to Python list
    if isinstance(indices, EigenList):
        idx_list = [
            int(decode_vector(elem, space, metric)) for elem in indices.elements
        ]
    else:
        raise TypeError("Second argument must be a list of indices")

    # Look up embeddings
    selected = embed_matrix.data[idx_list, :]

    result_matrix = Matrix(selected)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_causal_mask(arg, space: LRVMSpace, metric: Any = None):
    """
    Create a causal (lower triangular) attention mask.

    Used for autoregressive decoding where position i can only
    attend to positions <= i.

    Args:
        arg: Sequence length
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix of shape [seq_len, seq_len] with -inf above diagonal

    Example:
        mask is causal_mask of 128
        masked_scores is matrix_add of [scores, mask]
    """
    from eigenscript.semantic.matrix import Matrix

    seq_len = int(decode_vector(arg, space, metric))

    # Create lower triangular mask
    # 0 for positions that can attend, -inf for positions that cannot
    mask = np.triu(np.ones((seq_len, seq_len)) * float("-inf"), k=1)

    result_matrix = Matrix(mask)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_reshape(arg, space: LRVMSpace, metric: Any = None):
    """
    Reshape a matrix to new dimensions.

    Args:
        arg: List of [matrix, rows, cols]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Reshaped matrix

    Example:
        # Reshape for multi-head attention
        reshaped is matrix_reshape of [query, 8, 64]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 3:
        raise TypeError("matrix_reshape requires [matrix, rows, cols]")

    m_vec = arg.elements[0]
    rows = int(decode_vector(arg.elements[1], space, metric))
    cols = int(decode_vector(arg.elements[2], space, metric))

    if "matrix" not in m_vec.metadata:
        raise TypeError("First argument must be a matrix")

    matrix = m_vec.metadata["matrix"]
    reshaped = matrix.reshape(rows, cols)

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = reshaped
    return result_vec


def builtin_matrix_concat(arg, space: LRVMSpace, metric: Any = None):
    """
    Concatenate matrices along rows (axis 0).

    Args:
        arg: List of matrices to concatenate
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Concatenated matrix

    Example:
        # Concatenate attention heads
        concat is matrix_concat of [head1, head2, head3, head4]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList):
        raise TypeError("matrix_concat requires a list of matrices")

    matrices = []
    for elem in arg.elements:
        if "matrix" not in elem.metadata:
            raise TypeError("All elements must be matrices")
        matrices.append(elem.metadata["matrix"].data)

    concatenated = np.concatenate(matrices, axis=0)

    result_matrix = Matrix(concatenated)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_slice(arg, space: LRVMSpace, metric: Any = None):
    """
    Slice rows from a matrix.

    Args:
        arg: List of [matrix, start_row, end_row]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Sliced matrix containing rows [start_row:end_row]

    Example:
        # Get first 64 rows (one attention head)
        head1 is matrix_slice of [queries, 0, 64]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 3:
        raise TypeError("matrix_slice requires [matrix, start_row, end_row]")

    m_vec = arg.elements[0]
    start = int(decode_vector(arg.elements[1], space, metric))
    end = int(decode_vector(arg.elements[2], space, metric))

    if "matrix" not in m_vec.metadata:
        raise TypeError("First argument must be a matrix")

    matrix = m_vec.metadata["matrix"]
    sliced = Matrix(matrix.data[start:end, :])

    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = sliced
    return result_vec


def builtin_dropout_matrix(arg, space: LRVMSpace, metric: Any = None):
    """
    Apply dropout to a matrix (for training).

    Randomly sets elements to 0 with probability p and scales
    remaining elements by 1/(1-p).

    Args:
        arg: List of [matrix, dropout_rate]
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        Matrix with dropout applied

    Example:
        dropped is dropout_matrix of [hidden, 0.1]
    """
    from eigenscript.evaluator.interpreter import EigenList
    from eigenscript.semantic.matrix import Matrix

    if not isinstance(arg, EigenList) or len(arg.elements) != 2:
        raise TypeError("dropout_matrix requires [matrix, dropout_rate]")

    m_vec = arg.elements[0]
    p = float(decode_vector(arg.elements[1], space, metric))

    if "matrix" not in m_vec.metadata:
        raise TypeError("First argument must be a matrix")

    matrix = m_vec.metadata["matrix"]

    # Create dropout mask
    mask = np.random.binomial(1, 1 - p, size=matrix.data.shape)
    # Apply mask and scale
    dropped = matrix.data * mask / (1 - p + 1e-10)

    result_matrix = Matrix(dropped)
    result_vec = space.zero_vector()
    result_vec.metadata["matrix"] = result_matrix
    return result_vec


def builtin_matrix_to_list(arg, space: LRVMSpace, metric: Any = None):
    """
    Convert a matrix to a nested list.

    Args:
        arg: Matrix to convert
        space: LRVM space for operations
        metric: Metric tensor (optional)

    Returns:
        EigenList of lists representing the matrix

    Example:
        data is matrix_to_list of result
    """
    from eigenscript.evaluator.interpreter import EigenList

    if "matrix" not in arg.metadata:
        raise TypeError("matrix_to_list requires a matrix")

    matrix = arg.metadata["matrix"]
    rows = []

    for row in matrix.data:
        row_elems = [space.embed(float(val)) for val in row]
        rows.append(EigenList(row_elems))

    return EigenList(rows)


def get_builtins(space: LRVMSpace) -> dict:
    """
    Get all built-in functions for the EigenScript environment.

    Args:
        space: LRVM space for the interpreter

    Returns:
        Dictionary mapping function names to BuiltinFunction objects
    """
    builtins = {
        "print": BuiltinFunction(
            name="print", func=builtin_print, description="Print a value to stdout"
        ),
        "input": BuiltinFunction(
            name="input", func=builtin_input, description="Read a line from stdin"
        ),
        "len": BuiltinFunction(
            name="len",
            func=builtin_len,
            description="Get the length/magnitude of a value",
        ),
        "type": BuiltinFunction(
            name="type", func=builtin_type, description="Get the type of a value"
        ),
        "norm": BuiltinFunction(
            name="norm",
            func=builtin_norm,
            description="Get the geometric norm of a vector",
        ),
        "range": BuiltinFunction(
            name="range", func=builtin_range, description="Generate a range of numbers"
        ),
        "upper": BuiltinFunction(
            name="upper", func=builtin_upper, description="Convert string to uppercase"
        ),
        "lower": BuiltinFunction(
            name="lower", func=builtin_lower, description="Convert string to lowercase"
        ),
        "split": BuiltinFunction(
            name="split",
            func=builtin_split,
            description="Split string into list of words",
        ),
        "join": BuiltinFunction(
            name="join",
            func=builtin_join,
            description="Join list of strings into a single string",
        ),
        "append": BuiltinFunction(
            name="append",
            func=builtin_append,
            description="Append an element to a list",
        ),
        "pop": BuiltinFunction(
            name="pop",
            func=builtin_pop,
            description="Remove and return the last element from a list",
        ),
        "min": BuiltinFunction(
            name="min", func=builtin_min, description="Find the minimum value in a list"
        ),
        "max": BuiltinFunction(
            name="max", func=builtin_max, description="Find the maximum value in a list"
        ),
        "sort": BuiltinFunction(
            name="sort", func=builtin_sort, description="Sort a list in ascending order"
        ),
        "map": BuiltinFunction(
            name="map",
            func=builtin_map,
            description="Transform each element in a list using a function",
        ),
        "filter": BuiltinFunction(
            name="filter",
            func=builtin_filter,
            description="Select elements matching criteria",
        ),
        "reduce": BuiltinFunction(
            name="reduce",
            func=builtin_reduce,
            description="Fold/accumulate values with a function",
        ),
        "sqrt": BuiltinFunction(
            name="sqrt",
            func=builtin_sqrt,
            description="Calculate the square root of a number",
        ),
        "abs": BuiltinFunction(
            name="abs",
            func=builtin_abs,
            description="Calculate the absolute value of a number",
        ),
        "pow": BuiltinFunction(
            name="pow", func=builtin_pow, description="Raise a number to a power"
        ),
        "log": BuiltinFunction(
            name="log", func=builtin_log, description="Calculate the natural logarithm"
        ),
        "exp": BuiltinFunction(
            name="exp", func=builtin_exp, description="Calculate e raised to a power"
        ),
        "sin": BuiltinFunction(
            name="sin",
            func=builtin_sin,
            description="Calculate the sine of an angle in radians",
        ),
        "cos": BuiltinFunction(
            name="cos",
            func=builtin_cos,
            description="Calculate the cosine of an angle in radians",
        ),
        "tan": BuiltinFunction(
            name="tan",
            func=builtin_tan,
            description="Calculate the tangent of an angle in radians",
        ),
        "floor": BuiltinFunction(
            name="floor",
            func=builtin_floor,
            description="Round a number down to the nearest integer",
        ),
        "ceil": BuiltinFunction(
            name="ceil",
            func=builtin_ceil,
            description="Round a number up to the nearest integer",
        ),
        "round": BuiltinFunction(
            name="round",
            func=builtin_round,
            description="Round a number to the nearest integer",
        ),
        # File I/O operations
        "file_open": BuiltinFunction(
            name="file_open",
            func=builtin_file_open,
            description="Open a file and return a handle",
        ),
        "file_read": BuiltinFunction(
            name="file_read",
            func=builtin_file_read,
            description="Read the contents of a file",
        ),
        "file_write": BuiltinFunction(
            name="file_write",
            func=builtin_file_write,
            description="Write content to a file",
        ),
        "file_close": BuiltinFunction(
            name="file_close",
            func=builtin_file_close,
            description="Close a file handle",
        ),
        "file_exists": BuiltinFunction(
            name="file_exists",
            func=builtin_file_exists,
            description="Check if a file exists",
        ),
        "list_dir": BuiltinFunction(
            name="list_dir",
            func=builtin_list_dir,
            description="List files in a directory",
        ),
        "file_size": BuiltinFunction(
            name="file_size",
            func=builtin_file_size,
            description="Get the size of a file",
        ),
        "dirname": BuiltinFunction(
            name="dirname",
            func=builtin_dirname,
            description="Get directory name from path",
        ),
        "basename": BuiltinFunction(
            name="basename",
            func=builtin_basename,
            description="Get base name from path",
        ),
        "absolute_path": BuiltinFunction(
            name="absolute_path",
            func=builtin_absolute_path,
            description="Get absolute path from relative path",
        ),
        # JSON operations
        "json_parse": BuiltinFunction(
            name="json_parse",
            func=builtin_json_parse,
            description="Parse JSON string to data",
        ),
        "json_stringify": BuiltinFunction(
            name="json_stringify",
            func=builtin_json_stringify,
            description="Convert data to JSON string",
        ),
        # Date/Time operations
        "time_now": BuiltinFunction(
            name="time_now",
            func=builtin_time_now,
            description="Get current Unix timestamp",
        ),
        "time_format": BuiltinFunction(
            name="time_format",
            func=builtin_time_format,
            description="Format timestamp as string",
        ),
        "time_parse": BuiltinFunction(
            name="time_parse",
            func=builtin_time_parse,
            description="Parse time string to timestamp",
        ),
        # Enhanced list operations
        "zip": BuiltinFunction(
            name="zip", func=builtin_zip, description="Combine lists element-wise"
        ),
        "enumerate": BuiltinFunction(
            name="enumerate",
            func=builtin_enumerate,
            description="Add indices to list elements",
        ),
        "flatten": BuiltinFunction(
            name="flatten", func=builtin_flatten, description="Flatten nested lists"
        ),
        "reverse": BuiltinFunction(
            name="reverse", func=builtin_reverse, description="Reverse list order"
        ),
        # Matrix operations for AI/ML
        "matrix": BuiltinFunction(
            name="matrix",
            func=builtin_matrix_create,
            description="Create matrix from nested list",
        ),
        "zeros": BuiltinFunction(
            name="zeros",
            func=builtin_matrix_zeros,
            description="Create matrix of zeros",
        ),
        "ones": BuiltinFunction(
            name="ones", func=builtin_matrix_ones, description="Create matrix of ones"
        ),
        "identity": BuiltinFunction(
            name="identity",
            func=builtin_matrix_identity,
            description="Create identity matrix",
        ),
        "transpose": BuiltinFunction(
            name="transpose",
            func=builtin_matrix_transpose,
            description="Transpose a matrix",
        ),
        "matmul": BuiltinFunction(
            name="matmul",
            func=builtin_matrix_matmul,
            description="Matrix multiplication",
        ),
        "det": BuiltinFunction(
            name="det",
            func=builtin_matrix_det,
            description="Compute determinant",
        ),
        "inv": BuiltinFunction(
            name="inv", func=builtin_matrix_inv, description="Compute matrix inverse"
        ),
        "eigenvalues": BuiltinFunction(
            name="eigenvalues",
            func=builtin_matrix_eigenvalues,
            description="Compute eigenvalues",
        ),
        # Neural Network operations for Transformers
        "softmax_matrix": BuiltinFunction(
            name="softmax_matrix",
            func=builtin_softmax_matrix,
            description="Apply softmax to matrix rows",
        ),
        "layer_norm_matrix": BuiltinFunction(
            name="layer_norm_matrix",
            func=builtin_layer_norm_matrix,
            description="Apply layer normalization",
        ),
        "random_matrix": BuiltinFunction(
            name="random_matrix",
            func=builtin_random_matrix,
            description="Create random matrix with Xavier init",
        ),
        "relu_matrix": BuiltinFunction(
            name="relu_matrix",
            func=builtin_relu_matrix,
            description="Apply ReLU activation to matrix",
        ),
        "gelu_matrix": BuiltinFunction(
            name="gelu_matrix",
            func=builtin_gelu_matrix,
            description="Apply GELU activation to matrix",
        ),
        "matrix_add": BuiltinFunction(
            name="matrix_add",
            func=builtin_matrix_add,
            description="Add two matrices element-wise",
        ),
        "matrix_scale": BuiltinFunction(
            name="matrix_scale",
            func=builtin_matrix_scale,
            description="Scale matrix by scalar",
        ),
        "matrix_shape": BuiltinFunction(
            name="matrix_shape",
            func=builtin_matrix_shape,
            description="Get matrix dimensions",
        ),
        "matrix_sum": BuiltinFunction(
            name="matrix_sum",
            func=builtin_matrix_sum,
            description="Sum all matrix elements",
        ),
        "matrix_mean": BuiltinFunction(
            name="matrix_mean",
            func=builtin_matrix_mean,
            description="Mean of all matrix elements",
        ),
        "matrix_sqrt": BuiltinFunction(
            name="matrix_sqrt",
            func=builtin_matrix_sqrt,
            description="Element-wise square root",
        ),
        "matrix_exp": BuiltinFunction(
            name="matrix_exp",
            func=builtin_matrix_exp,
            description="Element-wise exponential",
        ),
        "sinusoidal_pe": BuiltinFunction(
            name="sinusoidal_pe",
            func=builtin_sinusoidal_pe,
            description="Generate sinusoidal positional encodings",
        ),
        "embedding_lookup": BuiltinFunction(
            name="embedding_lookup",
            func=builtin_embedding_lookup,
            description="Look up embeddings by indices",
        ),
        "causal_mask": BuiltinFunction(
            name="causal_mask",
            func=builtin_causal_mask,
            description="Create causal attention mask",
        ),
        "matrix_reshape": BuiltinFunction(
            name="matrix_reshape",
            func=builtin_matrix_reshape,
            description="Reshape matrix dimensions",
        ),
        "matrix_concat": BuiltinFunction(
            name="matrix_concat",
            func=builtin_matrix_concat,
            description="Concatenate matrices",
        ),
        "matrix_slice": BuiltinFunction(
            name="matrix_slice",
            func=builtin_matrix_slice,
            description="Slice rows from matrix",
        ),
        "dropout_matrix": BuiltinFunction(
            name="dropout_matrix",
            func=builtin_dropout_matrix,
            description="Apply dropout to matrix",
        ),
        "matrix_to_list": BuiltinFunction(
            name="matrix_to_list",
            func=builtin_matrix_to_list,
            description="Convert matrix to nested list",
        ),
    }

    return builtins
