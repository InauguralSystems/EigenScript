# EigenScript Formal Grammar

EBNF specification for EigenScript v0.22+. This grammar describes the
concrete syntax accepted by the parser in `src/parser.c`. SPEC.md is the
normative semantics document (its examples are CI-gated); this file tracks
the concrete grammar.

## Notation

```
=           definition
|           alternation
[ ... ]     optional
{ ... }     zero or more repetitions
( ... )     grouping
'...'       terminal (keyword or symbol)
UPPER       token class (from lexer)
lower       non-terminal (grammar rule)
```

## Lexical Grammar

### Tokens

```
NUM         = HEX | DEC
DEC         = digit { digit } [ '.' { digit } ] [ exp ]
            | '.' digit { digit } [ exp ]
            ; the decimal form is parsed with strtod: scientific notation
            ; (1e5, 1E5) also lexes as one number and a trailing dot (1.)
            ; is accepted. Malformed forms like 1.2.3 are a parse error
            ; (one statement per line, #326/#315).
HEX         = ( '0x' | '0X' ) hexdigit { hexdigit }
            ; integer-only, lexed explicitly by the front end (#378) — NOT
            ; via strtod — so the value is exact to int64 and the profile
            ; is consistent (freestanding lexes it too). Hex-FLOAT forms
            ; (0x1p4, 0xA.8) are NOT numbers: they are a parse error.
exp         = ( 'e' | 'E' ) [ '+' | '-' ] digit { digit }
hexdigit    = digit | 'a'..'f' | 'A'..'F'
STR         = '"' { char | escape } '"'
FSTR        = 'f"' { char | escape | '{' expression '}' } '"'
IDENT       = ( letter | '_' ) { letter | digit | '_' }
NEWLINE     = '\n' (emitted when not inside brackets)
INDENT      = increase in leading whitespace
DEDENT      = decrease in leading whitespace
COMMENT     = '#' { any } '\n'

letter      = 'a'..'z' | 'A'..'Z'
digit       = '0'..'9'
escape      = '\n' | '\t' | '\r' | '\\' | '\"' | '\' any
              # only n t r \ " are special; any other '\x' yields literal x
              # (so '\{' and '\}' give literal braces)
```

### Keywords

```
is  of  define  as  if  elif  else  loop  while  for  in
return  and  or  not  null  try  catch  break  continue  import
match  case  unobserved  local
```

### Interrogatives

```
what  who  when  where  why  how
```

### Temporal Interrogatives (soft keywords)

```
prev  at
```

`prev` and `at` are soft keywords: they act as keywords only in
interrogative position (`prev of x`, `... at <expr>`) and fall back to
ordinary identifiers everywhere else. The six question words above are
soft in the same way — `what` not followed by `is` parses as an
identifier.

### Observer Predicates

```
converged  stable  improving  oscillating  diverging  equilibrium
```

### Operators and Punctuation

```
+  -  *  /  %
&  |  ^  <<  >>  ~
<  >  <=  >=  ==  !=
+=  -=  *=  /=  %=  &=  |=  ^=  <<=  >>=
(  )  [  ]  {  }
,  :  .
|>          pipe (left-associative, desugars a |> b to b of a)
=>          lambda arrow
```

### Whitespace Rules

- Indentation is significant (like Python)
- INDENT/DEDENT tokens are emitted based on leading spaces
- Inside `(...)`, `[...]`, or `{...}`, newlines and indentation are suppressed
  (multiline expressions allowed)
- Comments start with `#` and extend to end of line

## Syntactic Grammar

### Program

```
program     = { statement NEWLINE }
```

### Statements

```
statement   = define_stmt
            | if_stmt
            | loop_stmt
            | for_stmt
            | try_stmt
            | match_stmt
            | unobserved_stmt
            | import_stmt
            | return_stmt
            | break_stmt
            | continue_stmt
            | dot_assign_stmt
            | index_assign_stmt
            | destructure_stmt
            | local_assign_stmt
            | assign_stmt
            | expression

; Every statement ends at NEWLINE (or EOF/DEDENT) — leftover tokens on
; the line are a parse error ("one statement per line", #326).
; `break`/`continue` require an enclosing loop (compile error otherwise,
; #337); a module-level `return` ends the program (see SPEC.md).

define_stmt = 'define' IDENT [ '(' param_list ')' ] [ 'as' ] ':' NEWLINE block

param_list  = param { ',' param }
param       = IDENT [ 'is' expression ]
            ; the optional expression is a default value, evaluated in
            ; the defining scope when the argument is missing

if_stmt     = 'if' expression ':' NEWLINE block
              { 'elif' expression ':' NEWLINE block }
              [ 'else' ':' NEWLINE block ]

loop_stmt   = 'loop' [ 'while' ] expression ':' NEWLINE block

for_stmt    = 'for' IDENT 'in' expression ':' NEWLINE block

try_stmt    = 'try' ':' NEWLINE block
              'catch' [ IDENT ] ':' NEWLINE block

match_stmt  = 'match' expression ':' NEWLINE
              INDENT { 'case' ( expression | '_' ) ':' NEWLINE block } DEDENT

unobserved_stmt = 'unobserved' ':' NEWLINE block

import_stmt = 'import' IDENT

return_stmt = 'return' expression

break_stmt  = 'break'

continue_stmt = 'continue'

; dot/index assignment targets must be rooted at an IDENT
; ({"a":1}.k is 2 is a parse error; xs[0].a is 9 works)
dot_assign_stmt   = ident_chain '.' IDENT assign_op expression
index_assign_stmt = ident_chain '[' expression ']' assign_op expression
ident_chain       = IDENT { '[' expression ']' | '.' IDENT }

destructure_stmt  = '[' IDENT { ',' IDENT } ']' 'is' expression
                  ; the RHS list length must equal the pattern length

local_assign_stmt = 'local' IDENT 'is' expression

assign_stmt = IDENT assign_op expression
assign_op   = 'is' | '+=' | '-=' | '*=' | '/=' | '%='
            | '&=' | '|=' | '^=' | '<<=' | '>>='
            ; compound forms desugar: x += e  ==  x is x + e

block       = INDENT { statement NEWLINE } DEDENT
```

### Expressions

Precedence from lowest to highest:

```
expression  = pipe_expr

pipe_expr   = or_expr { '|>' or_expr }

or_expr     = and_expr { 'or' and_expr }

and_expr    = comparison { 'and' comparison }

comparison  = bitor_expr [ comp_op bitor_expr ]
comp_op     = '==' | '!=' | '<' | '>' | '<=' | '>='
            ; comparisons do NOT chain: 1 < 2 < 3 is a parse error

bitor_expr  = bitxor_expr { '|' bitxor_expr }

bitxor_expr = bitand_expr { '^' bitand_expr }

bitand_expr = shift_expr { '&' shift_expr }

shift_expr  = addition { ( '<<' | '>>' ) addition }

addition    = multiply { ( '+' | '-' ) multiply }

multiply    = unary { ( '*' | '/' | '%' ) unary }

unary       = '-' unary
            | 'not' unary
            | '~' unary
            | call

call        = primary [ 'of' unary ]
            ; the 'of' argument is a single unary-or-tighter expression — it
            ; does NOT absorb trailing infix, so `sqrt of x + 1` is
            ; `(sqrt of x) + 1` and `len of xs - 1` is `(len of xs) - 1`.
            ; Right-associative `f of g of x` and `f of -x` still hold.

primary     = NUM
            | STR
            | FSTR
            | 'null'
            | IDENT
            | interrogative
            | predicate
            | list_literal
            | dict_literal
            | lambda
            | '(' expression ')'

lambda      = '(' [ param_list ] ')' '=>' expression
```

### Postfix Operators

After any primary expression, zero or more postfix operations:

```
postfix     = primary { subscript | '.' IDENT }
subscript   = '[' expression ']'
            | '[' [ expression ] ':' [ expression ] ']'   ; slice
```

Note: which postfix forms a primary accepts depends on the primary.
IDENT, dict literals, parenthesized expressions, f-strings (which
desugar to parenthesized expressions), and the soft-keyword identifier
fallbacks (`prev`/`at`/question words, #328) accept both subscripts and
dot access. NUM, STR, and list literals accept only subscripts —
`[10, 20].x` is a parse error.

### Literals

```
list_literal = '[' [ expression { ',' expression } [ ',' ] ] ']'
             | '[' expression 'for' IDENT 'in' expression [ 'if' expression ] ']'

dict_literal = '{' [ dict_entry { ',' dict_entry } [ ',' ] ] '}'
dict_entry   = expression ':' expression
```

### Interrogatives and Predicates

```
interrogative = ( 'what' | 'who' | 'when' | 'where' | 'why' | 'how' ) 'is' expression [ 'at' expression ]
              | 'prev' 'of' expression [ 'at' expression ]

predicate     = 'converged' | 'stable' | 'improving'
              | 'oscillating' | 'diverging' | 'equilibrium'
```

The `at` qualifier pins the query to a source line: the answer is the
last value bound to the name at or before that line. The line operand
is a full expression. `prev of x` returns the value bound to `x` just
before its most recent assignment; it requires a named binding, so only
identifier operands are meaningful. Both temporal forms query the
per-name assignment history (top-level bindings) and evaluate to `null`
on a miss.

## Operator Precedence Table

From lowest to highest precedence:

| Level | Operators | Associativity | Description |
|-------|-----------|---------------|-------------|
| 1 | `\|>` | Left | Pipe (desugars `a \|> b` to `b of a`) |
| 2 | `or` | Left | Logical OR |
| 3 | `and` | Left | Logical AND |
| 4 | `==` `!=` `<` `>` `<=` `>=` | None | Comparison (non-chaining) |
| 5 | `\|` | Left | Bitwise OR |
| 6 | `^` | Left | Bitwise XOR |
| 7 | `&` | Left | Bitwise AND |
| 8 | `<<` `>>` | Left | Shifts |
| 9 | `+` `-` | Left | Addition, subtraction |
| 10 | `*` `/` `%` | Left | Multiplication, division, modulo |
| 11 | `-` (unary) `not` `~` | Right | Negation, logical NOT, bitwise NOT |
| 12 | `of` | Right | Function call / observation (`f of g of x` = `f of (g of x)`) |
| 13 | `[i]` `[a:b]` `.key` | Left | Index, slice, dot access |
| 14 | `=>` | — | Lambda (inside parenthesized param list) |

## Semantic Notes

- **Assignment** (`is`) is outward-mutable: if the name exists in a parent
  scope, it updates that binding. If not found, it creates a new local.
- **Local assignment** (`local name is expr`) always creates or updates the
  binding in the current evaluator scope only.
- **Function definition** (`define`) always creates a local binding.
- **Function call** (`fn of arg`) passes a single value. Multiple arguments
  are passed as a **literal** list: `fn of [a, b, c]`.
- **Argument lists** (#405; SPEC.md is normative): a *literal* bracket
  after `of` is the call's argument list at every count — `f of []` is
  zero args, `f of [x]` is one arg (the *element* `x`, not the list), and
  `f of [a, b]` is two. A list passed via a variable never acts as an
  argument list (`f of xs` binds the whole list to the first parameter;
  remaining parameters take defaults or `null`). To pass a literal list
  whole, or make any one-argument call, parenthesise: `f of ([x])` /
  `f of (x)`.
- **Implicit parameter**: `define fn as:` (no parameter list) uses the
  implicit parameter `n`. A zero-parameter lambda `() => expr` mirrors
  this classic style: it also receives the implicit `n`.
- **Observer tracking** is automatic on every assignment. Interrogatives and
  predicates query the observer state without modifying it.
- **`break`/`continue`** affect the innermost enclosing `loop` or `for`.
- **`import`** loads `lib/NAME.eigs` and binds all module-level definitions
  as a dictionary under the module name.
