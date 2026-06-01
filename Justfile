# List available recipes.
default:
    @just --list

# Install dependencies.
install:
    shards install

# Run the test suite.
test:
    crystal spec

# Run local verification checks.
check:
    crystal tool format --check src spec
    crystal spec

# Format all Crystal source.
format:
    crystal tool format

# Build the marketing landing page → docs/index.html
site:
    crystal run docs/build.cr

# Generate Crystal API docs → docs/api/
api:
    crystal docs --output=docs/api
    find docs/api -name '*.html' -print0 | xargs -0 perl -pi -e 's/[ \t]+$//'

# Build everything served by GitHub Pages (marketing + API).
docs: site api

# Rebuild generated docs for a release.
release-docs:
    just site
    version="$(crystal eval 'require "./src/can"; print Can::VERSION')"; crystal docs --output=docs/api --project-version="$version" --source-refname="v$version"
    find docs/api -name '*.html' -print0 | xargs -0 perl -pi -e 's/[ \t]+$//'

# Run the small portfolio-style example (prints HTML to stdout).
try:
    crystal run try/main.cr

# Render a .can file with the CLI.
render file:
    crystal run src/can-render.cr -- {{file}}

# Run the Kemal demo server at http://localhost:3000
try-kemal:
    crystal run try/kemal/app.cr

# Remove generated artifacts.
clean:
    rm -rf docs/api
    rm -f try/out.html
