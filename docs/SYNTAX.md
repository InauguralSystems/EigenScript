# EigenScript syntax guide

This guide is a non-normative reading path through EigenScript. The
[language specification](SPEC.md) is the sole authority; where an explanation
here seems incomplete, follow the linked specification section.

## Start with a program

Begin with the [program model](SPEC.md#program-model), then read
[lexical structure](SPEC.md#lexical-structure) for lines, indentation,
identifiers, comments, and tokens. The [complete formal grammar](SPEC.md#complete-formal-grammar)
is the precise parser-level reference.

## Work with values

The shortest route through everyday data is [values and types](SPEC.md#values-and-types),
[variables and assignment](SPEC.md#variables-and-assignment),
[numbers and arithmetic](SPEC.md#numbers-and-arithmetic), [strings](SPEC.md#strings),
[lists](SPEC.md#lists), and [dictionaries](SPEC.md#dictionaries). For boundary
behavior such as coercion, indexing, aliasing, and truthiness, continue to the
[language contract details](SPEC.md#language-contract-details).

## Organize control flow

Read [conditionals](SPEC.md#conditionals), [loops](SPEC.md#loops),
[pattern matching](SPEC.md#pattern-matching), and [error handling](SPEC.md#error-handling)
together. They share the same block and scope model, detailed under
[scope and binding](SPEC.md#scope--binding).

## Define and call functions

The main path is [functions](SPEC.md#functions), followed by
[closures and lambdas](SPEC.md#closures-and-lambdas) and
[the pipe operator](SPEC.md#the-pipe-operator). Exact call collection, defaults,
and destructuring are indexed from [function calls and argument unpacking](SPEC.md#function-calls--argument-unpacking).

## Split a program into files

[Modules](SPEC.md#modules) explains imports, direct loads, namespaces, and path
resolution. Runtime library operations are catalogued separately in the
[builtin reference](BUILTINS.md) and [standard-library guide](STDLIB.md).

## Observe and revisit execution

Read [interrogatives](SPEC.md#interrogatives-asking-your-code),
[observer semantics and predicates](SPEC.md#observer-semantics-and-predicates),
and [temporal interrogatives](SPEC.md#temporal-interrogatives) in that order.
The [observer guide](OBSERVER.md), [predicate guide](PREDICATES.md), and
[trace guide](TRACE.md) provide subsystem explanations without replacing the
language specification.

## Run concurrent work

The specification separates [concurrency](SPEC.md#concurrency) from
[cooperative tasks](SPEC.md#cooperative-tasks). The [concurrency guide](CONCURRENCY.md)
adds operational context.

## Read examples

All examples formerly carried by this guide now live in
[migrated syntax-guide examples](SPEC.md#migrated-syntax-guide-examples), where
the executable-document gate checks them with the rest of the specification.
