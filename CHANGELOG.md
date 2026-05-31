# Changelog

## 0.3.0 - 2026-05-31

- Breaking: quoted attributes are now literal text. Use expression
  attributes for dynamic values, for example `title={"Hello #{name}"}`
  instead of `title="Hello {name}"`.
- HTMX-style JSON attributes can now be written naturally, for example
  `hx-vals='{"kind":"book"}'`.
- Added `Can.use` for component-only template files and `Can.view` for
  renderable template files.
- Improved template diagnostics and code generation correctness checks.
