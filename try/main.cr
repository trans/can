require "../src/can"

record Project, name : String, description : String, tags : Array(String)

class HomePage
  Can.template "try/components.can"

  def render(io : IO)
    name = "Thomas"
    projects = [
      Project.new("can",  "A Crystal server-side web component system",  ["crystal", "templates", "ssr"]),
      Project.new("misc", "Other small experiments",                     ["fun"]),
    ]
    Can.template "try/page.can"
  end
end

HomePage.new.render(STDOUT)
