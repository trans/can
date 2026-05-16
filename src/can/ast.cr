module Can
  module AST
    abstract class Node
      property line : Int32
      property column : Int32

      def initialize(@line = 0, @column = 0)
      end
    end

    class Template < Node
      property children : Array(Node)

      def initialize(@children = [] of Node, @line = 0, @column = 0)
      end
    end

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

    # title="hello {name}, you have {n} messages"
    class InterpAttr < Attribute
      property parts : Array(Node)

      def initialize(@name : String, @parts : Array(Node), @line = 0, @column = 0)
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

    class Let < Node
      property name : String
      property expression : String
      property body : Array(Node)

      def initialize(@name : String, @expression : String,
                     @body = [] of Node, @line = 0, @column = 0)
      end
    end

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

    class Import < Node
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

    class Comment < Node
      property content : String

      def initialize(@content : String, @line = 0, @column = 0)
      end
    end

    class Doctype < Node
      property content : String

      def initialize(@content : String, @line = 0, @column = 0)
      end
    end
  end
end
