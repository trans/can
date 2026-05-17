require "kemal"
require "../../src/can"

# Pages collects render methods. Layout-component defs (with slots) live in
# layout.can and load at class scope; per-page templates load inside each
# method, where their content is rendered inside the layout via slot fills.
class Pages
  Can.template "try/kemal/layout.can"

  def home(name : String, todos : Array(String)) : String
    String.build do |io|
      Can.template "try/kemal/home.can"
    end
  end

  def about : String
    String.build do |io|
      Can.template "try/kemal/about.can"
    end
  end
end

PAGES = Pages.new

get "/" do |env|
  env.response.content_type = "text/html"
  name = env.params.query["name"]? || "stranger"
  todos = ["buy milk", "write more crystal", "go for a walk"]
  PAGES.home(name, todos)
end

get "/about" do |env|
  env.response.content_type = "text/html"
  PAGES.about
end

Kemal.run
