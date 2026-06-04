require "digest/crc32"
require "set"
require "./ast"
require "./parser"
require "./css_scope"

module Can
  # Codegen: emits Crystal source that writes HTML to a local `io`.
  #
  # Static text from the source template is emitted verbatim — author
  # responsibility to write valid HTML (e.g. `&lt;` for literal `<`).
  # Interpolated `{expr}` values in text and expression attributes are
  # HTML-escaped at runtime via stdlib `::HTML.escape`. On HTML tags,
  # expression attributes render true as a bare attribute and omit false/nil.
  # Quoted attributes are literal text.
  #
  # Tags render as literal HTML unless Can can resolve them to a component
  # method. `<.def tag="Card">` defines `card(io, ...)`, and `<Card>` calls it.
  # Manually written methods can also be used as components when their first
  # argument is named `io`; otherwise unknown tags pass through as literal HTML.
  # The tag is mapped to a method name via `tag.gsub('-', '_').underscore`.
  #
  # Top-level `<.def>` blocks become methods with optional named-slot `Proc`
  # params and a default-slot `__slot` proc. `<.def>` inside a render body
  # becomes a local `Proc` that closes over surrounding bindings. Inline defs
  # can't host `<.slot/>`, can't have param defaults, and can't be invoked
  # with child or slot content.
  class Codegen
    RAW_TEXT_TAGS = {"style", "script"}

    HTML_ELEMENTS = Set{
      "a", "abbr", "address", "area", "article", "aside", "audio",
      "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button",
      "canvas", "caption", "cite", "code", "col", "colgroup",
      "data", "datalist", "dd", "del", "details", "dfn", "dialog", "div", "dl", "dt",
      "em", "embed",
      "fieldset", "figcaption", "figure", "footer", "form",
      "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html",
      "i", "iframe", "img", "input", "ins",
      "kbd",
      "label", "legend", "li", "link",
      "main", "map", "mark", "menu", "meta", "meter",
      "nav", "noscript",
      "object", "ol", "optgroup", "option", "output",
      "p", "picture", "pre", "progress",
      "q",
      "rp", "rt", "ruby",
      "s", "samp", "script", "search", "section", "select", "slot", "small",
      "source", "span", "strong", "style", "sub", "summary", "sup", "svg",
      "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
      "time", "title", "tr", "track",
      "u", "ul",
      "var", "video",
      "wbr",
      # SVG elements. Tags are checked case-insensitively, but emitted using
      # the author's original spelling for names such as linearGradient.
      "animate", "animatemotion", "animatetransform", "circle", "clippath",
      "defs", "desc", "ellipse", "feblend", "fecolormatrix",
      "fecomponenttransfer", "fecomposite", "feconvolvematrix",
      "fediffuselighting", "fedisplacementmap", "fedistantlight",
      "fedropshadow", "feflood", "fefunca", "fefuncb", "fefuncg", "fefuncr",
      "fegaussianblur", "feimage", "femerge", "femergenode",
      "femorphology", "feoffset", "fepointlight", "fespecularlighting",
      "fespotlight", "fetile", "feturbulence", "filter", "foreignobject",
      "g", "image", "line", "lineargradient", "marker", "mask",
      "metadata", "mpath", "path", "pattern", "polygon", "polyline",
      "radialgradient", "rect", "set", "stop", "symbol", "textpath",
      "tspan", "use", "view",
    }

    @out : IO
    @scope : Symbol
    @inline_def_scopes : Array(Hash(String, Array(String)))
    @in_top_level_def : Bool = false
    @in_raw : Bool = false
    @current_component_attr : String? = nil
    @current_component_methods : Array(String)
    @source_name : String?
    @used_templates : Set(String)
    @component_methods : Set(String)
    @tmp_counter : Int32 = 0

    # Compiles a parsed template to Crystal source. When `source_name` is
    # provided, generated code includes `# can: source:line:column` markers
    # that make macro-expansion errors easier to map back to the template.
    def self.compile(template : AST::Template, scope : Symbol = :class, source_name : String? = nil) : String
      String.build { |sb| new(sb, scope, source_name).emit_template(template) }
    end

    # Parses and compiles a template string to Crystal source.
    def self.compile(source : String, scope : Symbol = :class, source_name : String? = nil) : String
      compile(Parser.parse(source), scope, source_name)
    end

    def initialize(@out : IO, @scope : Symbol = :class, @source_name : String? = nil,
                   @used_templates : Set(String) = Set(String).new,
                   @component_methods : Set(String) = Set(String).new)
      @inline_def_scopes = [Hash(String, Array(String)).new]
      @current_component_methods = [] of String
    end

    def emit_template(t : AST::Template) : Nil
      case @scope
      when :use
        emit_use_template(t)
      when :view
        emit_view_template(t)
      else
        t.children.each { |n| emit_top_level(n) }
      end
    end

    private def emit_use_template(t : AST::Template) : Nil
      t.children.each do |n|
        case n
        when AST::Def
          emit_top_level_def(n)
        when AST::Require
          emit_require(n)
        when AST::Use
          emit_use(n)
        when AST::Text
          next if n.content.blank?
          raise_at(n, "top-level render content is not allowed in Can.use")
        when AST::Comment
          next
        else
          raise_at(n, "top-level render content is not allowed in Can.use")
        end
      end
    end

    private def emit_view_template(t : AST::Template) : Nil
      render_nodes = [] of AST::Node

      t.children.each do |n|
        case n
        when AST::Def
          emit_top_level_def(n)
        when AST::Require
          emit_require(n)
        when AST::Use
          emit_use(n)
        when AST::Element
          emit_top_level_head_uses(n)
          render_nodes << n
        else
          render_nodes << n
        end
      end

      @out << "def render(io : IO) : Nil\n"
      with_scope do
        render_nodes.each { |n| emit_node(n) }
      end
      @out << "end\n"
    end

    private def emit_top_level(n : AST::Node) : Nil
      case n
      when AST::Def
        # At class scope, lower to a real method. At method scope, Crystal
        # forbids nested `def`, so we lower to a local Proc — same shape as
        # an inline def. Slot-bearing components are class-scope-only and
        # error clearly when met in method scope.
        @scope == :method ? emit_inline_def(n) : emit_top_level_def(n)
      when AST::Require then emit_require(n)
      when AST::Use
        raise_at(n, "<.use/> must be loaded at class/module scope") if @scope == :method
        emit_use(n)
      when AST::Text
        # At class scope there's no `io` to write to, so dropping
        # whitespace between top-level defs lets a components-only file
        # expand cleanly.
        return if @scope == :class && n.content.blank?
        emit_node(n)
      when AST::Comment
        # Comments between top-level defs in a components-only file have
        # nowhere to go — drop them silently at class scope.
        return if @scope == :class
        emit_node(n)
      else
        emit_node(n)
      end
    end

    private def emit_node(n : AST::Node) : Nil
      case n
      when AST::Text          then emit_text(n)
      when AST::Interpolation then emit_interp(n)
      when AST::Element       then emit_element(n)
      when AST::If            then emit_if(n)
      when AST::For           then emit_for(n)
      when AST::Let           then emit_let(n)
      when AST::Slot          then emit_slot(n)
      when AST::Def           then emit_inline_def(n)
      when AST::Raw           then emit_raw(n)
      when AST::Comment       then emit_comment(n)
      when AST::Doctype       then emit_doctype(n)
      when AST::SlotFill
        raise_at(n, "<:#{n.name}> slot-fill is only valid as a child of a component invocation")
      when AST::Require
        raise_at(n, "<.require/> is only allowed at the top level of a template")
      when AST::Use
        raise_at(n, "<.use/> is only allowed at the top level of a template or as a direct child of <head>")
      when AST::ElseMark
        raise_at(n, "<.else/> can only appear inside a <.if> body")
      when AST::ElseIfMark
        raise_at(n, "<.elseif/> can only appear inside a <.if> body")
      else
        raise_at(n, "codegen: unhandled node #{n.class.name}")
      end
    end

    private def emit_text(n : AST::Text) : Nil
      emit_source_marker(n)
      emit_static(n.content)
    end

    private def emit_interp(n : AST::Interpolation) : Nil
      emit_source_marker(n)
      emit_escaped_expr(n.expression)
    end

    private def emit_element(n : AST::Element) : Nil
      emit_source_marker(n)
      method = tag_to_method_name(n.tag)
      if self_shadowing_platform_tag?(n, method)
        emit_html_element(n)
      elsif component_method?(method)
        emit_component_call(n)
      else
        emit_manual_component_or_html(n, method)
      end
    end

    private def emit_html_element(n : AST::Element) : Nil
      attr = @current_component_attr

      if n.tag == "style" && attr && !n.children.empty?
        emit_scoped_style(n, attr)
        return
      end

      emit_static("<#{n.tag}")
      n.attributes.each { |a| emit_attribute(a) }
      emit_static(" #{attr}") if attr

      if n.self_closing
        emit_static("/>")
        return
      end

      emit_static(">")

      raw = RAW_TEXT_TAGS.includes?(n.tag)
      with_scope do
        n.children.each do |c|
          if raw && c.is_a?(AST::Text)
            emit_static(c.content)
          else
            emit_node(c)
          end
        end
      end

      emit_static("</#{n.tag}>")
    end

    private def emit_scoped_style(n : AST::Element, attr : String) : Nil
      raw_css = String.build do |sb|
        n.children.each do |c|
          sb << c.content if c.is_a?(AST::Text)
        end
      end

      scoped = CssScoper.scope(raw_css, attr)

      emit_static("<style")
      n.attributes.each { |a| emit_attribute(a) }
      emit_static(" #{attr}")
      emit_static(">")
      emit_static(scoped)
      emit_static("</style>")
    end

    private def emit_component_call(n : AST::Element) : Nil
      method = tag_to_method_name(n.tag)

      named_fills = {} of String => Array(AST::Node)
      default_children = [] of AST::Node
      n.children.each do |c|
        if c.is_a?(AST::SlotFill)
          raise_at(c, "duplicate slot fill <:#{c.name}> in component <#{n.tag}>") if named_fills.has_key?(c.name)
          named_fills[c.name] = c.body
        else
          default_children << c
        end
      end

      if params = inline_def_params(method)
        unless default_children.empty? && named_fills.empty?
          raise_not_implemented_at(n,
            "inline component <#{n.tag}> can't accept slot content (only top-level <.def> components support slots)"
          )
        end
        emit_inline_proc_call(n, method, params)
      else
        emit_method_call(n, method, default_children, named_fills)
      end
    end

    private def emit_manual_component_or_html(n : AST::Element, method : String) : Nil
      if n.children.any? { |c| c.is_a?(AST::SlotFill) }
        emit_manual_component_call(n, method)
      else
        emit_manual_component_check(method)
        @out << "  "
        emit_method_call(n, method, n.children, {} of String => Array(AST::Node))
        @out << "{% else %}\n"
        emit_html_element(n)
        @out << "{% end %}\n"
      end
    end

    private def emit_manual_component_call(n : AST::Element, method : String) : Nil
      emit_manual_component_check(method)
      @out << "  "
      emit_component_call(n)
      @out << "{% else %}\n"
      emit_macro_raise(format_error(n, "slot fills require a component method for <#{n.tag}>"))
      @out << "{% end %}\n"
    end

    private def emit_manual_component_check(method : String) : Nil
      @out << "{% if @type.methods.any? { |m| m.name == "
      method.inspect(@out)
      @out << " && m.args.size > 0 && m.args[0].name == \"io\" } || "
      @out << "@type.ancestors.any? { |a| a.has_method?(:"
      @out << method
      @out << ") } %}\n"
    end

    private def emit_macro_raise(message : String) : Nil
      @out << "  {% raise "
      message.inspect(@out)
      @out << " %}\n"
    end

    private def emit_inline_proc_call(n : AST::Element, method : String, params : Array(String)) : Nil
      proc_var = inline_proc_name(method)
      attrs = {} of String => AST::Attribute
      n.attributes.each do |a|
        raise_at(a, "duplicate attribute '#{a.name}' on inline component <#{n.tag}>") if attrs.has_key?(a.name)
        attrs[a.name] = a
      end
      attrs.each_key do |name|
        raise_at(attrs[name], "unknown param '#{name}' on inline component <#{n.tag}>") unless params.includes?(name)
      end

      @out << proc_var << ".call(io"
      params.each do |name|
        a = attrs[name]?
        raise_at(n, "missing required param '#{name}' on inline component <#{n.tag}>") unless a
        @out << ", "
        emit_component_arg_value(a)
      end
      @out << ")\n"
    end

    private def emit_method_call(n : AST::Element, method : String,
                                 default_children : Array(AST::Node),
                                 named_fills : Hash(String, Array(AST::Node))) : Nil
      @out << method << "(io"
      n.attributes.each { |a| emit_component_arg(a) }
      named_fills.each do |slot_name, content|
        @out << ", " << slot_name << ": ->(io : IO) {\n"
        with_scope do
          content.each { |c| emit_node(c) }
        end
        @out << "nil\n}"
      end
      unless default_children.empty?
        @out << ", __slot: ->(io : IO) {\n"
        with_scope do
          default_children.each { |c| emit_node(c) }
        end
        @out << "nil\n}"
      end
      @out << ")\n"
    end

    private def emit_attribute(a : AST::Attribute) : Nil
      case a
      when AST::StringAttr
        if a.value.empty?
          emit_static(" #{a.name}")
        else
          emit_static(%( #{a.name}="#{escape_static_attr(a.value)}"))
        end
      when AST::ExprAttr
        tmp = next_temp_name("attr_value")
        @out << tmp << " = ("
        @out << a.expression
        @out << ")\n"
        @out << "case " << tmp << "\n"
        @out << "when true\n"
        emit_static(" #{a.name}")
        @out << "when false, nil\n"
        @out << "else\n"
        emit_static(%( #{a.name}="))
        emit_escaped_expr(tmp)
        emit_static(%("))
        @out << "end\n"
      end
    end

    # Build the value passed to a component method as a Crystal expression.
    # No HTML escaping here — the receiving component's `{expr}` interpolations
    # do their own escaping at render time.
    private def emit_component_arg(a : AST::Attribute) : Nil
      @out << ", " << a.name << ": "
      emit_component_arg_value(a)
    end

    private def emit_component_arg_value(a : AST::Attribute) : Nil
      case a
      when AST::StringAttr
        a.value.inspect(@out)
      when AST::ExprAttr
        @out << '(' << a.expression << ')'
      end
    end

    private def emit_top_level_def(n : AST::Def) : Nil
      emit_source_marker(n)
      method = tag_to_method_name(n.tag)
      @component_methods << method
      named_slots = collect_named_slot_names(n.body)
      attr = has_style_block?(n.body) ? component_attr(n) : nil

      @out << "def " << method << "(io : IO"
      n.params.each do |p|
        @out << ", " << p.name
        @out << " : " << p.type unless p.type.empty?
        if d = p.default
          @out << " = " << d
        end
      end
      named_slots.each do |slot_name|
        @out << ", " << slot_name << " : Proc(IO, Nil) = ->(io : IO) {}"
      end
      # Default slot is also a Proc keyword arg (not `&block`) so the method
      # can self-recurse — Crystal inlines `&block` params, which makes
      # recursive component invocations error with "infinite inlining."
      @out << ", __slot : Proc(IO, Nil) = ->(io : IO) {}) : Nil\n"

      @in_top_level_def = true
      @current_component_methods << method
      previous_attr = @current_component_attr
      @current_component_attr = attr
      prev_raw = @in_raw
      @in_raw = false
      with_scope do
        n.body.each { |c| emit_node(c) }
      end
      @in_raw = prev_raw
      @current_component_attr = previous_attr
      @current_component_methods.pop
      @in_top_level_def = false

      @out << "end\n"
    end

    # Stable per-def identifier used for both <style> rewriting and element
    # stamping. Hashing the def's body structure means components with
    # identical bodies collide (intentional — they're the same component);
    # different bodies always differ.
    private def component_attr(n : AST::Def) : String
      key = String.build do |sb|
        sb << n.tag
        n.params.each { |p| sb << '|' << p.name << ':' << p.type }
        accumulate_signature(n.body, sb)
      end
      hash = Digest::CRC32.checksum(key.to_slice).to_s(16).rjust(8, '0')[0, 6]
      "data-c-#{tag_to_method_name(n.tag).gsub('_', '-')}-#{hash}"
    end

    private def accumulate_signature(nodes : Array(AST::Node), sb : IO) : Nil
      nodes.each do |n|
        case n
        when AST::Text          then sb << 'T' << n.content
        when AST::Interpolation then sb << 'I' << n.expression
        when AST::Element
          sb << 'E' << n.tag
          n.attributes.each { |a| sb << ' ' << a.name }
          sb << '{'
          accumulate_signature(n.children, sb)
          sb << '}'
        when AST::If
          sb << "?(" << n.condition << ")"
          accumulate_signature(n.then_body, sb)
          sb << '|'
          accumulate_signature(n.else_body, sb)
        when AST::For
          sb << "*(" << n.var << " in " << n.collection << ")"
          accumulate_signature(n.body, sb)
        when AST::Let
          sb << "=(" << n.name << ":=" << n.expression << ")"
          accumulate_signature(n.body, sb)
        when AST::Slot
          sb << "S:" << (n.name || "_")
        when AST::SlotFill
          sb << "F:" << n.name
          accumulate_signature(n.body, sb)
        when AST::Def
          sb << "D:" << n.tag
          accumulate_signature(n.body, sb)
        when AST::Raw
          sb << "R{"
          accumulate_signature(n.body, sb)
          sb << '}'
        when AST::Comment
          sb << "C:" << n.content
        when AST::Doctype
          sb << "!:" << n.content
        when AST::Require
          sb << "M:" << n.from
        when AST::Use
          sb << "U:" << n.from
        end
      end
    end

    private def emit_inline_def(n : AST::Def) : Nil
      if uses_any_slot?(n.body)
        raise_not_implemented_at(n,
          "<.def tag=\"#{n.tag}\"> contains <.slot/>. " \
          "Slot-bearing components must be defined at class/module scope — " \
          "move this <.def> into a separate .can file loaded outside any method body."
        )
      end

      if n.params.any?(&.default)
        raise_not_implemented_at(n,
          "<.def tag=\"#{n.tag}\"> has param defaults; Crystal Procs don't support defaults, " \
          "so defaults are top-level-only. Move this <.def> to class/module scope."
        )
      end

      emit_source_marker(n)
      method = tag_to_method_name(n.tag)
      proc_var = inline_proc_name(method)

      @out << proc_var << " = ->(io : IO"
      n.params.each do |p|
        @out << ", " << p.name << " : " << p.type
      end
      @out << ") {\n"

      prev_raw = @in_raw
      @in_raw = false
      with_scope do
        n.body.each { |c| emit_node(c) }
      end
      @in_raw = prev_raw

      @out << "nil\n}\n"

      register_inline_def(method, n.params.map(&.name))
    end

    private def emit_slot(n : AST::Slot) : Nil
      emit_source_marker(n)
      raise_at(n, "<.slot/> can only appear inside a top-level <.def> body") unless @in_top_level_def

      if name = n.name
        @out << name << ".call(io)\n"
      else
        @out << "__slot.call(io)\n"
      end
    end

    private def emit_require(n : AST::Require) : Nil
      emit_source_marker(n)
      @out << "require "
      n.from.inspect(@out)
      @out << '\n'
    end

    private def emit_use(n : AST::Use) : Nil
      emit_source_marker(n)
      path = resolve_use_path(n)
      return if @used_templates.includes?(path)

      @used_templates << path

      source = begin
        File.read(path)
      rescue ex
        raise_at(n, "cannot read <.use> file #{n.from.inspect}: #{ex.message}")
      end

      template = begin
        Parser.parse(source)
      rescue ex : ParseError
        message = ex.message.to_s.sub(/ \(line \d+, col \d+\)\z/, "")
        raise "#{path}:#{ex.line}:#{ex.column}: #{message}"
      end

      self.class.new(@out, :use, path, @used_templates, @component_methods).emit_template(template)
    end

    private def emit_top_level_head_uses(n : AST::Element) : Nil
      if n.tag == "head"
        emit_head_uses(n)
      elsif n.tag == "html"
        n.children.each do |c|
          emit_head_uses(c) if c.is_a?(AST::Element) && c.tag == "head"
        end
      end
    end

    private def emit_head_uses(n : AST::Element) : Nil
      n.children.reject! do |c|
        if c.is_a?(AST::Use)
          emit_use(c)
          true
        else
          false
        end
      end
    end

    private def emit_if(n : AST::If) : Nil
      emit_source_marker(n)
      @out << "if ("
      @out << n.condition
      @out << ")\n"
      with_scope { n.then_body.each { |c| emit_node(c) } }
      emit_else_branch(n.else_body)
      @out << "end\n"
    end

    # Emits the else-branch of an If, collapsing a single nested If in the
    # else_body into a Crystal `elsif` chain so generated code stays flat.
    private def emit_else_branch(else_body : Array(AST::Node)) : Nil
      return if else_body.empty?

      if else_body.size == 1 && (nested = else_body.first).is_a?(AST::If)
        @out << "elsif ("
        @out << nested.condition
        @out << ")\n"
        with_scope { nested.then_body.each { |c| emit_node(c) } }
        emit_else_branch(nested.else_body)
      else
        @out << "else\n"
        with_scope { else_body.each { |c| emit_node(c) } }
      end
    end

    private def emit_for(n : AST::For) : Nil
      emit_source_marker(n)
      @out << "("
      @out << n.collection
      @out << ").each do |"
      @out << n.var
      @out << "|\n"
      with_scope { n.body.each { |c| emit_node(c) } }
      @out << "end\n"
    end

    private def emit_let(n : AST::Let) : Nil
      emit_source_marker(n)
      @out << n.name
      @out << " = ("
      @out << n.expression
      @out << ")\n"
      with_scope { n.body.each { |c| emit_node(c) } }
    end

    private def emit_comment(n : AST::Comment) : Nil
      emit_source_marker(n)
      emit_static("<!--#{n.content}-->")
    end

    private def emit_doctype(n : AST::Doctype) : Nil
      emit_source_marker(n)
      emit_static("<!#{n.content}>")
    end

    private def emit_static(s : String) : Nil
      return if s.empty?
      @out << "io << "
      s.inspect(@out)
      @out << '\n'
    end

    private def emit_source_marker(n : AST::Node) : Nil
      return unless source = @source_name
      return if n.line <= 0
      @out << "# can: " << source << ':' << n.line << ':' << n.column << '\n'
    end

    private def raise_at(n : AST::Node, message : String) : NoReturn
      raise format_error(n, message)
    end

    private def raise_not_implemented_at(n : AST::Node, message : String) : NoReturn
      raise NotImplementedError.new(format_error(n, message))
    end

    private def format_error(n : AST::Node, message : String) : String
      return message unless source = @source_name
      return "#{source}: #{message}" if n.line <= 0
      "#{source}:#{n.line}:#{n.column}: #{message}"
    end

    private def emit_escaped_expr(expr : String) : Nil
      if @in_raw
        @out << "io << ("
        @out << expr
        @out << ").to_s\n"
      else
        @out << "::Can.write_escaped(io, ("
        @out << expr
        @out << "))\n"
      end
    end

    private def emit_raw(n : AST::Raw) : Nil
      emit_source_marker(n)
      prev = @in_raw
      @in_raw = true
      begin
        n.body.each { |c| emit_node(c) }
      ensure
        @in_raw = prev
      end
    end

    private def tag_to_method_name(tag : String) : String
      tag.gsub('-', '_').underscore
    end

    private def component_method?(method : String) : Bool
      @component_methods.includes?(method) || inline_def_params(method) != nil
    end

    private def self_shadowing_platform_tag?(n : AST::Element, method : String) : Bool
      html_tag?(n.tag) && @current_component_methods.last? == method
    end

    private def html_tag?(tag : String) : Bool
      HTML_ELEMENTS.includes?(tag.downcase)
    end

    private def inline_proc_name(method : String) : String
      "__can_#{method}"
    end

    private def next_temp_name(prefix : String) : String
      @tmp_counter += 1
      "__can_#{prefix}_#{@tmp_counter}"
    end

    private def push_scope : Nil
      @inline_def_scopes << Hash(String, Array(String)).new
    end

    private def pop_scope : Nil
      @inline_def_scopes.pop
    end

    private def with_scope(&)
      push_scope
      begin
        yield
      ensure
        pop_scope
      end
    end

    private def register_inline_def(name : String, params : Array(String)) : Nil
      @inline_def_scopes.last[name] = params
    end

    private def inline_def_params(name : String) : Array(String)?
      @inline_def_scopes.reverse_each do |scope|
        return scope[name] if scope.has_key?(name)
      end
      nil
    end

    private def escape_static_attr(value : String) : String
      value.gsub('"', "&quot;")
    end

    private def resolve_use_path(n : AST::Use) : String
      File.expand_path(n.from, template_base_dir)
    end

    private def template_base_dir : String
      if source = @source_name
        return File.dirname(source) unless source == "inline template"
      end

      Dir.current
    end

    private def visit_nodes(nodes : Array(AST::Node), descend_into_defs : Bool = false, &block : AST::Node ->) : Nil
      nodes.each do |n|
        visit_node(n, descend_into_defs, &block)
      end
    end

    private def visit_node(node : AST::Node, descend_into_defs : Bool = false, &block : AST::Node ->) : Nil
      yield node

      case node
      when AST::Element
        visit_nodes(node.children, descend_into_defs, &block)
      when AST::If
        visit_nodes(node.then_body, descend_into_defs, &block)
        visit_nodes(node.else_body, descend_into_defs, &block)
      when AST::For
        visit_nodes(node.body, descend_into_defs, &block)
      when AST::Let
        visit_nodes(node.body, descend_into_defs, &block)
      when AST::Raw
        visit_nodes(node.body, descend_into_defs, &block)
      when AST::SlotFill
        visit_nodes(node.body, descend_into_defs, &block)
      when AST::Def
        visit_nodes(node.body, descend_into_defs, &block) if descend_into_defs
      end
    end

    # Recursively walks a node list and returns the unique set of named-slot
    # names referenced via <.slot name="…"/>. Used to extend a top-level def's
    # signature with one Proc keyword arg per slot.
    private def collect_named_slot_names(nodes : Array(AST::Node)) : Array(String)
      seen = [] of String
      visit_nodes(nodes) do |n|
        if n.is_a?(AST::Slot) && (name = n.name)
          seen << name unless seen.includes?(name)
        end
      end
      seen
    end

    private def has_style_block?(nodes : Array(AST::Node)) : Bool
      found = false
      visit_nodes(nodes) do |n|
        if n.is_a?(AST::Element) && n.tag == "style"
          found = true
        end
      end
      found
    end

    private def uses_any_slot?(nodes : Array(AST::Node)) : Bool
      found = false
      visit_nodes(nodes) do |n|
        if n.is_a?(AST::Slot)
          found = true
        end
      end
      found
    end
  end
end
