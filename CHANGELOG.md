# Changelog

## 0.4.1 - 2026-06-01

- Changed tag dispatch to HTML-first: tags now render as literal HTML unless
  Can can resolve them to a component method.
- Custom elements such as `<my-widget>` now pass through naturally.
- Explicit component defs can intentionally shadow platform tags such as
  `<button>`, while the same platform tag remains literal inside the
  shadowing component body for wrapper components.

## 0.4.0 - 2026-06-01

- Added template-level `<.use from="..."/>` directives for loading `.can`
  component files from renderable templates.
- `<.use>` paths resolve relative to the containing template file and can
  appear at the top level or as a direct child of a top-level `<head>`.
- Added the `can-render` CLI target for rendering a single `.can` file from
  the command line, with `-o`, `-D name=value`, and `--require` support.
- Added docs and specs for template dependencies and CLI rendering.

## 0.3.0 - 2026-05-31

- Breaking: quoted attributes are now literal text. Use expression
  attributes for dynamic values, for example `title={"Hello #{name}"}`
  instead of `title="Hello {name}"`.
- HTMX-style JSON attributes can now be written naturally, for example
  `hx-vals='{"kind":"book"}'`.
- Added `Can.use` for component-only template files and `Can.view` for
  renderable template files.
- Improved template diagnostics and code generation correctness checks.
