# Can

A server-side web component system for Crystal. Write components as HTML;
render them to a string. Each component's `<style>` is scoped to the
elements it owns.

The name is short for *canned templates*. Sits in the XSLT and Zope
TAL/METAL lineage — components are a special form *inside the template
language* rather than imported from a Crystal class library. The HTML
itself is the program.

**[Live landing page →](https://trans.github.io/can/)** (built by `can` itself; source under [`docs/`](docs/))

```html
<.def tag="card" param:title="String">
  <style>
    .card { border: 1px solid #ccc; padding: 1rem; }
    .card > h2 { color: navy; margin-top: 0; }
  </style>
  <div class="card">
    <h2>{title}</h2>
    <.slot/>
  </div>
</.def>

<card title="Hello">
  <p>Welcome.</p>
</card>
```

## Installation

Add to your `shard.yml`:

```yaml
dependencies:
  can:
    github: trans/can
```

Then `shards install`.

## Quick start

Templates live in `.can` files. A small Crystal class loads them at compile
time and renders to an `IO`:

```crystal
require "can"

class HomePage
  Can.template "templates/components.can"   # class scope: defines methods

  def render(io : IO)
    name = "Thomas"
    Can.template "templates/home.can"       # method scope: emits HTML
  end
end

io = IO::Memory.new
HomePage.new.render(io)
puts io.to_s
```

Run with `crystal run`. The template is parsed and compiled to Crystal
source at compile time — there's no runtime parsing, and template errors
surface as compile errors.

## Interpolation

`{expr}` evaluates a Crystal expression and HTML-escapes the result:

```html
<h1>Hi, {user.name}!</h1>
<p>You have {todos.size} things to do.</p>
```

For pre-sanitized content, use `<.raw>`:

```html
<article>
  <.raw>{markdown_to_html(post.body)}</.raw>
</article>
```

Or mark the value at the data layer:

```crystal
trusted = Can.raw("<em>safe</em>")
```

```html
<div>{trusted}</div>   <!-- emitted verbatim -->
```

Both compose. `<.raw>` doesn't penetrate into nested `<.def>` bodies —
those have their own escape context.

## Special forms

Dotted tags are language built-ins:

| Form | Purpose |
|---|---|
| `<.def tag="…" param:foo="T">…</.def>` | Define a component. |
| `<.if cond={…}>…</.if>` (with `<.elseif/>` / `<.else/>`) | Conditional. |
| `<.for each={x in xs}>…</.for>` | Iteration. |
| `<.let name="x" value={…}>…</.let>` | Local binding for the body. |
| `<.slot/>` / `<.slot name="…"/>` | Slot placeholder in a component body. |
| `<.import from="…"/>` | `require` another Crystal file. |
| `<.raw>…</.raw>` | No-escape zone. |

`:if` and `:for` are attribute-form shortcuts:

```html
<p :if={admin?}>secret</p>
<li :for={item in items}>{item}</li>
```

When both are present, `:if` is outer (same as Vue 3).

`<.if>` supports `<.elseif/>` and `<.else/>` sentinels:

```html
<.if cond={n == 0}>
  zero
  <.elseif cond={n < 10}/>
  small
  <.else/>
  large
</.if>
```

Codegen collapses these into a Crystal `if/elsif/elsif/else/end` chain.

## Components

A `<.def>` defines a component. Invoke it as a tag — the tag name maps to
a Crystal method:

- `<Card>`, `<my-card>`, and `<card>` all map to method `card`.
- Hyphens become underscores; PascalCase becomes snake_case.
- Real HTML element names (`a`, `div`, `h1`, …) render literally.

```html
<.def tag="badge" param:label="String" param:emoji={"✨"}>
  <span>{emoji} {label}</span>
</.def>

<badge label="crystal"/>
<badge label="ruby" emoji="💎"/>
```

### Params

`param:foo="T"` declares a required param of type `T`. `param:foo={value}`
declares an optional one — the default is the given Crystal expression and
the type is inferred from the literal:

```html
<.def tag="row"
      param:label="String"            ← required
      param:n={0_i32}                 ← Int32, default 0
      param:items={[] of String}      ← Array(String), default []
>
  …
</.def>
```

Crystal's typed literal suffixes (`_i32`, `_u8`, `_f64`, …) cover the cases
where bare numerics would be ambiguous.

### Slots

A `<.slot/>` in a component body marks where the invocation's children
render. Named slots use `<.slot name="…"/>` in the def and `<:name>…</:name>`
at the call site:

```html
<.def tag="layout" param:heading="String">
  <header>
    <h1>{heading}</h1>
    <.slot name="nav"/>
  </header>
  <main><.slot/></main>
  <footer><.slot name="footer"/></footer>
</.def>

<layout heading="Welcome">
  <:nav><a href="/">home</a></:nav>
  <p>page content</p>
  <:footer><small>© 2026</small></:footer>
</layout>
```

Slot fill content runs in the *caller's* scope and captures the caller's
local variables.

### Top-level vs inline defs

A `<.def>` at the top of a template loaded at class scope becomes a real
method on the surrounding class. A `<.def>` inside another element — or
inside a template loaded inside a method — becomes a local `Proc` that
captures surrounding bindings:

```html
<div>
  <.def tag="pill">[{label}]</.def>
  <.for each={label in tags}><pill/></.for>
</div>
```

Inline defs **can't host slots or have param defaults** (Crystal `Proc`s
don't support either). Put slot-bearing or default-bearing components in
a separate `.can` file loaded at class scope:

```crystal
class Page
  Can.template "components.can"   # defs with slots/defaults here
  def render(io : IO)
    Can.template "page.can"       # rendering content here
  end
end
```

A clear compile-time error fires if you violate this.

## CSS scoping

A `<style>` block inside a `<.def>` is scoped automatically:

1. Each component gets a stable id like `c-card-a3f9` (6-char CRC32 of its
   tag + body).
2. Every HTML element rendered by the component is stamped with the
   matching `data-c-…` attribute.
3. Every CSS selector in the component's `<style>` is rewritten to require
   that attribute.

Author writes:

```html
<.def tag="card" param:title="String">
  <style>
    .card { border: 1px solid #ccc; }
    .card > h2 { color: navy; }
    .card:hover { border-color: black; }
  </style>
  <div class="card"><h2>{title}</h2></div>
</.def>
```

Browser receives (with `id` like `a3f9`):

```html
<style data-c-card-a3f9>
  .card[data-c-card-a3f9] { border: 1px solid #ccc; }
  .card[data-c-card-a3f9] > h2[data-c-card-a3f9] { color: navy; }
  .card[data-c-card-a3f9]:hover { border-color: black; }
</style>
<div class="card" data-c-card-a3f9>
  <h2 data-c-card-a3f9>Hello</h2>
</div>
```

The scoper recurses into `@media` and `@supports`, passes `@keyframes` /
`@font-face` / `@import` through unchanged, and respects comments and
strings.

Components without a `<style>` get no stamping — no noise in their output.

### Styling slot content

Slot content is written by the caller and isn't stamped with the host's id,
so `<.tags > *` after rewriting would require the `*` to have the host
attribute and miss the spans. Use `:slotted()` to opt slot content into a
rule:

```css
.tags > :slotted(*) { padding: 0.25rem; }
```

becomes

```css
.tags[data-c-tag-list-…] > * { padding: 0.25rem; }
```

The host stays scoped; the slot side doesn't require the attribute.

## How it works

`Can.template "path/to/foo.can"` is a macro. At compile time:

1. Crystal's `{{ run }}` invokes `src/can/cli/compile_template.cr` with the
   template path.
2. That CLI parses the file (`Can::Parser`) and runs codegen
   (`Can::Codegen`), producing a string of Crystal source.
3. The macro splices that string in at the call site.

So the template fully compiles into your binary. The macro is the only
piece that touches Crystal's macro system; parser, codegen, and CSS scoper
are plain Crystal modules with regular unit tests.

`Can.template_inline "…"` does the same with an inline source string.

## Use with Kemal (or any IO-based server)

`can` doesn't ship a Kemal adapter — it doesn't need one. A render
method just writes HTML to an `IO`, and `env.response` is an `IO`. The
recipe:

```crystal
require "kemal"
require "can"

class Pages
  Can.template "templates/layout.can"   # class scope: layout def with slots

  def home(name : String, todos : Array(String)) : String
    String.build do |io|
      Can.template "templates/home.can"
    end
  end
end

PAGES = Pages.new

get "/" do |env|
  env.response.content_type = "text/html"
  name = env.params.query["name"]? || "stranger"
  PAGES.home(name, ["buy milk", "write more crystal"])
end

Kemal.run
```

Where `layout.can` defines a top-level component with slots:

```html
<.def tag="layout" param:title="String">
  <!DOCTYPE html>
  <html>
    <head><title>{title}</title></head>
    <body>
      <header><.slot name="heading"/></header>
      <main><.slot/></main>
    </body>
  </html>
</.def>
```

And `home.can` fills those slots:

```html
<layout title="Home">
  <:heading><h1>Hi, {name}!</h1></:heading>
  <p>List:</p>
  <ul><.for each={t in todos}><li>{t}</li></.for></ul>
</layout>
```

The same shape works for Grip, plain `HTTP::Server`, or anything else
that exposes an `IO` for the response body. A runnable example lives at
`try/kemal/` — `crystal run try/kemal/app.cr` from the project root,
then open <http://localhost:3000/>.

## Limitations

- Inline `<.def>` can't host `<.slot/>` and can't have param defaults
  (Crystal `Proc` constraints). Clear errors fire.
- The brace-expression reader inside `{expr}` doesn't recurse into Crystal
  `#{…}` interpolations within string literals. Rare in practice.
- The CSS scoper handles common selectors but isn't a full CSS-syntax
  parser — exotic at-rules or deeply nested attribute selectors may not
  roundtrip identically.
- `<style>` is emitted inline at each component render; if a component
  appears N times on a page, its `<style>` block does too. Browsers handle
  this fine and gzip eats most of the wire cost.

## Development

```
$ shards install
$ crystal spec
```

The test suite uses `crystal run` for end-to-end round-trip and macro
tests, so a full run takes around a minute.

## Contributors

- [Thomas Sawyer](https://github.com/trans) — creator and
  maintainer

## License

MIT.
