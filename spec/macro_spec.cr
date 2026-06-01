require "./spec_helper"

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

private def compile_macro_error(body : String) : String
  program = <<-CRYSTAL
    require "can"
    io = IO::Memory.new
    #{body}
    print io.to_s
    CRYSTAL

  tmp = File.tempfile("can_macro_error_test", ".cr") { |f| f.print(program) }
  begin
    output = IO::Memory.new
    err = IO::Memory.new
    status = Process.run(
      "crystal", ["run", "--no-color", tmp.path],
      env: {"CRYSTAL_PATH" => CRYSTAL_PATH_FOR_TESTS},
      output: output, error: err, chdir: PROJECT_ROOT
    )
    status.success?.should be_false
    err.to_s
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

  it "reports parse errors with inline template location" do
    err = compile_macro_error <<-CR
      Can.template_inline "<div>\\n<span></div>"
      CR
    err.should contain("Can template error in inline template:2:7:")
    err.should_not contain("Unhandled exception")
  end

  it "includes template source markers near generated expression errors" do
    err = compile_macro_error <<-CR
      Can.template_inline %q(<p>{missing}</p>)
      CR
    err.should contain("# can: inline template:1:4")
    err.should contain("undefined local variable or method 'missing'")
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

  it "reports parse errors with file template location" do
    bad = File.tempfile("bad_can_template", ".can") do |f|
      f.print "<div>\n<span></div>"
    end

    begin
      err = compile_macro_error <<-CR
        Can.template #{bad.path.inspect}
        CR
      err.should contain("Can template error in #{bad.path}:2:7:")
      err.should_not contain("Unhandled exception")
    ensure
      bad.delete
    end
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

  it "supports a single-file template with top-level <.def> defined inside a method" do
    out = render_with_macro <<-CR
      name = "Thomas"
      tags = ["one", "two", "three"]
      Can.template "spec/fixtures/inline_components.can"
      CR
    out.should contain("<p>Hello, Thomas.</p>")
    out.should contain("[one]")
    out.should contain("[two]")
    out.should contain("[three]")
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

describe "Can.use / Can.view" do
  it "loads component defs with Can.use and renders a view with Can.view" do
    component = File.tempfile("can_component", ".can") do |f|
      f.print <<-CAN
        <.def tag="card" param:title="String">
          <section class="card"><h2>{title}</h2><.slot/></section>
        </.def>
        CAN
    end
    page = File.tempfile("can_page", ".can") do |f|
      f.print %(<card title={title}><p>{body}</p></card>)
    end

    begin
      out = render_with_macro <<-CR
        module SharedComponents
          Can.use #{component.path.inspect}
        end

        class HomePage
          include SharedComponents

          def title
            "Welcome"
          end

          def body
            "<safe?>"
          end

          Can.view #{page.path.inspect}
        end

        HomePage.new.render(io)
        CR

      out.should contain(%(<section class="card"><h2>Welcome</h2>))
      out.should contain("<p>&lt;safe?&gt;</p>")
    ensure
      component.delete
      page.delete
    end
  end

  it "lets Can.view define components used by its own render body" do
    page = File.tempfile("can_self_contained_page", ".can") do |f|
      f.print <<-CAN
        <.def tag="badge" param:label="String"><span>{label}</span></.def>
        <main><badge label="new"/></main>
        CAN
    end

    begin
      out = render_with_macro <<-CR
        class SelfContainedPage
          Can.view #{page.path.inspect}
        end

        SelfContainedPage.new.render(io)
        CR
      out.should contain(%(<main><span>new</span></main>))
    ensure
      page.delete
    end
  end

  it "loads component defs declared by top-level <.use>" do
    component = File.tempfile("can_used_component", ".can") do |f|
      f.print %(<.def tag="badge" param:label="String"><span>{label}</span></.def>)
    end
    page = File.tempfile("can_page_with_use", ".can") do |f|
      f.print %(<.use from="#{File.basename(component.path)}"/><main><badge label="new"/></main>)
    end

    begin
      out = render_with_macro <<-CR
        class PageWithUse
          Can.view #{page.path.inspect}
        end

        PageWithUse.new.render(io)
        CR

      out.should eq(%(<main><span>new</span></main>))
    ensure
      component.delete
      page.delete
    end
  end

  it "loads component defs declared by <.use> inside a top-level <head>" do
    component = File.tempfile("can_head_used_component", ".can") do |f|
      f.print %(<.def tag="badge" param:label="String"><span>{label}</span></.def>)
    end
    page = File.tempfile("can_page_with_head_use", ".can") do |f|
      f.print <<-CAN
        <html><head><.use from="#{File.basename(component.path)}"/><title>Home</title></head><body><badge label="ok"/></body></html>
        CAN
    end

    begin
      out = render_with_macro <<-CR
        class PageWithHeadUse
          Can.view #{page.path.inspect}
        end

        PageWithHeadUse.new.render(io)
        CR

      out.should contain(%(<head><title>Home</title></head>))
      out.should contain(%(<body><span>ok</span></body>))
      out.should_not contain("<.use")
    ensure
      component.delete
      page.delete
    end
  end

  it "rejects top-level render content in Can.use" do
    component = File.tempfile("can_bad_component", ".can") do |f|
      f.print %(<p>not component-only</p>)
    end

    begin
      err = compile_macro_error <<-CR
        module BadComponents
          Can.use #{component.path.inspect}
        end
        CR
      err.should contain("top-level render content is not allowed in Can.use")
      err.should contain(component.path)
    ensure
      component.delete
    end
  end

  it "rejects render content in files loaded by <.use>" do
    component = File.tempfile("can_bad_used_component", ".can") do |f|
      f.print %(<p>not component-only</p>)
    end
    page = File.tempfile("can_page_with_bad_use", ".can") do |f|
      f.print %(<.use from="#{File.basename(component.path)}"/><main>body</main>)
    end

    begin
      err = compile_macro_error <<-CR
        class BadPageWithUse
          Can.view #{page.path.inspect}
        end
        CR

      err.should contain("top-level render content is not allowed in Can.use")
      err.should contain(component.path)
    ensure
      component.delete
      page.delete
    end
  end
end
