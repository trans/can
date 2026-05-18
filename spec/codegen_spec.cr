require "./spec_helper"

private def gen(src : String) : String
  Can::Codegen.compile(src)
end

# Compiles the template, splices the generated code into a small script that
# defines `io` and any `prelude` Crystal, runs it via `crystal run`, and
# returns the captured stdout. Real round-trip — covers escaping behavior.
private def render(src : String, prelude : String = "") : String
  body = Can::Codegen.compile(src)
  script = <<-CRYSTAL
    require "can"
    io = IO::Memory.new
    #{prelude}
    #{body}
    print io.to_s
    CRYSTAL

  tmp = File.tempfile("can_render", ".cr") { |f| f.print(script) }
  begin
    output = IO::Memory.new
    err = IO::Memory.new
    status = Process.run(
      "crystal", ["run", "--no-color", tmp.path],
      env: {"CRYSTAL_PATH" => CRYSTAL_PATH_FOR_TESTS},
      output: output, error: err
    )
    unless status.success?
      raise "crystal run failed:\n#{err}\n--- script ---\n#{script}"
    end
    output.to_s
  ensure
    tmp.delete
  end
end

describe Can::Codegen do
  describe "source generation" do
    it "emits text as a Crystal string write" do
      gen("hello").should contain(%(io << "hello"))
    end

    it "emits interpolation via Can.write_escaped" do
      gen("{name}").should contain("::Can.write_escaped(io, (name))")
    end

    it "emits raw interpolation without the escape helper inside <.raw>" do
      out = gen("<.raw>{name}</.raw>")
      out.should contain("io << (name).to_s")
      out.should_not contain("::Can.write_escaped")
    end

    it "emits an element open and close" do
      out = gen("<p>hi</p>")
      out.should contain(%(io << "<p"))
      out.should contain(%(io << ">"))
      out.should contain(%(io << "hi"))
      out.should contain(%(io << "</p>"))
    end

    it "emits expression attributes wrapped in escape" do
      out = gen(%(<input value={x}/>))
      out.should contain(%(io << " value=\\""))
      out.should contain("::Can.write_escaped(io, (x))")
    end

    it "emits boolean attribute as bare name" do
      gen(%(<input disabled/>)).should contain(%(io << " disabled"))
    end

    it "emits <.if> as a Crystal if/end" do
      out = gen(%(<.if cond={x > 0}>hi</.if>))
      out.should contain("if (x > 0)")
      out.should contain("end")
    end

    it "emits <.if>/<.else/> as Crystal if/else/end" do
      out = gen(%(<.if cond={x}>yes<.else/>no</.if>))
      out.should contain("if (x)")
      out.should contain("else")
      out.should contain("end")
    end

    it "emits <.elseif/> chains as Crystal elsif" do
      out = gen(%(<.if cond={a}>1<.elseif cond={b}/>2<.elseif cond={c}/>3<.else/>4</.if>))
      out.should contain("if (a)")
      out.should contain("elsif (b)")
      out.should contain("elsif (c)")
      out.should contain("else")
    end

    it "rejects a stray <.else/> outside <.if>" do
      expect_raises(Exception, /only appear inside/) { gen("<.else/>") }
    end

    it "emits <.for> as .each with the bound var" do
      out = gen(%(<.for each={item in items}>{item}</.for>))
      out.should contain("(items).each do |item|")
    end

    it "emits <.let> as assignment" do
      gen(%(<.let name="x" value={1+2}>{x}</.let>)).should contain("x = (1+2)")
    end

    it "emits <.def> as a Crystal method definition with block param" do
      out = gen(%(<.def tag="x" param:title="String">y</.def>))
      out.should contain("def x(io : IO, title : String, &block : IO -> _) : Nil")
      out.should contain(%(io << "y"))
    end

    it "emits a param default and omits the type annotation when defaulted" do
      out = gen(%(<.def tag="card" param:title="String" param:level={2_i32}>y</.def>))
      out.should contain("def card(io : IO, title : String, level = 2_i32, &block : IO -> _) : Nil")
    end

    it "emits <.slot/> as block.call(io) inside a top-level def" do
      gen(%(<.def tag="x"><.slot/></.def>)).should contain("block.call(io)")
    end

    it "emits a named <.slot/> as a Proc-keyword call inside a top-level def" do
      out = gen(%(<.def tag="card" param:title="String"><.slot name="header"/></.def>))
      out.should contain("header : Proc(IO, Nil)")
      out.should contain("header.call(io)")
    end

    it "rejects <.slot/> outside any top-level def" do
      expect_raises(Exception, /only appear inside a top-level/) { gen("<.slot/>") }
    end

    it "emits <.import/> as a Crystal require" do
      gen(%(<.import from="components/card"/>)).should contain(%(require "components/card"))
    end

    it "lowers a nested <.def> to a local Proc" do
      out = gen(%(<.def tag="outer"><.def tag="inner">hi</.def><inner/></.def>))
      out.should contain("__can_inner = ->(io : IO")
      out.should contain("__can_inner.call(io)")
    end

    it "emits a known HTML tag as literal" do
      gen("<div></div>").should contain(%(io << "<div"))
    end

    it "emits an unknown tag as a component method call" do
      out = gen(%(<Card title="Hi"/>))
      out.should contain("card(io")
      out.should contain(%(title: "Hi"))
      out.should contain("end")
    end

    it "lowercases and underscores hyphenated component tags" do
      out = gen(%(<my-card/>))
      out.should contain("my_card(io")
    end

    it "passes expression attribute as raw Crystal in component call" do
      out = gen(%(<Card level={2}/>))
      out.should contain("level: (2)")
    end
  end

  describe "rendered output (round-trip)" do
    it "renders a plain element" do
      render("<p>hi</p>").should eq("<p>hi</p>")
    end

    it "escapes interpolated values" do
      render("<p>{name}</p>", prelude: %(name = "<world>")).should eq("<p>&lt;world&gt;</p>")
    end

    it "preserves static content verbatim (no double-escape)" do
      render("<p>5 &lt; 3</p>").should eq("<p>5 &lt; 3</p>")
    end

    it "renders a string attribute" do
      render(%(<a href="/x">link</a>)).should eq(%(<a href="/x">link</a>))
    end

    it "renders an interpolated attribute" do
      render(%(<a class="card {kind}">x</a>), prelude: %(kind = "blue"))
        .should eq(%(<a class="card blue">x</a>))
    end

    it "renders an expression attribute and escapes its value" do
      render(%(<a title={t}>x</a>), prelude: %(t = %(<bad>)))
        .should eq(%(<a title="&lt;bad&gt;">x</a>))
    end

    it "renders <.if> taking the true branch" do
      render(%(<.if cond={true}><p>yes</p></.if>)).should eq("<p>yes</p>")
    end

    it "renders <.if> skipping the false branch" do
      render(%(<.if cond={false}><p>no</p></.if>)).should eq("")
    end

    it "renders the else branch when condition is false" do
      render(%(<.if cond={false}><p>yes</p><.else/><p>no</p></.if>)).should eq("<p>no</p>")
    end

    it "renders an elseif chain, picking the first match" do
      out = render(%(<.if cond={n == 1}>one<.elseif cond={n == 2}/>two<.elseif cond={n == 3}/>three<.else/>other</.if>),
        prelude: %(n = 2))
      out.should eq("two")
    end

    it "falls through an elseif chain to else" do
      out = render(%(<.if cond={n == 1}>one<.elseif cond={n == 2}/>two<.else/>other</.if>),
        prelude: %(n = 99))
      out.should eq("other")
    end

    it "renders <.for>" do
      render(%(<ul><.for each={n in [1, 2, 3]}><li>{n}</li></.for></ul>))
        .should eq("<ul><li>1</li><li>2</li><li>3</li></ul>")
    end

    it "renders <.let>" do
      render(%(<.let name="x" value={1+2}>{x}</.let>)).should eq("3")
    end

    it "renders :if attribute desugared" do
      render(%(<p :if={true}>yes</p>)).should eq("<p>yes</p>")
    end

    it "renders :for attribute desugared" do
      render(%(<li :for={x in ["a", "b"]}>{x}</li>)).should eq("<li>a</li><li>b</li>")
    end

    it "renders :if outside :for when both are present" do
      render(%(<li :if={ok} :for={x in xs}>{x}</li>),
        prelude: %(ok = true; xs = ["a", "b"]))
        .should eq("<li>a</li><li>b</li>")
    end

    it "renders <style> content verbatim (no escape)" do
      render(%(<style>.card { color: red } h2 > span { margin: 0 }</style>))
        .should eq(%(<style>.card { color: red } h2 > span { margin: 0 }</style>))
    end

    it "renders an HTML comment" do
      # Wrapped in <div> so it's not at the top level (where class-scope
      # codegen drops comments, since there's no io to write to).
      render("<div><!-- hi --></div>").should eq("<div><!-- hi --></div>")
    end

    it "renders a doctype" do
      render("<!DOCTYPE html>").should eq("<!DOCTYPE html>")
    end

    it "renders a self-closing tag" do
      render(%(<img src="x.png"/>)).should eq(%(<img src="x.png"/>))
    end

    it "renders <.raw> content without escaping" do
      out = render(%(<div><.raw>{html}</.raw></div>), prelude: %(html = "<b>bold</b>"))
      out.should eq("<div><b>bold</b></div>")
    end

    it "still escapes interpolations outside <.raw>" do
      out = render(%(<div>{x}</div>), prelude: %(x = "<b>"))
      out.should eq("<div>&lt;b&gt;</div>")
    end

    it "treats Can.raw values as already-escaped" do
      out = render(%(<div>{x}</div>), prelude: %(x = Can.raw("<b>bold</b>")))
      out.should eq("<div><b>bold</b></div>")
    end

    it "doesn't penetrate <.raw> into a def body's interpolations" do
      out = render <<-CAN, prelude: %(html = "<i>i</i>")
        <.def tag="echo" param:s="String"><p>{s}</p></.def>
        <.raw><echo s={html}/></.raw>
        CAN
      out.should contain("<p>&lt;i&gt;i&lt;/i&gt;</p>")
    end
  end

  describe "components (round-trip)" do
    it "defines and invokes a component with a slot" do
      out = render <<-CAN
        <.def tag="card" param:title="String">
          <div class="card"><h2>{title}</h2><.slot/></div>
        </.def>
        <card title="Hi"><p>body</p></card>
        CAN
      out.should contain(%(<div class="card"><h2>Hi</h2>))
      out.should contain("<p>body</p>")
      out.should contain("</div>")
    end

    it "uses param defaults when not overridden" do
      out = render <<-CAN
        <.def tag="badge" param:label="String" param:emoji={"✨"}><span>{emoji} {label}</span></.def>
        <badge label="crystal"/>
        <badge label="ruby" emoji="💎"/>
        CAN
      out.should contain("<span>✨ crystal</span>")
      out.should contain("<span>💎 ruby</span>")
    end

    it "rejects defaults on inline <.def>" do
      expect_raises(NotImplementedError, /defaults are top-level-only/) do
        Can::Codegen.compile(%(<div><.def tag="x" param:n={0_i32}>{n}</.def><x/></div>))
      end
    end

    it "renders a component with multiple params" do
      out = render <<-CAN
        <.def tag="greeting" param:name="String" param:n="Int32">
          <p>Hi {name}, you have {n}.</p>
        </.def>
        <greeting name="Thomas" n={3}/>
        CAN
      out.should contain("<p>Hi Thomas, you have 3.</p>")
    end

    it "escapes interpolated component args at the receiver's interpolation site" do
      out = render <<-CAN, prelude: %(name = "<bad>")
        <.def tag="hi" param:who="String">
          <p>hi {who}</p>
        </.def>
        <hi who={name}/>
        CAN
      out.should contain("<p>hi &lt;bad&gt;</p>")
    end

    it "supports a component without a slot in its body" do
      out = render <<-CAN
        <.def tag="banner" param:msg="String">
          <h1>{msg}</h1>
        </.def>
        <banner msg="Welcome"/>
        CAN
      out.should contain("<h1>Welcome</h1>")
    end

    it "nests components inside HTML and other components" do
      out = render <<-CAN
        <.def tag="card" param:title="String">
          <div class="card"><h2>{title}</h2><.slot/></div>
        </.def>
        <main>
          <card title="Outer">
            <card title="Inner"><p>nested</p></card>
          </card>
        </main>
        CAN
      out.should contain("<h2>Outer</h2>")
      out.should contain("<h2>Inner</h2>")
      out.should contain("<p>nested</p>")
    end

    it "supports control flow in a component body" do
      out = render <<-CAN
        <.def tag="list" param:items="Array(String)">
          <.if cond={items.empty?}><p>none</p></.if>
          <ul :if={!items.empty?}><.for each={x in items}><li>{x}</li></.for></ul>
        </.def>
        <list items={["a", "b"]}/>
        <list items={[] of String}/>
        CAN
      out.should contain("<li>a</li>")
      out.should contain("<li>b</li>")
      out.should contain("<p>none</p>")
    end

    it "maps PascalCase and kebab-case to the same method" do
      out = render <<-CAN
        <.def tag="my-thing">A</.def>
        <MyThing/><my-thing/><my_thing/>
        CAN
      out.scan("A").size.should eq(3)
    end
  end

  describe "inline <.def> (round-trip)" do
    it "lowers an inline def to a Proc and invokes it" do
      out = render <<-CAN
        <div>
          <.def tag="badge">[hi]</.def>
          <badge/>
        </div>
        CAN
      out.should contain("<div>")
      out.should contain("[hi]")
      out.should contain("</div>")
    end

    it "captures surrounding bindings (closure)" do
      out = render <<-CAN, prelude: %(name = "Thomas")
        <div>
          <.def tag="greet">hi {name}</.def>
          <greet/>
        </div>
        CAN
      out.should contain("hi Thomas")
    end

    it "passes positional args to an inline def" do
      out = render <<-CAN
        <div>
          <.def tag="row" param:label="String" param:n="Int32">
            <p>{label}={n}</p>
          </.def>
          <row label="x" n={1}/>
          <row label="y" n={2}/>
        </div>
        CAN
      out.should contain("<p>x=1</p>")
      out.should contain("<p>y=2</p>")
    end

    it "rejects <.slot/> inside an inline def" do
      expect_raises(NotImplementedError, /class\/module scope/) do
        Can::Codegen.compile(%(<div><.def tag="x"><.slot/></.def></div>))
      end
    end

    it "lowers a top-level <.def> to a Proc when scope is :method" do
      out = Can::Codegen.compile(%(<.def tag="hello">hi</.def><hello/>), :method)
      out.should contain("__can_hello = ->(io : IO")
      out.should contain("__can_hello.call(io)")
      out.should_not contain("def hello(")
    end

    it "errors with file-split guidance for slot-bearing top-level def in :method scope" do
      expect_raises(NotImplementedError, /move this <\.def> into a separate \.can file/) do
        Can::Codegen.compile(%(<.def tag="card"><div><.slot/></div></.def><card>x</card>), :method)
      end
    end

    it "rejects slot content on an inline component invocation" do
      expect_raises(NotImplementedError, /can't accept slot content/) do
        Can::Codegen.compile(%(<div><.def tag="x">a</.def><x>body</x></div>))
      end
    end
  end

  describe "named slots and slot fills (round-trip)" do
    it "renders content into a named slot" do
      out = render <<-CAN
        <.def tag="page" param:title="String"><header><.slot name="header"/></header><main><.slot/></main><footer><.slot name="footer"/></footer></.def>
        <page title="Hi"><:header><h1>HEAD</h1></:header><p>body</p><:footer><small>FOOT</small></:footer></page>
        CAN
      out.should contain("<header><h1>HEAD</h1></header>")
      out.should contain("<main><p>body</p></main>")
      out.should contain("<footer><small>FOOT</small></footer>")
    end

    it "renders empty content for an unfilled named slot" do
      out = render <<-CAN
        <.def tag="page"><header><.slot name="header"/></header><main><.slot/></main></.def>
        <page><p>just body</p></page>
        CAN
      out.should contain("<header></header>")
      out.should contain("<main><p>just body</p></main>")
    end

    it "named slot fills can use surrounding bindings" do
      out = render <<-CAN, prelude: %(user = "Thomas")
        <.def tag="card"><h2><.slot name="title"/></h2><div><.slot/></div></.def>
        <card><:title>Hello, {user}</:title><p>welcome</p></card>
        CAN
      out.should contain("<h2>Hello, Thomas</h2>")
      out.should contain("<div><p>welcome</p></div>")
    end
  end

  describe "scoped CSS (round-trip)" do
    it "stamps a data-attr on elements rendered by a styled component" do
      out = render <<-CAN
        <.def tag="card"><style>.card { color: red }</style><div class="card">hi</div></.def>
        <card/>
        CAN
      out.should match(/<div class="card" data-c-card-[a-f0-9]{6}>hi<\/div>/)
    end

    it "rewrites the component's <style> selectors to include the data-attr" do
      out = render <<-CAN
        <.def tag="card"><style>.card { color: red } h2 { margin: 0 }</style><div class="card"><h2>hi</h2></div></.def>
        <card/>
        CAN
      out.should match(/\.card\[data-c-card-[a-f0-9]{6}\] \{ color: red \}/)
      out.should match(/h2\[data-c-card-[a-f0-9]{6}\] \{ margin: 0 \}/)
    end

    it "stamps the same id on all elements of one component" do
      out = render <<-CAN
        <.def tag="card"><style>.card { color: red }</style><div class="card"><h2>hi</h2><p>x</p></div></.def>
        <card/>
        CAN
      attrs = out.scan(/data-c-card-([a-f0-9]{6})/).map(&.[1])
      attrs.uniq.size.should eq(1)
      # div + h2 + p + the style tag itself = 4 stampings minimum
      attrs.size.should be >= 4
    end

    it "gives different components different ids" do
      out = render <<-CAN
        <.def tag="a-card"><style>.x { color: red }</style><div>A</div></.def>
        <.def tag="b-card"><style>.x { color: blue }</style><div>B</div></.def>
        <a-card/><b-card/>
        CAN
      ids = out.scan(/data-c-([a-z]+-card)-([a-f0-9]{6})/).map { |m| {m[1], m[2]} }.uniq
      ids.size.should eq(2)
      ids[0][1].should_not eq(ids[1][1])
    end

    it "doesn't stamp components without a <style>" do
      out = render <<-CAN
        <.def tag="card"><div class="card">hi</div></.def>
        <card/>
        CAN
      out.should_not match(/data-c-card/)
    end

    it "doesn't leak the parent's data-attr onto a nested component's elements" do
      out = render <<-CAN
        <.def tag="outer"><style>.outer { color: red }</style><div class="outer"><inner/></div></.def>
        <.def tag="inner"><style>.inner { color: blue }</style><span class="inner">x</span></.def>
        <outer/>
        CAN
      # outer stamps the div, inner stamps the span — never the other way.
      out.should match(/<div class="outer" data-c-outer-[a-f0-9]{6}>/)
      out.should match(/<span class="inner" data-c-inner-[a-f0-9]{6}>/)
      out.should_not match(/<span class="inner" data-c-outer/)
      out.should_not match(/<div class="outer" data-c-inner/)
    end
  end
end
