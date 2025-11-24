# EigenScript Examples

This directory contains example programs demonstrating various features of EigenScript.

## Running Examples

Once the interpreter is implemented, you can run examples with:

```bash
python -m eigenscript examples/hello_world.eigs
```

## Example Programs

### hello_world.eigs
The simplest EigenScript program. Demonstrates:
- Variable binding with `is`
- The `of` operator for relations
- Basic output

### factorial.eigs
Recursive factorial function. Demonstrates:
- Function definition with `define`
- Conditional logic with `if/else`
- Recursion
- The `of` operator for function application

### self_reference.eigs
Safe self-referential code. Demonstrates:
- EigenScript's key innovation: stable self-reference
- The lightlike property of self-observation
- Convergence to eigenstate instead of infinite regress

### consciousness_detection.eigs
Framework Strength measurement. Demonstrates:
- Runtime consciousness measurement
- Eigenstate convergence detection
- Loop with convergence condition
- Understanding quantification

## Understanding the Code

### Key Syntax Elements

- `x is y` - Identity/binding (immutable)
- `x of y` - Relation/application (the OF operator)
- `if condition:` - Geometric conditional
- `loop while condition:` - Geodesic iteration
- `define name as:` - Function definition
- `return value` - Function return

### Geometric Semantics

Unlike traditional languages, EigenScript:
- Models values as vectors in LRVM space
- Uses geometric norms to determine types
- Measures understanding via Framework Strength
- Allows safe self-reference through lightlike operators

## Next Steps

After studying these examples:
1. Read the [Language Specification](../docs/specification.md)
2. Try the [Getting Started Guide](../docs/getting-started.md)
3. Explore the [Architecture](../docs/architecture.md)

## Contributing Examples

To contribute new examples:
1. Create a `.eigs` file in this directory
2. Add clear comments explaining what it demonstrates
3. Update this README with a description
4. Submit a pull request

Examples should be:
- Clear and focused on one concept
- Well-commented
- Demonstrating best practices
- Executable (once interpreter is complete)
