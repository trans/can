require "../src/can"

# Renders the marketing site to docs/index.html.
# Run from the project root: `crystal run docs/build.cr`.

class Site
  Can.template "docs/components.can"

  def home(card_source : String) : String
    String.build { |io| Can.template "docs/index.can" }
  end
end

card_source = File.read("spec/fixtures/styled_card.can").strip

File.write("docs/index.html", Site.new.home(card_source))
puts "wrote docs/index.html (#{File.size("docs/index.html")} bytes)"
