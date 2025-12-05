"""
EigenScript Web Playground
Interactive web interface for running EigenScript code
"""

from flask import Flask, render_template, request, jsonify
import subprocess
import tempfile
import os

app = Flask(__name__)

# Example code snippets
EXAMPLES = {
    "hello": """# Hello World
print of "Hello from EigenScript!"
x is 5
y is 3
print of "Sum:"
print of x + y
""",
    "convergence": """# Convergence Demo - The Inaugural Algorithm
x is 0
target is 10
velocity is 0

loop while x < 20:
    error is target - x
    velocity is velocity + (error * 0.1)
    velocity is velocity * 0.9
    x is x + velocity
    print of x

    if converged:
        print of "Converged!"
        break
""",
    "factorial": """# Recursive Factorial
define factorial as:
    if n < 2:
        return 1
    prev is n - 1
    sub_result is factorial of prev
    return n * sub_result

print of "5! ="
result is factorial of 5
print of result

print of "10! ="
result is factorial of 10
print of result
""",
    "xor": """# XOR Neural Network Demo
define threshold as:
    x is arg
    if x > 0:
        return 1
    return 0

define compute_xor as:
    a is arg[0]
    b is arg[1]
    or_val is threshold of (a + b - 0.5)
    and_val is threshold of (a + b - 1.5)
    nand_val is 1 - and_val
    result is threshold of (or_val + nand_val - 1.5)
    return result

print of "XOR Truth Table:"
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
A is matrix of [[1, 2], [3, 4]]
B is matrix of [[5, 6], [7, 8]]

print of "Matrix A:"
A_list is matrix_to_list of A
print of A_list

print of "Matrix B:"
B_list is matrix_to_list of B
print of B_list

print of "A * B:"
C is matmul of [A, B]
C_list is matrix_to_list of C
print of C_list

print of "A transposed:"
At is transpose of A
At_list is matrix_to_list of At
print of At_list
""",
    "geometric": """# Geometric Introspection
print of "=== Geometric Predicates ==="

counter is 0
limit is 20

loop while counter < limit:
    counter is counter + 1

    if converged:
        print of "Converged at iteration:"
        print of counter
        break

    if stable:
        print of "Stable at:"
        print of counter

print of ""
print of "=== Final Metrics ==="
print of "Framework strength:"
fs is framework_strength
print of fs
""",
    "higher_order": """# Higher-Order Functions
numbers is [1, 2, 3, 4, 5]

define square as:
    return n * n

define is_even as:
    return (n % 2) is 0

print of "Original list:"
print of numbers

print of "Squared:"
squared is map of [square, numbers]
print of squared

print of "Even numbers:"
evens is filter of [is_even, numbers]
print of evens

print of "Sum (reduce):"
define add as:
    return a + b
total is reduce of [add, numbers, 0]
print of total
"""
}


@app.route('/')
def index():
    return render_template('index.html', examples=EXAMPLES)


@app.route('/run', methods=['POST'])
def run_code():
    code = request.json.get('code', '')

    if not code.strip():
        return jsonify({'error': 'No code provided', 'output': ''})

    with tempfile.NamedTemporaryFile(mode='w', suffix='.eigs', delete=False) as f:
        f.write(code)
        temp_path = f.name

    try:
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
        return jsonify({
            'error': 'Execution timed out (30s limit)',
            'output': ''
        })
    except Exception as e:
        return jsonify({
            'error': str(e),
            'output': ''
        })
    finally:
        os.unlink(temp_path)


@app.route('/examples/<name>')
def get_example(name):
    if name in EXAMPLES:
        return jsonify({'code': EXAMPLES[name]})
    return jsonify({'error': 'Example not found'}), 404


if __name__ == '__main__':
    app.run(debug=True, host='0.0.0.0', port=5000)
