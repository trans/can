require "./spec_helper"

private def scope(css : String, attr : String = "data-c") : String
  Can::CssScoper.scope(css, attr)
end

describe Can::CssScoper do
  describe "simple selectors" do
    it "scopes a tag selector" do
      scope("h2 { color: red }").should eq("h2[data-c] { color: red }")
    end

    it "scopes a class selector" do
      scope(".card { padding: 1rem }").should eq(".card[data-c] { padding: 1rem }")
    end

    it "scopes an id selector" do
      scope("#main { width: 100% }").should eq("#main[data-c] { width: 100% }")
    end

    it "scopes a universal selector" do
      scope("* { box-sizing: border-box }").should eq("*[data-c] { box-sizing: border-box }")
    end

    it "scopes a chained simple selector" do
      scope(".card.big { color: blue }").should eq(".card.big[data-c] { color: blue }")
    end

    it "scopes an attribute selector" do
      scope("input[disabled] { opacity: .5 }").should eq("input[disabled][data-c] { opacity: .5 }")
    end
  end

  describe "pseudo-classes and elements" do
    it "places the suffix before :hover" do
      scope(".card:hover { color: blue }").should eq(".card[data-c]:hover { color: blue }")
    end

    it "places the suffix before ::before" do
      scope(".card::before { content: '' }").should eq(".card[data-c]::before { content: '' }")
    end

    it "places the suffix before :nth-child(2n+1)" do
      scope("li:nth-child(2n+1) { color: red }").should eq("li[data-c]:nth-child(2n+1) { color: red }")
    end

    it "ignores `:` inside :not(...)" do
      scope(".foo:not(:hover) { color: red }").should eq(".foo[data-c]:not(:hover) { color: red }")
    end

    it "scopes a starting :root" do
      scope(":root { --x: 1 }").should eq("[data-c]:root { --x: 1 }")
    end
  end

  describe "combinators" do
    it "scopes both sides of a descendant combinator" do
      scope(".card h2 { color: navy }").should eq(".card[data-c] h2[data-c] { color: navy }")
    end

    it "scopes both sides of a child combinator" do
      scope(".card > h2 { color: navy }").should eq(".card[data-c] > h2[data-c] { color: navy }")
    end

    it "scopes both sides of an adjacent-sibling combinator" do
      scope("h2 + p { margin: 0 }").should eq("h2[data-c] + p[data-c] { margin: 0 }")
    end

    it "scopes both sides of a general-sibling combinator" do
      scope("h2 ~ p { color: gray }").should eq("h2[data-c] ~ p[data-c] { color: gray }")
    end
  end

  describe "selector lists" do
    it "scopes each member of a selector list" do
      scope(".a, .b, .c { color: red }").should eq(".a[data-c], .b[data-c], .c[data-c] { color: red }")
    end

    it "doesn't split inside :is(a, b)" do
      scope(":is(.a, .b) { color: red }").should eq("[data-c]:is(.a, .b) { color: red }")
    end
  end

  describe "at-rules" do
    it "recurses into @media" do
      scope("@media (min-width: 600px) { .card { color: red } }").should eq(
        "@media (min-width: 600px) { .card[data-c] { color: red } }"
      )
    end

    it "recurses into @supports" do
      scope("@supports (display: grid) { .grid { display: grid } }").should eq(
        "@supports (display: grid) { .grid[data-c] { display: grid } }"
      )
    end

    it "passes @keyframes selectors through unchanged" do
      out = scope("@keyframes fade { from { opacity: 0 } to { opacity: 1 } }")
      out.should contain("@keyframes fade")
      out.should_not contain("from[data-c]")
      out.should_not contain("to[data-c]")
    end

    it "passes @font-face through unchanged" do
      out = scope(%(@font-face { font-family: "X"; src: url(x) }))
      out.should contain("@font-face")
      out.should_not contain("[data-c]")
    end

    it "passes @import through unchanged" do
      scope(%(@import "reset.css";)).should contain(%(@import "reset.css";))
    end
  end

  describe "comments and strings" do
    it "preserves comments outside selectors" do
      scope("/* hi */ .card { color: red }").should contain("/* hi */")
    end

    it "preserves strings inside declarations" do
      out = scope(%(.x { content: "{ ; }" }))
      out.should contain(%(content: "{ ; }"))
    end
  end

  describe "multiple rules" do
    it "scopes each rule independently" do
      out = scope(".a { color: red } .b { color: blue }")
      out.should contain(".a[data-c]")
      out.should contain(".b[data-c]")
    end
  end
end
