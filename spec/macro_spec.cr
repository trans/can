require "./spec_helper"

CAN_SRC_DIR  = File.expand_path("../src", __DIR__)
PROJECT_ROOT = File.expand_path("..", __DIR__)

# Crystal honors $CRYSTAL_PATH for require lookup; if set it replaces the
# default so we have to query and prepend.
CRYSTAL_PATH_FOR_TESTS = begin
  default = `crystal env CRYSTAL_PATH`.strip
  default.empty? ? CAN_SRC_DIR : "#{CAN_SRC_DIR}:#{default}"
end

# Compiles and runs a small Crystal program that exercises the macro layer.
# `body` is spliced into a wrapper that requires can, sets up `io`, and prints
# the rendered output to stdout.
private def render_with_macro(body : String) : String
  program = <<-CRYSTAL
    require "can"
    io = IO::Memory.new
    #{body}
    print io.to_s
    CRYSTAL

  tmp = File.tempfile("can_macro_test", ".cr") { |f| f.print(program) }
  begin
    output = IO::Memory.new
    err = IO::Memory.new
    status = Process.run(
      "crystal", ["run", "--no-color", tmp.path],
      env: {"CRYSTAL_PATH" => CRYSTAL_PATH_FOR_TESTS},
      output: output, error: err, chdir: PROJECT_ROOT
    )
    unless status.success?
      raise "crystal run failed:\n#{err}\n--- program ---\n#{program}"
    end
    output.to_s
  ensure
    tmp.delete
  end
end

describe "Can.template_inline" do
  it "splices generated code in place and uses surrounding scope" do
    out = render_with_macro <<-CR
      name = "Thomas"
      Can.template_inline "<p>Hello, {name}!</p>"
      CR
    out.should eq("<p>Hello, Thomas!</p>")
  end

  it "auto-escapes interpolated values" do
    out = render_with_macro <<-CR
      msg = "<script>alert(1)</script>"
      Can.template_inline "<div>{msg}</div>"
      CR
    out.should eq("<div>&lt;script&gt;alert(1)&lt;/script&gt;</div>")
  end

  it "supports control flow" do
    out = render_with_macro <<-CR
      items = ["a", "b", "c"]
      Can.template_inline %q(<ul><.for each={x in items}><li>{x}</li></.for></ul>)
      CR
    out.should eq("<ul><li>a</li><li>b</li><li>c</li></ul>")
  end
end

describe "Can.template" do
  it "reads and compiles a template file" do
    out = render_with_macro <<-CR
      name = "World"
      items = ["read", "write"]
      Can.template "spec/fixtures/greet.can"
      CR
    out.should contain("<h1>Hello, World!</h1>")
    out.should contain("<li>read</li>")
    out.should contain("<li>write</li>")
  end

  it "skips conditional content when condition is false" do
    out = render_with_macro <<-CR
      name = "World"
      items = [] of String
      Can.template "spec/fixtures/greet.can"
      CR
    out.should contain("<h1>Hello, World!</h1>")
    out.should_not contain("<ul>")
    out.should_not contain("<li>")
  end

  it "compiles a template with component defs and invocations" do
    out = render_with_macro <<-CR
      name = "Thomas"
      items = ["buy milk", "write parser"]
      Can.template "spec/fixtures/page_with_components.can"
      CR
    out.should contain("<h1>Hello, Thomas!</h1>")
    out.should contain(%(<div class="card"><h2>Today</h2>))
    out.should contain("<li>buy milk</li>")
    out.should contain("<li>write parser</li>")
    out.should_not contain("Nothing to do")
  end

  it "renders the empty branch of a component" do
    out = render_with_macro <<-CR
      name = "Thomas"
      items = [] of String
      Can.template "spec/fixtures/page_with_components.can"
      CR
    out.should contain(%(<p class="empty">Nothing to do.</p>))
    out.should_not contain("<ul>")
  end

  it "scopes CSS and stamps the data-attr on elements end-to-end" do
    out = render_with_macro <<-CR
      Can.template "spec/fixtures/styled_card.can"
      CR

    # The same id appears on the <style> tag, the <div>, and the <h2>.
    ids = out.scan(/data-c-card-([a-f0-9]{6})/).map(&.[1]).uniq
    ids.size.should eq(1)
    id = ids.first

    out.should contain(%(<style data-c-card-#{id}>))
    out.should contain(%(<div class="card" data-c-card-#{id}>))
    out.should contain(%(<h2 data-c-card-#{id}>Hello</h2>))

    out.should contain(%(.card[data-c-card-#{id}]))
    out.should contain(%(.card[data-c-card-#{id}] > h2[data-c-card-#{id}]))
    out.should contain(%(.card[data-c-card-#{id}]:hover))

    # Slot content from the call site is NOT stamped — it belongs to the
    # caller's scope, which isn't a styled component here.
    out.should contain(%(<p>body content</p>))
  end

  it "renders a component with named slots end-to-end" do
    out = render_with_macro <<-CR
      user = "Thomas"
      year = 2026
      Can.template "spec/fixtures/page_with_slots.can"
      CR
    out.should contain("<h1>Hello, Thomas!</h1>")
    out.should contain(%(<a href="/">home</a>))
    out.should contain("<main><p>welcome, Thomas</p></main>")
    out.should contain("<small>© 2026</small>")
  end

  it "supports defining a component in one file and using it from another" do
    program = <<-CR
      class Page
        Can.template "spec/fixtures/components_only.can"

        def render(io : IO)
          name = "World"
          Can.template "spec/fixtures/uses_card.can"
        end
      end

      io = IO::Memory.new
      Page.new.render(io)
      print io.to_s
      CR

    tmp = File.tempfile("can_macro_test", ".cr") { |f| f.print %(require "can"\n#{program}) }
    begin
      output = IO::Memory.new
      err = IO::Memory.new
      status = Process.run(
        "crystal", ["run", "--no-color", tmp.path],
        env: {"CRYSTAL_PATH" => CRYSTAL_PATH_FOR_TESTS},
        output: output, error: err, chdir: PROJECT_ROOT
      )
      raise "crystal run failed:\n#{err}\n--- program ---\n#{program}" unless status.success?
      output.to_s.should contain(%(<div class="card"><h2>Hi</h2>))
      output.to_s.should contain("<p>hello from World</p>")
    ensure
      tmp.delete
    end
  end
end
