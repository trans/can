require "html"
require "./can/ast"
require "./can/parser"
require "./can/css_scope"
require "./can/codegen"

module Can
  VERSION = "0.1.0"

  # Compiles a template literal at macro expansion time and splices the
  # generated Crystal source in-place. The generated code writes HTML to a
  # local `io` (which the caller is responsible for having in scope).
  #
  #     io = IO::Memory.new
  #     name = "Thomas"
  #     Can.template_inline "<p>Hello, {name}!</p>"
  #     io.to_s # => "<p>Hello, Thomas!</p>"
  macro template_inline(source)
    {% if @def %}
      {{ run("./can/cli/compile_template", "inline", source, "method").id }}
    {% else %}
      {{ run("./can/cli/compile_template", "inline", source, "class").id }}
    {% end %}
  end

  # Same as `template_inline`, but reads the template from a file path
  # resolved relative to the compile-time working directory (typically the
  # project root).
  #
  #     io = IO::Memory.new
  #     user = current_user
  #     Can.template "pages/home.can"
  #
  # When called inside a method body, top-level `<.def>` blocks are lowered
  # to local `Proc`s (since Crystal forbids nested `def`s). Slot-bearing
  # components must therefore be defined at class/module scope.
  macro template(path)
    {% if @def %}
      {{ run("./can/cli/compile_template", "file", path, "method").id }}
    {% else %}
      {{ run("./can/cli/compile_template", "file", path, "class").id }}
    {% end %}
  end
end
