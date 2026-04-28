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
    {{ run("./can/cli/compile_template", "inline", source).id }}
  end

  # Same as `template_inline`, but reads the template from a file path
  # resolved relative to the compile-time working directory (typically the
  # project root).
  #
  #     io = IO::Memory.new
  #     user = current_user
  #     Can.template "pages/home.can"
  macro template(path)
    {{ run("./can/cli/compile_template", "file", path).id }}
  end
end
