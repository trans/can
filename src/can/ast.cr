module Can
  # Parsed template node types used by `Parser` and consumed by `Codegen`.
  #
  # These classes are intentionally public so tools can parse `.can` files,
  # inspect the tree, and build experiments on top of Can without depending on
  # Crystal macros.
  module AST
    # Base class for every parsed node.
    #
    # `line` and `column` point at the node's source location when available.
    abstract class Node
      property line : Int32
      property column : Int32

      def initialize(@line = 0, @column = 0)
      end
    end

    # Root node for a parsed `.can` template.
    class Template < Node
      property children : Array(Node)

      def initialize(@children = [] of Node, @line = 0, @column = 0)
      end
    end

    # Literal text between tags, comments, and interpolations.
    class Text < Node
      property content : String

      def initialize(@content : String, @line = 0, @column = 0)
      end
    end

    # {expr} — `expression` holds raw Crystal source, parsed by the Crystal
    # compiler when the macro splices it into generated code.
    class Interpolation < Node
      property expression : String

      def initialize(@expression : String, @line = 0, @column = 0)
      end
    end

    # Base class for parsed element and special-form attributes.
    abstract class Attribute < Node
      property name : String

      def initialize(@name : String, @line = 0, @column = 0)
      end
    end

    # title="hello"
    class StringAttr < Attribute
      property value : String

      def initialize(@name : String, @value : String, @line = 0, @column = 0)
      end
    end

    # items={list} — a single Crystal expression, not a string
    class ExprAttr < Attribute
      property expression : String

      def initialize(@name : String, @expression : String, @line = 0, @column = 0)
      end
    end

    # Standard HTML tag OR user-defined component invocation.
    # Resolution happens at codegen time against the in-scope def registry.
    class Element < Node
      property tag : String
      property attributes : Array(Attribute)
      property children : Array(Node)
      property self_closing : Bool

      def initialize(@tag : String, @attributes = [] of Attribute,
                     @children = [] of Node, @self_closing = false,
                     @line = 0, @column = 0)
      end
    end

    # Parameter declaration from a component definition.
    #
    # Required params carry a `type`; optional params carry the default Crystal
    # expression in `default`.
    class Param < Node
      property name : String
      property type : String
      property default : String?

      def initialize(@name : String, @type : String,
                     @default : String? = nil, @line = 0, @column = 0)
      end
    end

    # <.def tag="card" param:title="String">…</.def>
    class Def < Node
      property tag : String
      property params : Array(Param)
      property body : Array(Node)

      def initialize(@tag : String, @params = [] of Param,
                     @body = [] of Node, @line = 0, @column = 0)
      end
    end

    # Both <.if cond={…}>…</.if> and the :if={…} attribute desugar to this.
    class If < Node
      property condition : String
      property then_body : Array(Node)
      property else_body : Array(Node)

      def initialize(@condition : String, @then_body = [] of Node,
                     @else_body = [] of Node, @line = 0, @column = 0)
      end
    end

    # <.for each={item in items}>…</.for> and :for={item in items} desugar here.
    class For < Node
      property var : String
      property collection : String
      property body : Array(Node)

      def initialize(@var : String, @collection : String,
                     @body = [] of Node, @line = 0, @column = 0)
      end
    end

    # Local binding special form: `<.let name="x" value={expr}>...</.let>`.
    class Let < Node
      property name : String
      property expression : String
      property body : Array(Node)

      def initialize(@name : String, @expression : String,
                     @body = [] of Node, @line = 0, @column = 0)
      end
    end

    # Slot placeholder inside a top-level component definition.
    #
    # A `nil` name is the default slot; otherwise the slot is filled with a
    # matching `<:name>...</:name>` at the call site.
    class Slot < Node
      property name : String?

      def initialize(@name : String? = nil, @line = 0, @column = 0)
      end
    end

    # <:name>…</:name> — fills a named slot at a component invocation site.
    # Parsed for any tag starting with `:`. Only meaningful as a child of a
    # component-invocation Element; codegen rejects it elsewhere.
    class SlotFill < Node
      property name : String
      property body : Array(Node)

      def initialize(@name : String, @body = [] of Node, @line = 0, @column = 0)
      end
    end

    # Transient parser-only nodes: `<.else/>` and `<.elseif cond={…}/>` are
    # sentinels emitted by the parser and consumed by `build_if`, which
    # restructures the body into nested `If` nodes. They never reach codegen
    # in well-formed templates; if they do, codegen raises a "stray" error.
    class ElseMark < Node
    end

    class ElseIfMark < Node
      property condition : String

      def initialize(@condition : String, @line = 0, @column = 0)
      end
    end

    # Crystal require directive: `<.require from="..."/>`.
    class Require < Node
      property from : String

      def initialize(@from : String, @line = 0, @column = 0)
      end
    end

    # Template dependency directive: `<.use from="..."/>`.
    #
    # Codegen loads the referenced `.can` file as a component-only template.
    class Use < Node
      property from : String

      def initialize(@from : String, @line = 0, @column = 0)
      end
    end

    # <.raw>…</.raw> — every {expr} interpolation directly inside this body
    # is emitted verbatim (no HTML escape). Doesn't penetrate into <.def>
    # bodies nested within (those have their own escape context).
    class Raw < Node
      property body : Array(Node)

      def initialize(@body = [] of Node, @line = 0, @column = 0)
      end
    end

    # HTML comment: `<!-- ... -->`.
    class Comment < Node
      property content : String

      def initialize(@content : String, @line = 0, @column = 0)
      end
    end

    # Doctype or bang directive, such as `<!DOCTYPE html>`.
    class Doctype < Node
      property content : String

      def initialize(@content : String, @line = 0, @column = 0)
      end
    end
  end
end
