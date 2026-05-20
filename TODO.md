# TODO

Punch list captured here so the deferred items don't get lost. None of
these are blockers — call the library done for now and pick them off as
they bite.

## Polish

### Whitespace from template indentation flows into the output

Blank lines and indentation in a `.can` file become blank lines and
indentation in the rendered HTML. Cosmetic; doesn't affect correctness.
Real fix is a small AST pass that collapses or strips runs of whitespace
between block-level elements at codegen time. Fiddly because we don't
want to break `<pre>` / `<style>` / `<script>` raw-text content.

### Per-page style collection

Each component's `<style>` block is emitted inline at every invocation,
so a `<card>` rendered 50 times on a page produces 50 copies of the same
`<style>`. The browser dedupes correctly (the data-attr selector matches
once); gzip flattens most of the wire cost. Pure aesthetics for
devtools cleanliness.

Real fix needs a render-context object that tracks which components have
appeared on the current page and emits each one's stylesheet only on the
first appearance. Architectural — touches the calling convention.

## Parser edge cases

### `{expr}` doesn't follow `#{…}` inside Crystal string literals

The brace-counting reader inside `{…}` tracks paren/brace depth and
string literals, but doesn't recurse into Crystal string interpolations
inside those literals. So `{name = "a #{x} b"}` mis-counts braces. Rare
in practice — most template interpolations don't contain Crystal string
interpolation. Real fix is making the brace reader recognize `#{` inside
string literals as a nested context.

## Features

### Interpreter mode / standalone CLI

Today the only way to render a template is to write a Crystal program
that calls `Can.template` and compile it. A `can-render` CLI that takes
a `.can` file + component library and emits HTML at runtime — no Crystal
build needed by the user — would unlock a static-site-generator usage
pattern.

Parser, codegen, and scoper are reusable. The new piece is an
interpreter that walks the AST and emits HTML directly, instead of
generating Crystal source. ~100-200 lines. Also makes live-reload
trivial.

### `@scope` migration for scoped CSS

See the `TODO` comment in `src/can/css_scope.cr`. Once CSS
`@scope { ... } to (...)` ships in Firefox and Safari (Chromium already
has it), we can switch from per-element `data-c-…` stamping to
stamping only the component root, with `@scope` walling off nested
components. Same isolation guarantees, much lighter markup.

## Won't fix unless asked

- Adapter modules for Grip, Lucky, etc. (just write to `env.response` —
  no adapter needed).
- A `Can::Page` base class. The recipe in the README is small enough.
