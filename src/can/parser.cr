require "./ast"

module Can
  class ParseError < Exception
    getter line : Int32
    getter column : Int32

    def initialize(msg : String, @line : Int32 = 0, @column : Int32 = 0)
      super("#{msg} (line #{@line}, col #{@column})")
    end
  end

  # Strict XML-ish parser for the can template language. Tags must be
  # explicitly closed (or self-closed); attribute values must be quoted
  # (`"..."` / `'...'`) or expression-form (`={...}`).
  #
  # `<style>` and `<script>` switch to raw-text mode — content is captured
  # verbatim until the matching close tag, no nested-tag or interpolation
  # parsing. (Trade-off: no `{expr}` inside CSS for now; revisit later.)
  class Parser
    RAW_TEXT_TAGS = {"style", "script"}

    @source : String
    @bytes : Bytes
    @pos : Int32
    @line : Int32
    @col : Int32

    def self.parse(source : String) : AST::Template
      new(source).parse
    end

    def initialize(@source : String)
      @bytes = @source.to_slice
      @pos = 0
      @line = 1
      @col = 1
    end

    def parse : AST::Template
      l, c = @line, @col
      children = parse_nodes(until_close: nil)
      AST::Template.new(children, l, c)
    end

    # =====================================================================
    # Top-level node-stream parsing
    # =====================================================================

    private def parse_nodes(until_close : String?) : Array(AST::Node)
      result = [] of AST::Node

      until eof?
        if starts_with?("</")
          if until_close && matches_close_tag?(until_close)
            consume_close_tag(until_close)
            return result
          elsif until_close
            raise_here "expected </#{until_close}>, got </#{peek_close_tag_name}>"
          else
            raise_here "unexpected closing tag </#{peek_close_tag_name}>"
          end
        elsif starts_with?("<!--")
          result << parse_comment
        elsif starts_with?("<!")
          result << parse_doctype
        elsif starts_with?("<")
          result << parse_element_or_special
        else
          parse_text_run(result)
        end
      end

      if until_close
        raise_here "expected </#{until_close}> before EOF"
      end

      result
    end

    private def parse_text_run(result : Array(AST::Node)) : Nil
      text_start = @pos
      text_line = @line
      text_col = @col

      until eof?
        b = byte_at
        case b
        when '<'.ord.to_u8
          break
        when '{'.ord.to_u8
          if @pos > text_start
            result << AST::Text.new(byte_slice(text_start, @pos - text_start), text_line, text_col)
          end
          il, ic = @line, @col
          expr = read_brace_expression
          result << AST::Interpolation.new(expr, il, ic)
          text_start = @pos
          text_line = @line
          text_col = @col
        else
          advance
        end
      end

      if @pos > text_start
        result << AST::Text.new(byte_slice(text_start, @pos - text_start), text_line, text_col)
      end
    end

    # =====================================================================
    # Comments / doctype
    # =====================================================================

    private def parse_comment : AST::Comment
      l, c = @line, @col
      expect_str("<!--")
      start = @pos
      until eof? || starts_with?("-->")
        advance
      end
      raise_at "unterminated <!-- comment", l, c if eof?
      content = byte_slice(start, @pos - start)
      expect_str("-->")
      AST::Comment.new(content, l, c)
    end

    private def parse_doctype : AST::Doctype
      l, c = @line, @col
      expect_str("<!")
      start = @pos
      until eof? || byte_at == '>'.ord.to_u8
        advance
      end
      raise_at "unterminated <! ... > directive", l, c if eof?
      content = byte_slice(start, @pos - start)
      advance # consume '>'
      AST::Doctype.new(content, l, c)
    end

    # =====================================================================
    # Element / special-form parsing
    # =====================================================================

    private def parse_element_or_special : AST::Node
      l, c = @line, @col
      expect_byte('<'.ord.to_u8)
      tag = read_tag_name
      attrs = parse_attributes

      self_closing = false
      skip_whitespace
      if starts_with?("/>")
        advance
        advance
        self_closing = true
      else
        expect_byte('>'.ord.to_u8)
      end

      body = if self_closing
               [] of AST::Node
             elsif RAW_TEXT_TAGS.includes?(tag)
               parse_raw_text(tag)
             else
               parse_nodes(until_close: tag)
             end

      if tag.starts_with?('.')
        build_special_form(tag[1..], attrs, body, l, c)
      elsif tag.starts_with?(':')
        build_slot_fill(tag[1..], attrs, body, l, c)
      else
        build_element(tag, attrs, body, self_closing, l, c)
      end
    end

    private def build_slot_fill(name : String, attrs : Array(AST::Attribute), body : Array(AST::Node), l : Int32, c : Int32) : AST::Node
      raise_at "slot fill <:#{name}> doesn't take attributes (got '#{attrs.first.name}')", l, c unless attrs.empty?
      AST::SlotFill.new(name, body, l, c)
    end

    private def parse_raw_text(tag : String) : Array(AST::Node)
      start = @pos
      start_line, start_col = @line, @col
      close = "</#{tag}>"
      until eof? || starts_with?(close)
        advance
      end
      raise_at "unterminated <#{tag}>", start_line, start_col if eof?
      text = byte_slice(start, @pos - start)
      consume_close_tag(tag)
      text.empty? ? [] of AST::Node : [AST::Text.new(text, start_line, start_col).as(AST::Node)]
    end

    private def matches_close_tag?(expected : String) : Bool
      return false unless starts_with?("</")
      saved = {@pos, @line, @col}
      begin
        advance # '<'
        advance # '/'
        return false unless tag_name_start_byte?(byte_at) || byte_at == '.'.ord.to_u8 || byte_at == ':'.ord.to_u8
        name = read_tag_name
        name == expected
      ensure
        @pos, @line, @col = saved
      end
    end

    private def peek_close_tag_name : String
      saved = {@pos, @line, @col}
      begin
        advance
        advance
        if tag_name_start_byte?(byte_at) || byte_at == '.'.ord.to_u8 || byte_at == ':'.ord.to_u8
          read_tag_name
        else
          "?"
        end
      ensure
        @pos, @line, @col = saved
      end
    end

    private def consume_close_tag(expected : String) : Nil
      expect_str("</")
      name = read_tag_name
      raise_here "expected </#{expected}> got </#{name}>" unless name == expected
      skip_whitespace
      expect_byte('>'.ord.to_u8)
    end

    # =====================================================================
    # Attributes
    # =====================================================================

    private def parse_attributes : Array(AST::Attribute)
      attrs = [] of AST::Attribute
      loop do
        skip_whitespace
        break if eof?
        b = byte_at
        break if b == '>'.ord.to_u8
        break if b == '/'.ord.to_u8 && peek_byte(1) == '>'.ord.to_u8
        attrs << parse_attribute
      end
      attrs
    end

    private def parse_attribute : AST::Attribute
      l, c = @line, @col
      name = read_attribute_name

      if eof? || byte_at != '='.ord.to_u8
        return AST::StringAttr.new(name, "", l, c)
      end

      advance # consume '='

      case byte_at
      when '{'.ord.to_u8
        expr = read_brace_expression
        AST::ExprAttr.new(name, expr, l, c)
      when '"'.ord.to_u8, '\''.ord.to_u8
        parse_quoted_value(name, l, c)
      else
        raise_here "attribute value for '#{name}' must be quoted or {expr}"
      end
    end

    private def parse_quoted_value(name : String, l : Int32, c : Int32) : AST::Attribute
      quote_byte = byte_at
      advance # opening quote

      parts = [] of AST::Node
      text_start = @pos
      text_line, text_col = @line, @col

      until eof? || byte_at == quote_byte
        if byte_at == '{'.ord.to_u8
          if @pos > text_start
            parts << AST::Text.new(byte_slice(text_start, @pos - text_start), text_line, text_col)
          end
          il, ic = @line, @col
          expr = read_brace_expression
          parts << AST::Interpolation.new(expr, il, ic)
          text_start = @pos
          text_line, text_col = @line, @col
        else
          advance
        end
      end

      raise_at "unterminated attribute value for '#{name}'", l, c if eof?

      if @pos > text_start
        parts << AST::Text.new(byte_slice(text_start, @pos - text_start), text_line, text_col)
      end

      advance # closing quote

      if parts.empty?
        AST::StringAttr.new(name, "", l, c)
      elsif parts.size == 1 && (only = parts[0]).is_a?(AST::Text)
        AST::StringAttr.new(name, only.content, l, c)
      else
        AST::InterpAttr.new(name, parts, l, c)
      end
    end

    # =====================================================================
    # Special-form builders
    # =====================================================================

    private def build_special_form(name : String, attrs : Array(AST::Attribute), body : Array(AST::Node), l : Int32, c : Int32) : AST::Node
      case name
      when "def"     then build_def(attrs, body, l, c)
      when "if"      then build_if(attrs, body, l, c)
      when "else"    then build_else_mark(attrs, body, l, c)
      when "elseif"  then build_elseif_mark(attrs, body, l, c)
      when "for"     then build_for(attrs, body, l, c)
      when "let"     then build_let(attrs, body, l, c)
      when "slot"    then build_slot(attrs, l, c)
      when "import"  then build_import(attrs, l, c)
      when "raw"     then build_raw(attrs, body, l, c)
      else                raise_at "unknown special form <.#{name}>", l, c
      end
    end

    private def build_raw(attrs, body, l, c) : AST::Raw
      raise_at "<.raw> takes no attributes", l, c unless attrs.empty?
      AST::Raw.new(body, l, c)
    end

    private def build_def(attrs, body, l, c) : AST::Def
      tag_attr = attrs.find { |a| a.name == "tag" }
      raise_at "<.def> requires a 'tag' attribute", l, c unless tag_attr
      raise_at "<.def> 'tag' must be a literal string", l, c unless tag_attr.is_a?(AST::StringAttr)
      tag = tag_attr.value

      params = [] of AST::Param
      attrs.each do |a|
        next if a.name == "tag"
        if a.name.starts_with?("param:")
          pn = a.name[6..]
          unless a.is_a?(AST::StringAttr)
            raise_at "param:#{pn} must be a literal type expression in quotes", a.line, a.column
          end
          params << AST::Param.new(pn, a.value, nil, a.line, a.column)
        else
          raise_at "unknown attribute on <.def>: #{a.name}", a.line, a.column
        end
      end

      AST::Def.new(tag, params, body, l, c)
    end

    private def build_if(attrs, body, l, c) : AST::If
      cond = required_expr(attrs, "cond", "<.if>", l, c)
      then_body, else_body = split_if_body(body)
      AST::If.new(cond, then_body, else_body, l, c)
    end

    private def build_else_mark(attrs, body, l, c) : AST::ElseMark
      raise_at "<.else/> takes no attributes", l, c unless attrs.empty?
      raise_at "<.else/> must be self-closing", l, c unless body.empty?
      AST::ElseMark.new(l, c)
    end

    private def build_elseif_mark(attrs, body, l, c) : AST::ElseIfMark
      cond = required_expr(attrs, "cond", "<.elseif>", l, c)
      raise_at "<.elseif/> must be self-closing", l, c unless body.empty?
      AST::ElseIfMark.new(cond, l, c)
    end

    # Splits an <.if> body at <.else/> and <.elseif/> sentinels into the
    # then-branch and a possibly-nested else-branch. Multiple <.else/>s or
    # branches after the first <.else/> raise.
    private def split_if_body(body : Array(AST::Node)) : {Array(AST::Node), Array(AST::Node)}
      marker_idx = body.index { |n| n.is_a?(AST::ElseMark) || n.is_a?(AST::ElseIfMark) }
      return {body, [] of AST::Node} unless marker_idx

      then_body = body[0...marker_idx]
      marker = body[marker_idx]
      rest = body[(marker_idx + 1)..]

      case marker
      when AST::ElseMark
        if stray = rest.find { |n| n.is_a?(AST::ElseMark) || n.is_a?(AST::ElseIfMark) }
          raise_at "<.else/> or <.elseif/> appears after a previous <.else/>", stray.line, stray.column
        end
        {then_body, rest}
      when AST::ElseIfMark
        nested_then, nested_else = split_if_body(rest)
        nested_if = AST::If.new(marker.condition, nested_then, nested_else, marker.line, marker.column)
        {then_body, [nested_if] of AST::Node}
      else
        raise "unreachable"
      end
    end

    private def build_for(attrs, body, l, c) : AST::For
      each_expr = required_expr(attrs, "each", "<.for>", l, c)
      var, coll = parse_for_clause(each_expr, l, c)
      AST::For.new(var, coll, body, l, c)
    end

    private def build_let(attrs, body, l, c) : AST::Let
      name_attr = attrs.find { |a| a.name == "name" }
      raise_at "<.let> requires 'name'", l, c unless name_attr.is_a?(AST::StringAttr)
      value_expr = required_expr(attrs, "value", "<.let>", l, c)
      AST::Let.new(name_attr.value, value_expr, body, l, c)
    end

    private def build_slot(attrs, l, c) : AST::Slot
      name_attr = attrs.find { |a| a.name == "name" }
      name = name_attr.is_a?(AST::StringAttr) ? name_attr.value : nil
      AST::Slot.new(name, l, c)
    end

    private def build_import(attrs, l, c) : AST::Import
      from_attr = attrs.find { |a| a.name == "from" }
      raise_at "<.import> requires 'from'", l, c unless from_attr.is_a?(AST::StringAttr)
      AST::Import.new(from_attr.value, l, c)
    end

    private def required_expr(attrs : Array(AST::Attribute), aname : String, ctx : String, l : Int32, c : Int32) : String
      attr = attrs.find { |a| a.name == aname }
      raise_at "#{ctx} requires '#{aname}'", l, c unless attr
      expr_of(attr, ctx)
    end

    private def expr_of(attr : AST::Attribute, ctx : String) : String
      case attr
      when AST::ExprAttr   then attr.expression
      when AST::StringAttr then attr.value
      else                      raise_at "#{ctx} '#{attr.name}' must be a string or {expr}", attr.line, attr.column
      end
    end

    private def parse_for_clause(expr : String, l : Int32, c : Int32) : {String, String}
      m = expr.match(/\A\s*([a-zA-Z_][a-zA-Z0-9_]*)\s+in\s+(.+)\z/m)
      raise_at "expected 'var in collection' in for-clause, got #{expr.inspect}", l, c unless m
      {m[1], m[2].strip}
    end

    # =====================================================================
    # Element builder (with :if / :for desugaring)
    # =====================================================================

    private def build_element(tag : String, attrs : Array(AST::Attribute), body : Array(AST::Node), self_closing : Bool, l : Int32, c : Int32) : AST::Node
      if_attr = attrs.find { |a| a.name == ":if" }
      for_attr = attrs.find { |a| a.name == ":for" }
      remaining = attrs.reject { |a| a.name == ":if" || a.name == ":for" }

      el = AST::Element.new(tag, remaining, body, self_closing, l, c)
      result : AST::Node = el

      if for_attr
        var, coll = parse_for_clause(expr_of(for_attr, ":for"), for_attr.line, for_attr.column)
        result = AST::For.new(var, coll, [result] of AST::Node, l, c)
      end

      if if_attr
        result = AST::If.new(expr_of(if_attr, ":if"), [result] of AST::Node, [] of AST::Node, l, c)
      end

      result
    end

    # =====================================================================
    # Brace-expression reader (Crystal source between `{` and matching `}`)
    # =====================================================================

    private def read_brace_expression : String
      l, c = @line, @col
      expect_byte('{'.ord.to_u8)
      start = @pos
      depth = 1

      until eof? || depth == 0
        b = byte_at
        case b
        when '{'.ord.to_u8
          depth += 1
          advance
        when '}'.ord.to_u8
          depth -= 1
          if depth == 0
            result = byte_slice(start, @pos - start)
            advance
            return result.strip
          end
          advance
        when '"'.ord.to_u8
          skip_crystal_string('"')
        when '\''.ord.to_u8
          skip_crystal_char_literal
        else
          advance
        end
      end

      raise_at "unterminated { ... } expression", l, c
    end

    private def skip_crystal_string(quote : Char) : Nil
      q = quote.ord.to_u8
      advance # opening quote
      until eof?
        b = byte_at
        if b == '\\'.ord.to_u8
          advance(2)
        elsif b == q
          advance
          return
        else
          advance
        end
      end
      raise_here "unterminated string literal"
    end

    private def skip_crystal_char_literal : Nil
      advance # opening '
      while !eof? && byte_at != '\''.ord.to_u8
        advance(byte_at == '\\'.ord.to_u8 ? 2 : 1)
      end
      raise_here "unterminated char literal" if eof?
      advance # closing '
    end

    # =====================================================================
    # Lexical helpers
    # =====================================================================

    private def read_tag_name : String
      start = @pos
      if byte_at == '.'.ord.to_u8 || byte_at == ':'.ord.to_u8
        advance
      end
      raise_here "expected tag name" unless tag_name_start_byte?(byte_at)
      while !eof? && tag_name_byte?(byte_at)
        advance
      end
      byte_slice(start, @pos - start)
    end

    private def read_attribute_name : String
      start = @pos
      raise_here "expected attribute name" unless attr_name_start_byte?(byte_at)
      while !eof? && attr_name_byte?(byte_at)
        advance
      end
      byte_slice(start, @pos - start)
    end

    private def skip_whitespace : Nil
      while !eof? && whitespace?(byte_at)
        advance
      end
    end

    private def whitespace?(b) : Bool
      b == ' '.ord.to_u8 || b == '\t'.ord.to_u8 || b == '\n'.ord.to_u8 || b == '\r'.ord.to_u8
    end

    private def tag_name_start_byte?(b) : Bool
      letter?(b)
    end

    private def tag_name_byte?(b) : Bool
      letter?(b) || digit?(b) || b == '-'.ord.to_u8 || b == '_'.ord.to_u8
    end

    private def attr_name_start_byte?(b) : Bool
      letter?(b) || b == ':'.ord.to_u8 || b == '_'.ord.to_u8
    end

    private def attr_name_byte?(b) : Bool
      letter?(b) || digit?(b) ||
        b == ':'.ord.to_u8 || b == '-'.ord.to_u8 ||
        b == '_'.ord.to_u8 || b == '.'.ord.to_u8
    end

    private def letter?(b) : Bool
      (b >= 'a'.ord.to_u8 && b <= 'z'.ord.to_u8) ||
        (b >= 'A'.ord.to_u8 && b <= 'Z'.ord.to_u8)
    end

    private def digit?(b) : Bool
      b >= '0'.ord.to_u8 && b <= '9'.ord.to_u8
    end

    # =====================================================================
    # Position / byte helpers
    # =====================================================================

    private def eof? : Bool
      @pos >= @bytes.size
    end

    private def byte_at : UInt8
      eof? ? 0_u8 : @bytes[@pos]
    end

    private def peek_byte(offset : Int32) : UInt8
      p = @pos + offset
      p >= @bytes.size ? 0_u8 : @bytes[p]
    end

    private def byte_slice(start : Int32, len : Int32) : String
      @source.byte_slice(start, len)
    end

    private def starts_with?(s : String) : Bool
      sb = s.to_slice
      return false if @pos + sb.size > @bytes.size
      sb.size.times do |i|
        return false if @bytes[@pos + i] != sb[i]
      end
      true
    end

    private def advance(n : Int32 = 1) : Nil
      n.times do
        break if eof?
        if @bytes[@pos] == '\n'.ord.to_u8
          @line += 1
          @col = 1
        else
          @col += 1
        end
        @pos += 1
      end
    end

    private def expect_byte(b : UInt8) : Nil
      raise_here "expected '#{b.unsafe_chr}' but got '#{byte_at.unsafe_chr}'" if byte_at != b
      advance
    end

    private def expect_str(s : String) : Nil
      raise_here "expected '#{s}'" unless starts_with?(s)
      advance(s.bytesize)
    end

    private def raise_here(msg : String) : NoReturn
      raise ParseError.new(msg, @line, @col)
    end

    private def raise_at(msg : String, line : Int32, col : Int32) : NoReturn
      raise ParseError.new(msg, line, col)
    end
  end
end
