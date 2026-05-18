require "../src/can"

# Renders the marketing site to docs/index.html.
# Run from the project root: `crystal run docs/build.cr`.

class Site
  Can.template "docs/components.can"

  def home(snippets : Hash(String, String)) : String
    String.build { |io| Can.template "docs/index.can" }
  end
end

# Source snippets are passed as data so the <:source> slots on the page
# stay short. Each one matches the actual invocation in index.can — when
# adding a new demo, update both.
snippets = {
  "card_soft"  => <<-CAN,
    <card-soft title="Soft">Pastel surfaces, rounded corners, a quiet voice.</card-soft>
    CAN
  "card_bold"  => <<-CAN,
    <card-bold title="Bold">High-contrast, monospace heading, a hard drop shadow.</card-bold>
    CAN
  "card_paper" => <<-CAN,
    <card-paper title="Paper">Quiet serif, paper texture, a marginal note.</card-paper>
    CAN
  "callouts"   => <<-CAN,
    <callout kind="info">Server-rendered. No client runtime, …</callout>
    <callout kind="warning">Slot-bearing components must be defined …</callout>
    <callout kind="danger">Use Can.raw() or <.raw> only for content …</callout>
    CAN
}

File.write("docs/index.html", Site.new.home(snippets))
puts "wrote docs/index.html (#{File.size("docs/index.html")} bytes)"
