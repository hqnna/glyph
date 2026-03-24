# glyph ![license] ![activity] [![justforfun]](https://justforfunnoreally.dev)

[license]: https://img.shields.io/github/license/hqnna/glyph?labelColor=4c4350&color=3672cc
[activity]: https://img.shields.io/github/last-commit/hqnna/glyph?label=activity&labelColor=4c4350&color=3672cb
[justforfun]: https://img.shields.io/badge/justforfunnoreally-dev-9ff

A modern configuration language with a focus on readability and performance.

## Reference Implementation

Glyph's reference Zig implementation takes advantage of multiple things:

- **Tokenizer** - Streaming tokenizer with SIMD scanning for variable-length tokens.
- **Parser** - Recursive descent parser with one-token lookahead, and a zero-copy AST.
- **Serializer** - Deserializes into and serializes from structs using comptime reflection.

As of [`f3a80d0`] the Zig library implementation is fully implemented and working.

[`f3a80d0`]: https://github.com/hqnna/glyph/commit/f3a80d06220f0af0f5b376ce7af1d020b1fa9c80

## Grammar Specification

Below is a simple [PEG] grammar for Glyph's syntax, for those implementing it theirselves.

[PEG]: https://en.wikipedia.org/wiki/Parsing_expression_grammar

```
File          ← Spacing (RuneDecl / Entry)* EOF
Entry         ← Key ':' Spacing Value Spacing

Value         ← Object / Array / String / Expr / FieldRef / Bool / Nil

Object        ← '{' Spacing (RuneDecl / Entry)* '}' Spacing

Array         ← '[' Spacing ArrayBody? ']' Spacing
ArrayBody     ← Value (',' Spacing Value)* ','? Spacing

Expr          ← ExprPrimary (ExprOp ExprPrimary)*
ExprPrimary   ← '(' Spacing Expr ')' / ExprFunc / RuneRef / FieldRef / Float / Integer / '-' ExprPrimary
ExprOp        ← Spacing ('+' / '-' / '*' / '/') Spacing
ExprFunc      ← Ident '(' Spacing Expr (',' Spacing Expr)* ')' Spacing

RuneDecl      ← RuneName ':' Spacing Value Spacing
RuneRef       ← RuneName Accessor*
RuneName      ← '$' [a-zA-Z_] [a-zA-Z0-9_]*

FieldRef      ← FieldName Accessor*
FieldName     ← '@' [a-zA-Z_] [a-zA-Z0-9_]*

Accessor      ← '.' Key / '[' Integer ']'

String        ← '"' StringChar* '"'
StringChar    ← '\\' [\"nrtbf/] / !'"' .

Float         ← '-'? [0-9]+ '.' [0-9]+
Integer       ← '-'? [0-9]+
Bool          ← 'true' / 'false'
Nil           ← 'nil'

Key           ← Spacing [a-zA-Z_] [a-zA-Z0-9_]*
Ident         ← [a-zA-Z_] [a-zA-Z0-9_]*

Spacing       ← (WS / Comment)*
WS            ← [ \t\r\n]+
Comment       ← '#' (!'\n' .)* '\n'?
EOF           ← !.
```
