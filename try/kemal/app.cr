require "kemal"
require "../../src/can"

module LayoutComponents
  Can.use "try/kemal/layout.can"
end

class HomePage
  include LayoutComponents

  getter name : String
  getter todos : Array(String)

  def initialize(@name : String, @todos : Array(String))
  end

  Can.view "try/kemal/home.can"
end

class AboutPage
  include LayoutComponents

  Can.view "try/kemal/about.can"
end

class Pages
  def home(name : String, todos : Array(String)) : String
    String.build do |io|
      HomePage.new(name, todos).render(io)
    end
  end

  def about : String
    String.build do |io|
      AboutPage.new.render(io)
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
