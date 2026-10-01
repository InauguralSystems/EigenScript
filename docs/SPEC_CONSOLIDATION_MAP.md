# Specification consolidation map (#1271)

This is a migration audit, not a language authority. The sole normative source
is [SPEC.md](SPEC.md). It records where each heading—and all statements under
that heading—landed during the direct merge. “Existing” means the destination
already covered the rule; “details” means the former contract wording was
retained under the linked consolidated section. Conflicts were resolved in
favor of the current executable specification and implementation evidence,
never by keeping both wordings.

## Former language-contract inventory

| former heading | one destination | resolution |
|---|---|---|
| Equality | [Language contract details: Equality](SPEC.md#equality----) | details |
| Ordering | [Ordering](SPEC.md#ordering-----) | details |
| Coercion | [Coercion](SPEC.md#coercion) | details |
| Errors | [Errors](SPEC.md#errors) | details; the strict-default wording supersedes the old division warning |
| Modules | [Modules](SPEC.md#modules) | existing construct section plus details |
| Numbers | [Numbers and arithmetic](SPEC.md#numbers-and-arithmetic) | existing section plus details; strict mode remains the current rule |
| Strings | [Strings](SPEC.md#strings) | existing section plus byte-model details |
| Bitwise | [Bitwise operators](SPEC.md#bitwise-operators) | existing section plus details |
| Truthiness | [Truthiness](SPEC.md#truthiness) | details |
| Scope & binding | [Scope & binding](SPEC.md#scope--binding) | details; current loop-binder behavior supersedes older guide prose |
| Evaluation | [Evaluation](SPEC.md#evaluation) | details |
| Mutability & aliasing | [Mutability & aliasing](SPEC.md#mutability--aliasing) | details |
| Function calls & argument unpacking | [Function calls & argument unpacking](SPEC.md#function-calls--argument-unpacking) | details; #405/#733 decisions retained |
| Default parameter values | [Default parameter values](SPEC.md#default-parameter-values-0130) | details |
| Destructuring assignment | [Destructuring assignment](SPEC.md#destructuring-assignment-0130) | details |
| Streaming subprocess I/O | [Streaming subprocess I/O](SPEC.md#streaming-subprocess-io-0130) | details |
| Operator precedence | [Operator precedence](SPEC.md#operator-precedence) | details and grammar table share this destination |
| Indexing | [Indexing](SPEC.md#indexing----) | details |
| Statistics convention | [Statistics convention](SPEC.md#statistics-convention-library) | details |
| How to use this document | [SPEC introduction](SPEC.md#eigenscript-language-specification) | obsolete workflow removed; new rules go to SPEC directly |

## Former grammar inventory

Every statement under Notation; Lexical Grammar (Tokens, Keywords,
Interrogatives, Temporal Interrogatives, Reserved Observer Forms, Observer
Predicates, Operators and Punctuation, Whitespace Rules); Syntactic Grammar
(Program, Statements, Expressions, Postfix Operators, Literals,
Interrogatives and Predicates); Operator Precedence Table; and Semantic Notes
moved to [Complete formal grammar](SPEC.md#complete-formal-grammar). Semantic
notes that overlap construct prose point to that construct's existing section;
the grammar has one retained production, not a separately included appendix.

## Former syntax-guide inventory

Variables and Assignment (including Numeric Semantics and Compound Assignment),
Functions (Named Parameters, Classic Style, No arguments), String
Interpolation, Interactive REPL, Conditionals, Loops, Error Handling, Closures,
Operators (Type rules and `of` precedence), Lists, Dictionaries, eval, Modules
(Path resolution), Interrogatives (Temporal Interrogatives), Observer Semantics,
Unobserved Blocks, Standard Library, and Gotchas now map through the exact links
in [the non-normative syntax reading path](SYNTAX.md). Its 35 executable fences
moved without deletion to [Migrated syntax-guide examples](SPEC.md#migrated-syntax-guide-examples).
