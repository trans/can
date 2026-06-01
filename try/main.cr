require "../src/can"

record Project, name : String, description : String, tags : Array(String)

class HomePage
  getter name : String
  getter projects : Array(Project)

  def initialize(@name : String, @projects : Array(Project))
  end

  Can.use "try/components.can"
  Can.view "try/page.can"
end

HomePage.new(
  "Thomas",
  [
    Project.new("can", "A Crystal server-side web component system", ["crystal", "templates", "ssr"]),
    Project.new("misc", "Other small experiments", ["fun"]),
  ]
).render(STDOUT)
