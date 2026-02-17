# Julia Metaprogramming — Ground Truth

Distilled from the [Julia Manual](https://docs.julialang.org/en/v1/manual/metaprogramming/)
and [MacroTools.jl](https://fluxml.ai/MacroTools.jl/stable/).

---

## Core Concepts

### Expr Structure

Every Julia expression is an `Expr` with two fields:

```julia
ex = :(a + b * c)
ex.head   # :call
ex.args   # [:+, :a, Expr(:call, :*, :b, :c)]
```

Construction: `Expr(:call, :+, 1, 1)` is equivalent to `:(1 + 1)`.

Inspect with `dump(ex)` or `Meta.show_sexpr(ex)`.

### Quoting

```julia
:(a + b)                  # single expression
quote ... end             # block (includes LineNumberNodes)
```

### Interpolation

```julia
a = 1
:($a + b)                 # :(1 + b) — value of `a` spliced in
:(f(1, $(args...)))       # splatting interpolation
```

### Symbols

```julia
:foo                      # Symbol literal
Symbol("func", 10)        # :func10 — runtime construction
```

---

## Macros

### Expansion Model

```
@mymacro(args...)  →  macro receives Expr/Symbol/literal args
                   →  returns an Expr
                   →  compiler inserts it in place
```

Macros run at **parse time** (not runtime). Use `@macroexpand` to debug.

### Implicit Arguments

Every macro receives:
- `__source__::LineNumberNode` — call-site location
- `__module__::Module` — expansion context

### Hygiene

- Local variables in returned `quote` blocks get `gensym`'d names.
- Global references resolve in the **macro definition** module.
- `esc(expr)` escapes an expression — it's resolved in the **caller's** scope.

**Rule of thumb**: `esc()` user-provided expressions, don't `esc()` your own logic.

```julia
macro time(ex)
    quote
        local t0 = time_ns()
        local val = $(esc(ex))    # user code — escaped
        local t1 = time_ns()
        println("elapsed: ", (t1-t0)/1e9, "s")
        val
    end
end
```

### Dispatch

Macros support multiple dispatch on **AST types** (not runtime types):

```julia
macro m(::Int)       # matches literal integers
macro m(x, y)        # matches two arguments
macro m(args...)     # varargs fallback
```

---

## Non-Standard String Literals

```julia
macro r_str(p)  # defines r"..." syntax
    Regex(p)
end
```

Our `@cypher_str` uses this: `cypher"MATCH (n) WHERE n.name = $name"`.

---

## Code Generation Patterns

### Loop + @eval

```julia
for op in (:sin, :cos, :tan)
    @eval Base.$op(a::MyType) = MyType($op(a.x))
end
```

### @generated Functions

Dispatch on **types** at compile-time, return a quoted body:

```julia
@generated function foo(x)
    if x <: Integer
        return :(x ^ 2)
    else
        return :(x)
    end
end
```

---

## AST Patterns for DSL Design

### Common `Expr` Heads

| Head         | Example source          | `args` structure                    |
| ------------ | ----------------------- | ----------------------------------- |
| `:call`      | `f(x, y)`               | `[:f, :x, :y]`                      |
| `:call`      | `x + y`                 | `[:+, :x, :y]`                      |
| `:call`      | `a:B` (range/colon)     | `[:(:), :a, :B]`                    |
| `:(.)`       | `p.name`                | `[:p, QuoteNode(:name)]`            |
| `:(->)`      | `x -> body`             | `[:x, Expr(:block, ...)]`           |
| `:(-->) `    | `a --> b`               | `[:a, :b]`                          |
| `:vect`      | `[a, b]`                | `[:a, :b]`                          |
| `:tuple`     | `(a, b, c)`             | `[:a, :b, :c]`                      |
| `:macrocall` | `@foo x y`              | `[Symbol("@foo"), LineNum, :x, :y]` |
| `:block`     | `begin ... end`         | `[LineNum, expr1, LineNum, expr2]`  |
| `:&&`        | `a && b`                | `[:a, :b]`                          |
| `:\|\|`      | `a \|\| b`              | `[:a, :b]`                          |
| `:$`         | `$var` (inside quote)   | `[:var]`                            |
| `:(=)`       | `x = y`                 | `[:x, :y]`                          |
| `:(::)`      | `x::Int`                | `[:x, :Int]`                        |
| `:if`        | `if c ... else ... end` | `[cond, then_block, else_block]`    |
| `:kw`        | `f(x=1)` keyword arg    | `[:x, 1]`                           |

### QuoteNode

Wraps a value to prevent interpolation: `QuoteNode(:foo)`.
Parser produces it for `:symbol` literals inside expressions.

### LineNumberNode

`LineNumberNode(line, file)` — appears in `:block` expressions.
**Always filter these** when walking block args.

---

## Key Insight for Our DSL

### `>>` / `<<` Chain Operators

The `>>` and `<<` operators are parsed as standard Julia `:call` expressions:

```julia
dump(:(a >> b >> c))
# Expr(:call, :>>, Expr(:call, :>>, :a, :b), :c)
```

Key properties:
- **Left-associative**: `a >> b >> c` → `>>(>>(a, b), c)`
- **Both `>>` and `<<`** parse as `:call` with the operator as first arg
- **Mixed chains** `a >> B >> b << C << c` produce nested calls that can
  be walked to detect direction changes per relationship

The DSL uses `_is_chain_operator` to detect `>>` / `<<` heads and
`_chain_to_pattern` to recursively decompose the nested calls into a
linear sequence of `(node, rel, direction)` tuples.

### Arrow Bracket Syntax

Julia's parser turns `(a:B)-[r:T]->(c:D)` into:

```
Expr(:call, :-,
    Expr(:call, :(:), :a, :B),          # a:B  → node
    Expr(:(->),
        Expr(:vect, Expr(:call, :(:), :r, :T)),  # [r:T] → rel bracket
        Expr(:block, ...,
            Expr(:call, :(:), :c, :D)    # c:D  → target node
        )
    )
)
```

The `->` arrow and `-` minus combine to make `-[…]->` parseable.
The `-->` operator parses directly as `Expr(:-->, lhs, rhs)`.

**Left arrows (`<-`) don't parse the same way** — `<` and `-` don't
combine into a single operator. This requires alternative DSL syntax.

---

## MacroTools.jl — Pattern Matching

### @capture

Declarative destructuring of expressions:

```julia
using MacroTools: @capture

# Match function call:
@capture(ex, f_(args__))          # f_ = single, args__ = slurp

# Match struct:
@capture(ex, struct T_ fields__ end)

# Unions (try A, then B):
@capture(ex, (f_(xs__) = body_) | (function f_(xs__) body_ end))
```

- `_` suffix = single capture  
- `__` suffix = slurp (array capture, max one per expression)
- Returns `true`/`false`; binds variables on success.

### Type-constrained capture

```julia
@capture(ex, foo(x_String_string))   # matches String or Expr(:string,...)
@capture(ex, struct T_Symbol ... end) # T must be a plain Symbol
```

### Expression Walking

```julia
using MacroTools: postwalk, prewalk

# Replace all integers with their +1:
postwalk(x -> x isa Integer ? x + 1 : x, :(2 + 3))  # :(3 + 4)

# Pattern: find-and-replace with @capture
postwalk(ex) do x
    @capture(x, f_(xs__)) || return x
    :($f(extra_arg, $(xs...)))
end
```

- `postwalk`: leaves first, whole expression last (safe default).
- `prewalk`: whole expression first, then recurses into result (**can loop!**).

### Useful Utilities

| Function       | Purpose                                       |
| -------------- | --------------------------------------------- |
| `rmlines(ex)`  | Strip `LineNumberNode`s from blocks           |
| `unblock(ex)`  | Remove redundant outer `begin` blocks         |
| `namify(ex)`   | Extract name from `Foo{T}` or `Bar{T} <: Vec` |
| `isexpr(x,h)`  | Test expression head or type                  |
| `prettify(ex)` | Clean up generated code for readability       |
| `splitdef(f)`  | Decompose any function definition into a Dict |
| `combinedef`   | Rebuild function from Dict                    |
| `shortdef(f)`  | Normalize `function ... end` to `f(x) = ...`  |

### Canonical Macro Pattern

```julia
macro mymacro(ex)
    postwalk(ex) do x
        @capture(x, some_pattern) || return x
        return transformed_x
    end
end
```
