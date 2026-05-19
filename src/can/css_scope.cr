module Can
  # Rewrites CSS to scope every selector to a given attribute.
  #
  #     .card { color: red }
  #     .card:hover, h2 { color: blue }
  #     @media (max-width: 600px) { h2 { font-size: 1rem } }
  #
  # becomes (with attr `data-c-foo`):
  #
  #     .card[data-c-foo] { color: red }
  #     .card[data-c-foo]:hover, h2[data-c-foo] { color: blue }
  #     @media (max-width: 600px) { h2[data-c-foo] { font-size: 1rem } }
  #
  # Pass-through (not scoped): `@keyframes`, `@font-face`, `@import`, `@charset`,
  # `@page`, and any unknown at-rule body. Recurses into `@media`, `@supports`,
  # `@container`, `@layer` blocks.
  #
  # Tokenizer is brace/string/comment-aware but doesn't fully implement the CSS
  # syntax module; uncommon edge cases (escapes inside selectors, attribute
  # selectors with nested brackets) may not roundtrip identically.
  #
  # TODO: revisit per-element stamping once CSS `@scope { ... } to (...)` is
  # broadly supported (Chromium ships it; Firefox/Safari behind as of 2026).
  # `@scope` provides a real scope barrier with a stop selector, which would
  # let us stamp only the component's root element and wall off nested
  # components via `to (.child-component-root)`. Same isolation semantics,
  # much lighter markup. Conservative target: revisit when all evergreen
  # browsers ship it and a reasonable LTS window has passed.
  class CssScoper
    SCOPED_AT_RULES = {"media", "supports", "container", "layer"}

    @source : String
    @bytes : Bytes
    @pos : Int32
    @out : IO
    @suffix : String

    def self.scope(css : String, attr : String) : String
      String.build { |sb| new(css, "[#{attr}]", sb).process_top_level }
    end

    private def initialize(@source : String, @suffix : String, @out : IO)
      @bytes = @source.to_slice
      @pos = 0
    end

    protected def process_top_level : Nil
      until eof?
        copy_trivia
        return if eof?
        case peek
        when '@' then process_at_rule
        when '}'
          @out << '}'
          @pos += 1
        else
          process_rule
        end
      end
    end

    private def process_at_rule : Nil
      start = @pos
      @pos += 1 # consume '@'
      name_start = @pos
      while !eof? && (letter?(peek) || peek == '-')
        @pos += 1
      end
      name = byte_slice(name_start, @pos - name_start)

      # Read prelude (text up to `{` or `;`), respecting comments and strings.
      while !eof? && peek != '{' && peek != ';'
        if peek == '/' && peek_at(1) == '*'
          skip_comment_silently
        elsif peek == '"' || peek == '\''
          skip_string_silently(peek)
        else
          @pos += 1
        end
      end

      @out << byte_slice(start, @pos - start)
      return if eof?

      if peek == ';'
        @out << ';'
        @pos += 1
        return
      end

      @out << '{'
      @pos += 1

      if SCOPED_AT_RULES.includes?(name)
        process_block_recursive
      else
        copy_block_passthrough
      end
    end

    # Processes inside `{ ... }` as scoped CSS, stopping at the matching `}`.
    private def process_block_recursive : Nil
      until eof?
        copy_trivia
        return if eof?
        case peek
        when '}'
          @out << '}'
          @pos += 1
          return
        when '@'
          process_at_rule
        else
          process_rule
        end
      end
    end

    # Copies through bytes until the matching `}`, respecting nested `{...}`,
    # comments, and strings.
    private def copy_block_passthrough : Nil
      depth = 0
      until eof?
        case peek
        when '{'
          depth += 1
          @out << '{'
          @pos += 1
        when '}'
          if depth == 0
            @out << '}'
            @pos += 1
            return
          end
          depth -= 1
          @out << '}'
          @pos += 1
        when '/'
          if peek_at(1) == '*'
            copy_comment
          else
            @out << '/'
            @pos += 1
          end
        when '"', '\''
          copy_string(peek)
        else
          @out << peek
          @pos += 1
        end
      end
    end

    private def process_rule : Nil
      sel_start = @pos
      while !eof? && peek != '{'
        if peek == '/' && peek_at(1) == '*'
          skip_comment_silently
        elsif peek == '"' || peek == '\''
          skip_string_silently(peek)
        else
          @pos += 1
        end
      end

      raw = byte_slice(sel_start, @pos - sel_start)

      if eof?
        @out << raw
        return
      end

      @out << rewrite_selector_list(raw)
      @out << '{'
      @pos += 1
      copy_block_passthrough
    end

    private def rewrite_selector_list(s : String) : String
      String.build do |sb|
        first = true
        split_top_level_commas(s).each do |part|
          sb << ',' unless first
          first = false
          sb << rewrite_selector(part)
        end
      end
    end

    private def split_top_level_commas(s : String) : Array(String)
      groups = [] of String
      paren_depth = 0
      bracket_depth = 0
      group_start = 0
      i = 0
      chars = s.chars
      while i < chars.size
        c = chars[i]
        case c
        when '('   then paren_depth += 1
        when ')'   then paren_depth -= 1
        when '['   then bracket_depth += 1
        when ']'   then bracket_depth -= 1
        when ','
          if paren_depth == 0 && bracket_depth == 0
            groups << chars[group_start...i].join
            group_start = i + 1
          end
        end
        i += 1
      end
      groups << chars[group_start..].join if group_start <= chars.size
      groups
    end

    private def rewrite_selector(sel : String) : String
      String.build do |sb|
        paren_depth = 0
        bracket_depth = 0
        compound_start = -1
        i = 0
        chars = sel.chars

        flush_compound = ->(end_index : Int32) {
          return if compound_start < 0 || end_index <= compound_start
          compound = chars[compound_start...end_index].join
          if compound.strip.empty?
            sb << compound
          else
            sb << augment_compound(compound)
          end
          compound_start = -1
        }

        while i < chars.size
          c = chars[i]

          if compound_start < 0 && !whitespace?(c) && c != '>' && c != '+' && c != '~'
            compound_start = i
          end

          case c
          when '('   then paren_depth += 1; i += 1
          when ')'   then paren_depth -= 1; i += 1
          when '['   then bracket_depth += 1 if paren_depth == 0; i += 1
          when ']'   then bracket_depth -= 1 if paren_depth == 0; i += 1
          else
            if paren_depth == 0 && bracket_depth == 0 && (whitespace?(c) || c == '>' || c == '+' || c == '~')
              flush_compound.call(i)
              # Copy combinator run (whitespace and at most one of >, +, ~)
              while i < chars.size && whitespace?(chars[i])
                sb << chars[i]
                i += 1
              end
              if i < chars.size && (chars[i] == '>' || chars[i] == '+' || chars[i] == '~')
                sb << chars[i]
                i += 1
                while i < chars.size && whitespace?(chars[i])
                  sb << chars[i]
                  i += 1
                end
              end
            else
              i += 1
            end
          end
        end

        flush_compound.call(chars.size)
      end
    end

    # Augments a single compound selector by inserting `@suffix` before the
    # first `:` (pseudo-class/element) at depth 0; otherwise appends.
    #
    # Special case: `:slotted(X)` strips the wrapper and emits X verbatim,
    # leaving the surrounding host selector to do the scoping. This lets
    # CSS reach into slot content (which carries the caller's data-attr,
    # not the component's) via a structural relationship.
    private def augment_compound(compound : String) : String
      return compound if compound.empty?

      if compound.starts_with?(":slotted(")
        if close = matching_close_paren(compound, ":slotted".size)
          inner = compound[":slotted(".size...close]
          rest = compound[(close + 1)..]
          return "#{inner}#{rest}"
        end
      end

      paren_depth = 0
      compound.each_char_with_index do |c, i|
        case c
        when '('
          paren_depth += 1
        when ')'
          paren_depth -= 1
        when ':'
          return "#{compound[0...i]}#{@suffix}#{compound[i..]}" if paren_depth == 0
        end
      end
      compound + @suffix
    end

    private def matching_close_paren(s : String, open_idx : Int32) : Int32?
      depth = 0
      i = open_idx
      while i < s.size
        case s[i]
        when '('
          depth += 1
        when ')'
          depth -= 1
          return i if depth == 0
        end
        i += 1
      end
      nil
    end

    # ===== Trivia / string / comment helpers =====

    private def copy_trivia : Nil
      loop do
        return if eof?
        case peek
        when ' ', '\t', '\n', '\r'
          @out << peek
          @pos += 1
        when '/'
          return unless peek_at(1) == '*'
          copy_comment
        else
          return
        end
      end
    end

    private def copy_comment : Nil
      @out << '/'
      @out << '*'
      @pos += 2
      until eof?
        if peek == '*' && peek_at(1) == '/'
          @out << '*'
          @out << '/'
          @pos += 2
          return
        end
        @out << peek
        @pos += 1
      end
    end

    private def copy_string(quote : Char) : Nil
      @out << quote
      @pos += 1
      until eof?
        c = peek
        if c == '\\'
          @out << c
          @pos += 1
          next if eof?
          @out << peek
          @pos += 1
          next
        end
        @out << c
        @pos += 1
        return if c == quote
      end
    end

    private def skip_comment_silently : Nil
      @pos += 2
      until eof?
        if peek == '*' && peek_at(1) == '/'
          @pos += 2
          return
        end
        @pos += 1
      end
    end

    private def skip_string_silently(quote : Char) : Nil
      @pos += 1
      until eof?
        c = peek
        if c == '\\'
          @pos += 1
          @pos += 1 unless eof?
          next
        end
        @pos += 1
        return if c == quote
      end
    end

    # ===== Byte/char helpers =====

    private def eof? : Bool
      @pos >= @bytes.size
    end

    private def peek : Char
      eof? ? '\0' : @bytes[@pos].unsafe_chr
    end

    private def peek_at(off : Int32) : Char
      p = @pos + off
      p >= @bytes.size ? '\0' : @bytes[p].unsafe_chr
    end

    private def byte_slice(start : Int32, len : Int32) : String
      @source.byte_slice(start, len)
    end

    private def letter?(c : Char) : Bool
      ('a' <= c <= 'z') || ('A' <= c <= 'Z')
    end

    private def whitespace?(c : Char) : Bool
      c == ' ' || c == '\t' || c == '\n' || c == '\r'
    end
  end
end
