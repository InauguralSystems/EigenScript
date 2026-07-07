# EigenScript compared to Python, JavaScript, Rust, and Lisp

A translation guide: each section shows the same program in a language
you already know, then in EigenScript. Every EigenScript block followed
by an `output` block is executed by the test suite
(`tests/test_doc_examples.py`) and must produce exactly that output.
The other languages' blocks are illustrative only.

The one-paragraph summary: EigenScript reads like Python (indentation
blocks, dynamic types), applies functions with a keyword like a
concatenative language (`f of x`), is a Lisp-like single-value-kind
world underneath (everything is one of eight runtime types, code runs
top to bottom, no static pass), and differs from all of them in one
fundamental way: **every assignment is observed**, and the language has
first-class constructs (`converged`, `what is x`, `prev of x`) for
asking the running program about its own state and history.

## At a glance

| | Python | JavaScript | Rust | Lisp | EigenScript |
|---|---|---|---|---|---|
| typing | dynamic | dynamic | static | dynamic | dynamic |
| numbers | int + float | float | many | many | one: 64-bit float |
| assignment | `x = 1` | `let x = 1` | `let x = 1;` | `(define x 1)` | `x is 1` |
| call | `f(x)` | `f(x)` | `f(x)` | `(f x)` | `f of x` |
| blocks | indentation | braces | braces | parens | indentation |
| booleans | `True/False` | `true/false` | `bool` | `#t/#f` | `1`/`0` |
| null | `None` | `null/undefined` | `Option` | `nil` | `null` |
| errors | exceptions | exceptions | `Result` | conditions | `try`/`catch` |
| self-inspection | none | none | none | macros | interrogatives + observer |

## Variables and arithmetic

Python:

```python
x = 42
x += 1
print(x)            # 43
print(7 / 2)        # 3.5
print(7 // 2)       # 3   (floor division operator)
```

EigenScript — one number type, true division; floor explicitly:

```eigenscript
x is 42
x += 1
print of x
print of (7 / 2)
print of (floor of (7 / 2))
```
```output
43
3.5
3
```

## Functions

Python:

```python
def add(a, b):
    return a + b

print(add(3, 4))
```

JavaScript:

```javascript
const add = (a, b) => a + b;
console.log(add(3, 4));
```

EigenScript — a bare literal list after `of` is the argument list, at
every element count: `f of [a, b]` is two arguments, `f of [x]` is one.
(Parentheses always mean one argument: `f of ([x])` passes a literal
1-element list whole.)

```eigenscript
define add(a, b) as:
    return a + b

print of (add of [3, 4])

inc is (x) => x + 1
print of (inc of 41)
```
```output
7
42
```

## Closures: the counter

Python:

```python
def make_counter():
    count = 0
    def step():
        nonlocal count
        count += 1
        return count
    return step
```

JavaScript:

```javascript
function makeCounter() {
    let count = 0;
    return () => ++count;
}
```

EigenScript — no `nonlocal` needed: assignment is outward-mutable, so
inner functions write outer variables directly:

```eigenscript
define make_counter as:
    count is 0
    define step as:
        count is count + 1
        return count
    return step

c is make_counter of null
print of (c of null)
print of (c of null)
```
```output
1
2
```

## Lists: map / filter / comprehension

Python:

```python
xs = [1, 2, 3, 4, 5]
print([v * v for v in xs])
print([v for v in xs if v % 2 == 0])
print(list(map(lambda v: v * 10, xs)))
```

EigenScript — same comprehension shape; `map`/`filter` come from the
standard library:

```eigenscript
load_file of "lib/list.eigs"
xs is [1, 2, 3, 4, 5]
print of [v * v for v in xs]
print of [v for v in xs if v % 2 == 0]
print of (map of [xs, (v) => v * 10])
```
```output
[1, 4, 9, 16, 25]
[2, 4]
[10, 20, 30, 40, 50]
```

## Dictionaries / objects

JavaScript:

```javascript
const user = { name: "Ada", year: 1815 };
user.field = "computing";
console.log(user.name, Object.keys(user).length);
```

EigenScript — dot access and bracket access are interchangeable;
assignment creates keys:

```eigenscript
user is {"name": "Ada", "year": 1815}
user.field is "computing"
print of user.name
print of (len of (keys of user))
```
```output
Ada
3
```

## Pattern matching

Rust:

```rust
match code {
    200 => println!("OK"),
    404 => println!("Not Found"),
    _   => println!("other"),
}
```

EigenScript:

```eigenscript
code is 404
match code:
    case 200:
        print of "OK"
    case 404:
        print of "Not Found"
    case _:
        print of "other"
```
```output
Not Found
```

## Error handling

Python:

```python
try:
    raise ValueError("boom")
except Exception as e:
    print(f"caught: {e}")
```

EigenScript — `throw of` raises, `catch name:` binds. A thrown value
binds unchanged; a built-in runtime error binds a `{kind, message,
line}` dict with `kind` from a closed vocabulary (no exception
hierarchy — discriminate on the kind string):

```eigenscript
try:
    throw of "boom"
catch e:
    print of f"caught: {e}"

try:
    x is [1] - 1
catch e:
    print of f"caught: {e.kind} at line {e.line}"
```
```output
caught: boom
caught: type_mismatch at line 7
```

## Pipes (vs Lisp threading / shell pipes)

Clojure:

```clojure
(-> 5 double inc)   ; threading macro
```

EigenScript — `|>` is built in:

```eigenscript
double is (x) => x * 2
inc is (x) => x + 1
print of (5 |> double |> inc)
```
```output
11
```

## Concurrency

Python (threads + queue):

```python
import threading, queue
q = queue.Queue()
threading.Thread(target=lambda: q.put(21 * 2)).start()
print(q.get())
```

EigenScript — `spawn` + channels:

```eigenscript
ch is channel of null
spawn of [(v) => send of [ch, v * 2], 21]
print of (recv of ch)
```
```output
42
```

## Convergence loops: boilerplate you stop writing

Before the metaphysics, the everyday win. Every numeric fixed-point loop in
Python or JavaScript hand-rolls the same three things — and beginners get them
wrong: an **epsilon threshold**, a way to **remember** the previous value(s),
and a **max-iteration guard** so a non-converging loop doesn't hang.

```python
# Python: the epsilon, the remembering, and the guard are all yours
def newton_sqrt(n, eps=1e-12, max_iter=1000):
    guess = n / 2 or 1.0
    for _ in range(max_iter):            # max-iter guard, by hand
        nxt = (guess + n / guess) / 2
        if abs(nxt - guess) < eps:       # epsilon threshold, by hand
            return nxt
        guess = nxt                      # remember the last value, by hand
    return guess                         # ...and hope it converged
```

EigenScript watches every value settle for you, so the loop *is* the
convergence test — no epsilon, no remembered previous, no guard:

```eigenscript
define newton_sqrt as:
    guess is n / 2.0
    if guess == 0:
        guess is 1.0
    loop while not converged:
        guess is (guess + n / guess) / 2.0
    return guess

print of ("sqrt(2) = " + (str of (newton_sqrt of 2)))
```
```output
sqrt(2) = 1.414213562373095
```

`converged` reads the loop's last-assigned value and is true once its trend has
flattened. (Use it inside a function so the loop gets a fresh binding to watch —
see `examples/observer_vs_boilerplate.eigs`.) The next section is *why* this
works; you can reach for it long before you need the theory.

## What has no equivalent elsewhere: the observer

Every assignment (outside `unobserved` blocks) updates an observer
tracking the value's entropy and trend. You can ask a variable about
itself, terminate loops on *convergence* instead of a hand-written
epsilon test, and read a variable's past:

```eigenscript
x is 10
x is 20
x is 30
print of (what is x)
print of (who is x)
print of (when is x)
print of (prev of x)

e is 5
loop while not converged:
    e is e * 0.5
print of (e < 0.001)
```
```output
30
x
3
20
1
```

In Python you would write the convergence loop with an explicit
threshold; in EigenScript the loop condition *is* the semantic intent:

```python
# Python: the epsilon is yours to pick, plumb, and tune
while abs(e_prev - e) > 1e-9:
    e_prev, e = e, step(e)
```

```eigenscript skip
loop while not converged:    # EigenScript: the runtime watches e
    e is step of e
```

## Before / after: porting checklist

Transformations you will apply constantly when porting Python code:

| Python | EigenScript | why |
|---|---|---|
| `x = v` | `x is v` | assignment keyword |
| `f(a)` | `f of a` | application keyword |
| `f(a, b)` | `f of [a, b]` | bare literal list = argument list |
| `f([a])` (pass a 1-element list) | `f of ([a])` | parentheses = one argument |
| `True` / `False` / `None` | `1` / `0` / `null` | no boolean type |
| `x ** y` | `pow of [x, y]` | `^` is XOR |
| `len(x)` | `len of x` | builtin, same name |
| `xs.append(v)` | `append of [xs, v]` | builtins, not methods |
| `while c:` | `loop while c:` | loop keyword |
| `def f():` body using `nonlocal` | plain `is` | assignment is outward-mutable |
| `d["k"]` / `d.get("k")` | `d.k` or `d["k"]` | dot works on any dict |

A worked port — Python before:

```python
def word_lengths(words):
    out = {}
    for w in words:
        out[w] = len(w)
    return out

print(word_lengths(["ada", "grace"]))
```

EigenScript after:

```eigenscript
define word_lengths(words) as:
    out is {}
    for w in words:
        out[w] is len of w
    return out

print of (word_lengths of (["ada", "grace"]))
```
```output
{"ada": 3, "grace": 5}
```

(Note the `of (["ada", "grace"])` — parenthesised: parentheses always
make the argument a single value, so the literal list arrives whole. A
bare `of ["ada", "grace"]` would also work here — two arguments to a
one-parameter function pack back into a list — but the parenthesised
form says "one list" directly and works for any arity.)
