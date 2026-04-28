require "./spec_helper"

private def parse(src : String) : Can::AST::Template
  Can::Parser.parse(src)
end

private def single(src : String) : Can::AST::Node
  t = parse(src)
  t.children.size.should eq(1)
  t.children.first
end

describe Can::Parser do
  describe "text and interpolation" do
    it "parses plain text" do
      n = single("hello world")
      n.as(Can::AST::Text).content.should eq("hello world")
    end

    it "splits text and {expr} into separate nodes" do
      t = parse("Hi, {name}!")
      t.children.size.should eq(3)
      t.children[0].as(Can::AST::Text).content.should eq("Hi, ")
      t.children[1].as(Can::AST::Interpolation).expression.should eq("name")
      t.children[2].as(Can::AST::Text).content.should eq("!")
    end

    it "handles brace nesting inside expressions" do
      t = parse("{users.map { |u| u.name }.join(\", \")}")
      t.children.size.should eq(1)
      t.children[0].as(Can::AST::Interpolation).expression
        .should eq(%(users.map { |u| u.name }.join(", ")))
    end

    it "ignores braces inside string literals in expressions" do
      t = parse(%({"a }b"}))
      t.children[0].as(Can::AST::Interpolation).expression.should eq(%("a }b"))
    end
  end

  describe "elements" do
    it "parses an empty element" do
      el = single("<div></div>").as(Can::AST::Element)
      el.tag.should eq("div")
      el.attributes.should be_empty
      el.children.should be_empty
    end

    it "parses a self-closing element" do
      el = single("<br/>").as(Can::AST::Element)
      el.tag.should eq("br")
      el.self_closing.should be_true
    end

    it "preserves text inside elements" do
      el = single("<p>hello</p>").as(Can::AST::Element)
      el.children[0].as(Can::AST::Text).content.should eq("hello")
    end

    it "nests elements" do
      el = single("<ul><li>a</li><li>b</li></ul>").as(Can::AST::Element)
      el.children.size.should eq(2)
      el.children[0].as(Can::AST::Element).tag.should eq("li")
    end

    it "errors on mismatched close tag" do
      expect_raises(Can::ParseError, /expected <\/div>/) do
        parse("<div></span>")
      end
    end
  end

  describe "attributes" do
    it "parses string attribute" do
      el = single(%(<a href="/">x</a>)).as(Can::AST::Element)
      a = el.attributes[0].as(Can::AST::StringAttr)
      a.name.should eq("href")
      a.value.should eq("/")
    end

    it "parses expression attribute" do
      el = single(%(<input value={user.name}/>)).as(Can::AST::Element)
      a = el.attributes[0].as(Can::AST::ExprAttr)
      a.name.should eq("value")
      a.expression.should eq("user.name")
    end

    it "parses interpolated string attribute" do
      el = single(%(<a title="hi {name}, msg {n}">x</a>)).as(Can::AST::Element)
      a = el.attributes[0].as(Can::AST::InterpAttr)
      a.parts.size.should eq(4)
      a.parts[0].as(Can::AST::Text).content.should eq("hi ")
      a.parts[1].as(Can::AST::Interpolation).expression.should eq("name")
      a.parts[2].as(Can::AST::Text).content.should eq(", msg ")
      a.parts[3].as(Can::AST::Interpolation).expression.should eq("n")
    end

    it "parses boolean (valueless) attribute" do
      el = single(%(<input disabled/>)).as(Can::AST::Element)
      a = el.attributes[0].as(Can::AST::StringAttr)
      a.name.should eq("disabled")
      a.value.should eq("")
    end

    it "parses namespaced attributes" do
      el = single(%(<.def tag="x" param:title="String"></.def>))
      d = el.as(Can::AST::Def)
      d.tag.should eq("x")
      d.params.size.should eq(1)
      d.params[0].name.should eq("title")
      d.params[0].type.should eq("String")
    end
  end

  describe "<.def>" do
    it "parses a minimal def" do
      d = single(%(<.def tag="hello">Hello</.def>)).as(Can::AST::Def)
      d.tag.should eq("hello")
      d.params.should be_empty
      d.body[0].as(Can::AST::Text).content.should eq("Hello")
    end

    it "parses params" do
      d = single(%(<.def tag="card" param:title="String" param:level="Int32"><h2>{title}</h2></.def>)).as(Can::AST::Def)
      d.params.map(&.name).should eq(["title", "level"])
      d.params.map(&.type).should eq(["String", "Int32"])
    end

    it "errors without a tag" do
      expect_raises(Can::ParseError, /requires a 'tag'/) do
        parse("<.def>x</.def>")
      end
    end
  end

  describe "<.if>" do
    it "parses element form" do
      i = single(%(<.if cond={x > 0}><p>yes</p></.if>)).as(Can::AST::If)
      i.condition.should eq("x > 0")
      i.then_body.size.should eq(1)
      i.else_body.should be_empty
    end

    it "desugars :if attribute" do
      n = single(%(<p :if={admin?}>secret</p>))
      i = n.as(Can::AST::If)
      i.condition.should eq("admin?")
      el = i.then_body[0].as(Can::AST::Element)
      el.tag.should eq("p")
      el.attributes.should be_empty
    end
  end

  describe "<.for>" do
    it "parses element form" do
      f = single(%(<.for each={item in items}><li>{item}</li></.for>)).as(Can::AST::For)
      f.var.should eq("item")
      f.collection.should eq("items")
      f.body[0].as(Can::AST::Element).tag.should eq("li")
    end

    it "desugars :for attribute" do
      n = single(%(<li :for={u in users}>{u.name}</li>))
      f = n.as(Can::AST::For)
      f.var.should eq("u")
      f.collection.should eq("users")
    end

    it "puts :if outside :for when both are present" do
      n = single(%(<li :if={show?} :for={x in xs}>{x}</li>))
      i = n.as(Can::AST::If)
      i.condition.should eq("show?")
      f = i.then_body[0].as(Can::AST::For)
      f.var.should eq("x")
      f.collection.should eq("xs")
      f.body[0].as(Can::AST::Element).tag.should eq("li")
    end
  end

  describe "<.let> / <.slot> / <.import>" do
    it "parses <.let>" do
      l = single(%(<.let name="x" value={1 + 2}>{x}</.let>)).as(Can::AST::Let)
      l.name.should eq("x")
      l.expression.should eq("1 + 2")
    end

    it "parses <.slot/>" do
      s = single("<.slot/>").as(Can::AST::Slot)
      s.name.should be_nil
    end

    it "parses named <.slot>" do
      s = single(%(<.slot name="header"/>)).as(Can::AST::Slot)
      s.name.should eq("header")
    end

    it "parses <:name> as a SlotFill" do
      f = single(%(<:header><h1>logo</h1></:header>)).as(Can::AST::SlotFill)
      f.name.should eq("header")
      f.body[0].as(Can::AST::Element).tag.should eq("h1")
    end

    it "errors when <:name> has attributes" do
      expect_raises(Can::ParseError, /doesn't take attributes/) do
        Can::Parser.parse(%(<:header foo="bar">x</:header>))
      end
    end

    it "parses <.import>" do
      i = single(%(<.import from="components/card"/>)).as(Can::AST::Import)
      i.from.should eq("components/card")
    end
  end

  describe "raw-text tags" do
    it "captures <style> content verbatim, including braces" do
      el = single(%(<style>.card { color: red } h2 { margin: 0 }</style>)).as(Can::AST::Element)
      el.tag.should eq("style")
      el.children.size.should eq(1)
      el.children[0].as(Can::AST::Text).content
        .should eq(".card { color: red } h2 { margin: 0 }")
    end

    it "captures <script> content verbatim" do
      el = single(%(<script>if (x < 3) { foo() }</script>)).as(Can::AST::Element)
      el.children[0].as(Can::AST::Text).content.should eq("if (x < 3) { foo() }")
    end
  end

  describe "comments and doctype" do
    it "parses an HTML comment" do
      c = single("<!-- hi -->").as(Can::AST::Comment)
      c.content.should eq(" hi ")
    end

    it "parses a doctype" do
      d = single("<!DOCTYPE html>").as(Can::AST::Doctype)
      d.content.should eq("DOCTYPE html")
    end
  end

  describe "running examples" do
    it "parses the inline hello example" do
      t = parse(<<-HTML)
        <.def tag="hello">Hello</.def>
        <hello/>
        HTML
      t.children.size.should be >= 2
      d = t.children.find { |n| n.is_a?(Can::AST::Def) }.as(Can::AST::Def)
      d.tag.should eq("hello")
      use = t.children.find { |n| n.is_a?(Can::AST::Element) && n.as(Can::AST::Element).tag == "hello" }
      use.should_not be_nil
    end

    it "parses the card example with style and slot" do
      t = parse(<<-HTML)
        <.def tag="card" param:title="String">
          <style>
            .card { border: 1px solid #ccc; padding: 1rem; }
            h2 { color: navy; }
          </style>
          <div class="card">
            <h2>{title}</h2>
            <div class="body"><.slot/></div>
          </div>
        </.def>
        HTML
      d = t.children.find { |n| n.is_a?(Can::AST::Def) }.as(Can::AST::Def)
      d.tag.should eq("card")
      d.params[0].name.should eq("title")
      style = d.body.find { |n| n.is_a?(Can::AST::Element) && n.as(Can::AST::Element).tag == "style" }
      style.should_not be_nil
      style.as(Can::AST::Element).children[0].as(Can::AST::Text).content.should contain("color: navy")
    end
  end
end
