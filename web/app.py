"""
EigenScript Web Playground
Interactive web interface for running EigenScript code with full compiler support
"""

from flask import Flask, render_template, request, jsonify
import subprocess
import tempfile
import os

app = Flask(__name__)

# Example code snippets - comprehensive demos of all features
EXAMPLES = {
    "hello": """# Hello World
print of "Hello from EigenScript!"

x is 5
y is 3
print of "Sum:"
print of x + y
""",
    "convergence": """# Convergence Demo - The Inaugural Algorithm
# Watch a value converge to a target using damped oscillation

x is 0
target is 10
velocity is 0

print of "Converging to target..."

loop while x < 20:
    error is target - x
    velocity is velocity + (error * 0.1)
    velocity is velocity * 0.9
    x is x + velocity
    print of x

    if converged:
        print of "System converged!"
        break

print of "Final value:"
print of x
""",
    "factorial": """# Recursive Factorial
define factorial as:
    if n < 2:
        return 1
    prev is n - 1
    sub_result is factorial of prev
    return n * sub_result

print of "Factorial calculations:"
print of "5! ="
result is factorial of 5
print of result

print of "10! ="
result is factorial of 10
print of result

print of "12! ="
result is factorial of 12
print of result
""",
    "xor": """# XOR Neural Network Demo
# Implements XOR using threshold activation functions

define threshold as:
    x is arg
    if x > 0:
        return 1
    return 0

define compute_xor as:
    a is arg[0]
    b is arg[1]
    # OR gate
    or_val is threshold of (a + b - 0.5)
    # AND gate
    and_val is threshold of (a + b - 1.5)
    # NAND of the AND result
    nand_val is 1 - and_val
    # Final XOR = OR AND NAND
    result is threshold of (or_val + nand_val - 1.5)
    return result

print of "XOR Truth Table:"
print of "==============="
print of "XOR(0,0) ="
print of compute_xor of [0, 0]
print of "XOR(0,1) ="
print of compute_xor of [0, 1]
print of "XOR(1,0) ="
print of compute_xor of [1, 0]
print of "XOR(1,1) ="
print of compute_xor of [1, 1]
""",
    "matrix": """# Matrix Operations
# Linear algebra with EigenScript matrices

A is matrix of [[1, 2], [3, 4]]
B is matrix of [[5, 6], [7, 8]]

print of "Matrix A:"
A_list is matrix_to_list of A
print of A_list

print of "Matrix B:"
B_list is matrix_to_list of B
print of B_list

print of "A * B (matrix multiply):"
C is matmul of [A, B]
C_list is matrix_to_list of C
print of C_list

print of "A transposed:"
At is transpose of A
At_list is matrix_to_list of At
print of At_list

print of "Determinant of A:"
det is determinant of A
print of det
""",
    "attention": """# Scaled Dot-Product Attention
# Core mechanism of transformer models

Q is matrix of [[1.0, 0.0], [0.0, 1.0]]
K is matrix of [[1.0, 0.0], [0.0, 1.0]]
V is matrix of [[1.0, 2.0], [3.0, 4.0]]

print of "Query matrix Q:"
print of matrix_to_list of Q

print of "Key matrix K:"
print of matrix_to_list of K

print of "Value matrix V:"
print of matrix_to_list of V

print of "Computing attention..."

# Attention(Q, K, V) = softmax(QK^T / sqrt(d_k)) * V
K_t is transpose of K
scores is matmul of [Q, K_t]
scaled is matrix_scale of [scores, 0.707]
weights is softmax_matrix of scaled
output is matmul of [weights, V]

print of "Attention output:"
out_list is matrix_to_list of output
print of out_list

print of "Framework strength:"
fs is framework_strength
print of fs
""",
    "higher_order": """# Higher-Order Functions
# map, filter, reduce with custom functions

numbers is [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

define square as:
    return n * n

define is_even as:
    return (n % 2) is 0

define add as:
    return a + b

print of "Original list:"
print of numbers

print of "Squared (map):"
squared is map of [square, numbers]
print of squared

print of "Even numbers (filter):"
evens is filter of [is_even, numbers]
print of evens

print of "Sum (reduce):"
total is reduce of [add, numbers, 0]
print of total

print of "List comprehension - squares of evens:"
result is [square of x for x in numbers if is_even of x]
print of result
""",
    "geometric": """# Geometric Introspection
# EigenScript's self-aware predicates

print of "=== Geometric Predicates ==="
print of "Tracking computational state..."

counter is 0
limit is 25
prev_value is 0

loop while counter < limit:
    counter is counter + 1

    # Oscillating computation
    value is prev_value + (10 - prev_value) * 0.3
    prev_value is value

    if converged:
        print of "Converged at iteration:"
        print of counter
        break

    if stable:
        print of "Stable at iteration:"
        print of counter

print of ""
print of "=== Final Metrics ==="
print of "Framework strength:"
fs is framework_strength
print of fs

print of "Signature:"
sig is signature
print of sig

print of "System stable:"
print of stable
""",
    "interrogatives": """# Interrogatives Demo
# Self-aware code that can query its own execution

define analyze as:
    print of "WHO am I?"
    print of WHO

    print of "WHAT is being computed?"
    print of WHAT

    print of "WHERE in execution?"
    print of WHERE

    return n * 2

print of "Running analysis..."
result is analyze of 21

print of "Result:"
print of result

print of "Final framework strength:"
print of framework_strength
""",
    "meta_eval": """# Meta-Circular Evaluation
# EigenScript can evaluate itself!

define identity as:
    return n

define apply_twice as:
    first is identity of n
    second is identity of first
    return second

print of "Testing self-reference stability..."

val is 42
r1 is identity of val
r2 is identity of r1
r3 is identity of r2

print of "Original:"
print of val
print of "After 3 identity applications:"
print of r3

print of "Apply twice:"
result is apply_twice of 21
print of result

print of "System remains stable:"
print of stable

print of "Converged (fixed point):"
print of converged
"""
}


@app.route('/')
def index():
    return render_template('index.html', examples=EXAMPLES)


@app.route('/run', methods=['POST'])
def run_code():
    code = request.json.get('code', '')
    mode = request.json.get('mode', 'interpret')  # 'interpret' or 'compile'

    if not code.strip():
        return jsonify({'error': 'No code provided', 'output': ''})

    with tempfile.NamedTemporaryFile(mode='w', suffix='.eigs', delete=False) as f:
        f.write(code)
        temp_path = f.name

    try:
        if mode == 'compile':
            # Use the compiler to generate LLVM IR
            result = subprocess.run(
                ['eigenscript-compile', temp_path, '-o', '-'],
                capture_output=True,
                text=True,
                timeout=60
            )
        else:
            # Use the interpreter
            result = subprocess.run(
                ['eigenscript', temp_path],
                capture_output=True,
                text=True,
                timeout=30
            )

        output = result.stdout
        error = result.stderr

        if result.returncode != 0:
            return jsonify({
                'error': error or 'Execution failed',
                'output': output
            })

        return jsonify({
            'output': output,
            'error': ''
        })

    except subprocess.TimeoutExpired:
        timeout = 60 if mode == 'compile' else 30
        return jsonify({
            'error': f'Execution timed out ({timeout}s limit)',
            'output': ''
        })
    except FileNotFoundError as e:
        return jsonify({
            'error': f'Command not found: {str(e)}. Is EigenScript installed?',
            'output': ''
        })
    except Exception as e:
        return jsonify({
            'error': str(e),
            'output': ''
        })
    finally:
        if os.path.exists(temp_path):
            os.unlink(temp_path)


@app.route('/examples/<name>')
def get_example(name):
    if name in EXAMPLES:
        return jsonify({'code': EXAMPLES[name]})
    return jsonify({'error': 'Example not found'}), 404


@app.route('/health')
def health():
    """Health check endpoint for deployment platforms"""
    return jsonify({'status': 'ok', 'version': '0.4.1'})


if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
