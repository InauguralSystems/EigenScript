# EigenScript Formal Grammar

EBNF specification for EigenScript v0.6.0. This grammar describes the
concrete syntax accepted by the parser in `src/eigenscript.c`.

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
NUM         = digit { digit } [ '.' digit { digit } ]
STR         = '"' { char | escape } '"'
FSTR        = 'f"' { char | escape | '{' expression '}' } '"'
IDENT       = ( letter | '_' ) { letter | digit | '_' }
NEWLINE     = '\n' (emitted when not inside brackets)
INDENT      = increase in leading whitespace
DEDENT      = decrease in leading whitespace
COMMENT     = '#' { any } '\n'

letter      = 'a'..'z' | 'A'..'Z'
digit       = '0'..'9'
escape      = '\n' | '\t' | '\\' | '\"' | '\{' | '\}'
```

### Keywords

```
is  of  define  as  if  elif  else  loop  while  for  in
return  and  or  not  null  try  catch  break  continue  import
```

### Interrogatives

```
what  who  when  where  why  how
```

### Observer Predicates

```
converged  stable  improving  oscillating  diverging  equilibrium
```

### Operators and Punctuation

```
+  -  *  /  %
<  >  <=  >=  ==  !=
(  )  [  ]  {  }
,  :  .
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
            | import_stmt
            | return_stmt
            | break_stmt
            | continue_stmt
            | dot_assign_stmt
            | assign_stmt
            | expression

define_stmt = 'define' IDENT [ '(' param_list ')' ] [ 'as' ] ':' NEWLINE block

param_list  = IDENT { ',' IDENT }

if_stmt     = 'if' expression ':' NEWLINE block
              { 'elif' expression ':' NEWLINE block }
              [ 'else' ':' NEWLINE block ]

loop_stmt   = 'loop' [ 'while' ] expression ':' NEWLINE block

for_stmt    = 'for' IDENT 'in' expression ':' NEWLINE block

try_stmt    = 'try' ':' NEWLINE block
              'catch' [ IDENT ] ':' NEWLINE block

import_stmt = 'import' IDENT

return_stmt = 'return' expression

break_stmt  = 'break'

continue_stmt = 'continue'

dot_assign_stmt = postfix '.' IDENT 'is' expression

assign_stmt = IDENT 'is' expression

block       = INDENT { statement NEWLINE } DEDENT
```

### Expressions

Precedence from lowest to highest:

```
expression  = or_expr

or_expr     = and_expr { 'or' and_expr }

and_expr    = comparison { 'and' comparison }

comparison  = addition [ comp_op addition ]
comp_op     = '==' | '!=' | '<' | '>' | '<=' | '>='

addition    = multiply { ( '+' | '-' ) multiply }

multiply    = unary { ( '*' | '/' | '%' ) unary }

unary       = '-' unary
            | 'not' unary
            | call

call        = primary [ 'of' addition ]

primary     = NUM
            | STR
            | FSTR
            | 'null'
            | IDENT
            | interrogative
            | predicate
            | list_literal
            | dict_literal
            | '(' expression ')'
```

### Postfix Operators

After any primary expression, zero or more postfix operations:

```
postfix     = primary { '[' expression ']' | '.' IDENT }
```

Note: postfix indexing and dot access apply to NUM, STR, IDENT,
list literals, dict literals, and parenthesized expressions.

### Literals

```
list_literal = '[' [ expression { ',' expression } [ ',' ] ] ']'
             | '[' expression 'for' IDENT 'in' expression [ 'if' expression ] ']'

dict_literal = '{' [ dict_entry { ',' dict_entry } [ ',' ] ] '}'
dict_entry   = expression ':' expression
```

### Interrogatives and Predicates

```
interrogative = ( 'what' | 'who' | 'when' | 'where' | 'why' | 'how' ) 'is' expression

predicate     = 'converged' | 'stable' | 'improving'
              | 'oscillating' | 'diverging' | 'equilibrium'
```

## Operator Precedence Table

From lowest to highest precedence:

| Level | Operators | Associativity | Description |
|-------|-----------|---------------|-------------|
| 1 | `or` | Left | Logical OR |
| 2 | `and` | Left | Logical AND |
| 3 | `==` `!=` `<` `>` `<=` `>=` | None | Comparison |
| 4 | `+` `-` | Left | Addition, subtraction |
| 5 | `*` `/` `%` | Left | Multiplication, division, modulo |
| 6 | `-` (unary) `not` | Right | Negation, logical NOT |
| 7 | `of` | Left | Function call |
| 8 | `[i]` `.key` | Left | Index, dot access |

## Semantic Notes

- **Assignment** (`is`) is outward-mutable: if the name exists in a parent
  scope, it updates that binding. If not found, it creates a new local.
- **Function definition** (`define`) always creates a local binding.
- **Function call** (`fn of arg`) passes a single value. Multiple arguments
  are passed as a list: `fn of [a, b, c]`.
- **Named parameters** (`define fn(a, b) as:`) unpack a list argument into
  named locals. `define fn as:` uses the implicit parameter `n`.
- **Observer tracking** is automatic on every assignment. Interrogatives and
  predicates query the observer state without modifying it.
- **`break`/`continue`** affect the innermost enclosing `loop` or `for`.
- **`import`** loads `lib/NAME.eigs` and binds all module-level definitions
  as a dictionary under the module name.
