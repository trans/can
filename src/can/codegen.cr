require "digest/crc32"
require "./ast"
require "./parser"
require "./css_scope"

module Can
  # Codegen: emits Crystal source that writes HTML to a local `io`.
  #
  # Static text from the source template is emitted verbatim — author
  # responsibility to write valid HTML (e.g. `&lt;` for literal `<`).
  # Interpolated `{expr}` values are HTML-escaped at runtime via stdlib
  # `::HTML.escape`.
  #
  # An element whose tag is in `HTML_ELEMENTS` renders as literal HTML.
  # Any other tag is treated as a component invocation: `<Card title="…">…</Card>`
  # becomes `card(io, title: "…") do |io| … end`. The tag is mapped to a
  # method name via `tag.gsub('-', '_').underscore`.
  #
  # `<.def>` at the top level becomes a method (with optional named-slot
  # `Proc` params and a default-slot `&block`). `<.def>` inside a body
  # becomes a local `Proc` that closes over surrounding bindings; v1
  # restriction: inline defs can't host `<.slot/>` and can't be invoked
  # with slot content.
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
    }

    @out : IO
    @scope : Symbol
    @inline_def_scopes : Array(Set(String))
    @in_top_level_def : Bool = false
    @in_raw : Bool = false
    @current_component_attr : String? = nil

    def self.compile(template : AST::Template, scope : Symbol = :class) : String
      String.build { |sb| new(sb, scope).emit_template(template) }
    end

    def self.compile(source : String, scope : Symbol = :class) : String
      compile(Parser.parse(source), scope)
    end

    def initialize(@out : IO, @scope : Symbol = :class)
      @inline_def_scopes = [Set(String).new]
    end

    def emit_template(t : AST::Template) : Nil
      t.children.each { |n| emit_top_level(n) }
    end

    private def emit_top_level(n : AST::Node) : Nil
      case n
      when AST::Def
        # At class scope, lower to a real method. At method scope, Crystal
        # forbids nested `def`, so we lower to a local Proc — same shape as
        # an inline def. Slot-bearing components are class-scope-only and
        # error clearly when met in method scope.
        @scope == :method ? emit_inline_def(n) : emit_top_level_def(n)
      when AST::Import then emit_import(n)
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
        raise "<:#{n.name}> slot-fill is only valid as a child of a component invocation"
      when AST::Import
        raise "<.import/> is only allowed at the top level of a template"
      when AST::ElseMark
        raise "<.else/> can only appear inside a <.if> body"
      when AST::ElseIfMark
        raise "<.elseif/> can only appear inside a <.if> body"
      else
        raise "codegen: unhandled node #{n.class.name}"
      end
    end

    private def emit_text(n : AST::Text) : Nil
      emit_static(n.content)
    end

    private def emit_interp(n : AST::Interpolation) : Nil
      emit_escaped_expr(n.expression)
    end

    private def emit_element(n : AST::Element) : Nil
      if html_tag?(n.tag)
        emit_html_element(n)
      else
        emit_component_call(n)
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
          named_fills[c.name] = c.body
        else
          default_children << c
        end
      end

      if inline_def_in_scope?(method)
        unless default_children.empty? && named_fills.empty?
          raise NotImplementedError.new(
            "inline component <#{n.tag}> can't accept slot content (only top-level <.def> components support slots)"
          )
        end
        emit_inline_proc_call(n, method)
      else
        emit_method_call(n, method, default_children, named_fills)
      end
    end

    private def emit_inline_proc_call(n : AST::Element, method : String) : Nil
      proc_var = inline_proc_name(method)
      @out << proc_var << ".call(io"
      n.attributes.each do |a|
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
          emit_static(%( #{a.name}="#{a.value}"))
        end
      when AST::ExprAttr
        emit_static(%( #{a.name}="))
        emit_escaped_expr(a.expression)
        emit_static(%("))
      when AST::InterpAttr
        emit_static(%( #{a.name}="))
        a.parts.each do |p|
          case p
          when AST::Text          then emit_static(p.content)
          when AST::Interpolation then emit_escaped_expr(p.expression)
          end
        end
        emit_static(%("))
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
      when AST::InterpAttr
        @out << "String.build { |__sb| "
        a.parts.each do |p|
          case p
          when AST::Text
            @out << "__sb << "
            p.content.inspect(@out)
            @out << "; "
          when AST::Interpolation
            @out << "__sb << ("
            @out << p.expression
            @out << ").to_s; "
          end
        end
        @out << '}'
      end
    end

    private def emit_top_level_def(n : AST::Def) : Nil
      method = tag_to_method_name(n.tag)
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
      previous_attr = @current_component_attr
      @current_component_attr = attr
      prev_raw = @in_raw
      @in_raw = false
      with_scope do
        n.body.each { |c| emit_node(c) }
      end
      @in_raw = prev_raw
      @current_component_attr = previous_attr
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
        when AST::Import
          sb << "M:" << n.from
        end
      end
    end

    private def emit_inline_def(n : AST::Def) : Nil
      if uses_any_slot?(n.body)
        raise NotImplementedError.new(
          "<.def tag=\"#{n.tag}\"> contains <.slot/>. " \
          "Slot-bearing components must be defined at class/module scope — " \
          "move this <.def> into a separate .can file loaded outside any method body."
        )
      end

      if n.params.any?(&.default)
        raise NotImplementedError.new(
          "<.def tag=\"#{n.tag}\"> has param defaults; Crystal Procs don't support defaults, " \
          "so defaults are top-level-only. Move this <.def> to class/module scope."
        )
      end

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

      register_inline_def(method)
    end

    private def emit_slot(n : AST::Slot) : Nil
      raise "<.slot/> can only appear inside a top-level <.def> body" unless @in_top_level_def

      if name = n.name
        @out << name << ".call(io)\n"
      else
        @out << "__slot.call(io)\n"
      end
    end

    private def emit_import(n : AST::Import) : Nil
      @out << "require "
      n.from.inspect(@out)
      @out << '\n'
    end

    private def emit_if(n : AST::If) : Nil
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
      @out << "("
      @out << n.collection
      @out << ").each do |"
      @out << n.var
      @out << "|\n"
      with_scope { n.body.each { |c| emit_node(c) } }
      @out << "end\n"
    end

    private def emit_let(n : AST::Let) : Nil
      @out << n.name
      @out << " = ("
      @out << n.expression
      @out << ")\n"
      with_scope { n.body.each { |c| emit_node(c) } }
    end

    private def emit_comment(n : AST::Comment) : Nil
      emit_static("<!--#{n.content}-->")
    end

    private def emit_doctype(n : AST::Doctype) : Nil
      emit_static("<!#{n.content}>")
    end

    private def emit_static(s : String) : Nil
      return if s.empty?
      @out << "io << "
      s.inspect(@out)
      @out << '\n'
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

    private def html_tag?(tag : String) : Bool
      HTML_ELEMENTS.includes?(tag.downcase)
    end

    private def inline_proc_name(method : String) : String
      "__can_#{method}"
    end

    private def push_scope : Nil
      @inline_def_scopes << Set(String).new
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

    private def register_inline_def(name : String) : Nil
      @inline_def_scopes.last << name
    end

    private def inline_def_in_scope?(name : String) : Bool
      @inline_def_scopes.any?(&.includes?(name))
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
