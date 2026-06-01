# Launch Copy

Reusable copy for promoting Can. Keep the tone technical, honest, and
specific. Can is pre-1.0, and `can-render` is a focused renderer, not a full
static site generator yet.

## Positioning

Can is a server-side HTML component system for Crystal. Write `.can`
templates as HTML, compose components with slots and scoped CSS, and compile
them to Crystal before your app runs.

Short repo description:

> Server-side HTML components for Crystal, compiled before runtime.

## GitHub Release Notes

Can v0.4.0 adds template-level `<.use>` and `can-render`, a small CLI for
rendering a single `.can` file in static experiments.

Can is a pre-1.0 server-side HTML component system for Crystal. Templates are
written as `.can` HTML files and compiled to Crystal before runtime, so there
is no runtime template parser and no browser-side framework involved.

This release is still best treated as experimental, but it should be useful
if you are exploring componentized HTML for Crystal SSR apps, Kemal or
`HTTP::Server` projects, or small static rendering experiments.

Highlights:

- Template-level `<.use from="..."/>` for loading `.can` component files from
  renderable templates.
- Relative `.can` dependency resolution from the containing template file.
- `can-render`, a small command-line renderer for one `.can` file.
- CLI support for `-o`, `-D name=value`, and `--require`.
- Expanded README and generated API docs.

Note: `can-render` is not a full static site generator yet, though a broader
static-site workflow is a natural future direction.

## Show HN Draft

Title:

> Show HN: Can - server-side HTML components for Crystal

Post:

> Hi HN,
>
> I built Can, a pre-1.0 server-side HTML component system for Crystal.
>
> The idea is to write components as HTML in `.can` files, then compile those
> templates into Crystal before the app runs. There is no runtime template
> parser and no browser-side framework involved.
>
> It currently supports component defs, slots, scoped CSS, literal quoted
> attributes, expression attributes, `Can.use`, `Can.view`, template-level
> `<.use>`, and a small `can-render` CLI for rendering a single `.can` file in
> static experiments.
>
> This is still early, but I am interested in feedback from people who use
> Crystal for server-rendered apps or who have opinions about HTML-first
> component systems.
>
> Repo: https://github.com/trans/can
> Docs/site: https://trans.github.io/can/

## Reddit Draft

Title:

> Can v0.4.0 - server-side HTML components for Crystal

Post:

> I am working on Can, a pre-1.0 server-side HTML component system for
> Crystal.
>
> The short version:
>
> - write components as HTML in `.can` files
> - compile templates to Crystal before runtime
> - use component defs, slots, scoped CSS, literal and expression attributes
> - v0.4.0 adds template-level `<.use>` and a small `can-render` CLI
>
> It is not a JavaScript framework, and `can-render` is not a full static site
> generator yet. The current sweet spot is experiments and small Crystal SSR
> projects.
>
> Repo: https://github.com/trans/can
> Site/docs: https://trans.github.io/can/
>
> I would especially like feedback on whether the component model and README
> explain the value clearly to Crystal developers.

## Follow-Up Topics

- Server-side HTML components in Crystal
- Compile-time HTML templates in Crystal
- Crystal server-rendered components with Kemal
- Can vs ECR for Crystal templates
- Static HTML experiments with Crystal and `can-render`

## Channels To Avoid

- Spammy cold outreach
- Posting identical copy across communities
- Overclaiming maturity or production readiness
- Paid ads for now
- Framing Can as a JavaScript framework or as already having a full static
  site generator
