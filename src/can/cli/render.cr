require "option_parser"

module Can
  module CLI
    class Render
      private DEFAULT_CLASS = "CanRenderPage"
      private IDENTIFIER    = /\A[a-z_][a-zA-Z0-9_]*\z/
      private CLASS_NAME    = /\A[A-Z][a-zA-Z0-9_]*\z/

      private class UsageError < Exception
      end

      @output_path : String?
      @requires : Array(String)
      @assigns : Array({String, String})
      @class_name : String
      @show_help : Bool
      @show_version : Bool

      def self.run(argv : Array(String), can_require : String, can_source_dir : String) : Int32
        new(argv, can_require, can_source_dir).run
      end

      def initialize(@argv : Array(String), @can_require : String, @can_source_dir : String)
        @output_path = nil
        @requires = [] of String
        @assigns = [] of {String, String}
        @class_name = DEFAULT_CLASS
        @show_help = false
        @show_version = false
      end

      def run : Int32
        parser = build_parser

        begin
          parser.parse(@argv)
          return print_help(parser) if @show_help
          return print_version if @show_version

          raise UsageError.new("expected exactly one .can file") unless @argv.size == 1

          template_path = File.expand_path(@argv.first)
          raise UsageError.new("cannot read #{template_path}") unless File.exists?(template_path) && !File.directory?(template_path)

          render(template_path)
        rescue ex : UsageError
          STDERR.puts "can-render: #{ex.message}"
          STDERR.puts parser
          1
        rescue ex : OptionParser::Exception
          STDERR.puts "can-render: #{ex.message}"
          STDERR.puts parser
          1
        end
      end

      private def build_parser : OptionParser
        OptionParser.new do |parser|
          parser.banner = "Usage: can-render [options] FILE"

          parser.on("-o PATH", "--output=PATH", "Write rendered HTML to PATH instead of stdout.") do |path|
            @output_path = path
          end

          parser.on("-r PATH", "--require=PATH", "Require a Crystal helper file before rendering. Repeatable.") do |path|
            @requires << path
          end

          parser.on("-D NAME=VALUE", "--assign=NAME=VALUE", "Expose a string getter to the template. Repeatable.") do |raw|
            @assigns << parse_assign(raw)
          end

          parser.on("--class=NAME", "Generated page class name. Defaults to #{DEFAULT_CLASS}.") do |name|
            raise UsageError.new("--class must be a simple Crystal constant name") unless name.matches?(CLASS_NAME)

            @class_name = name
          end

          parser.on("-v", "--version", "Print Can version.") do
            @show_version = true
          end

          parser.on("-h", "--help", "Show this help.") do
            @show_help = true
          end
        end
      end

      private def parse_assign(raw : String) : {String, String}
        idx = raw.index('=')
        raise UsageError.new("assigns must use NAME=VALUE") unless idx

        name = raw[0...idx]
        value = raw[(idx + 1)..]
        raise UsageError.new("invalid assign name #{name.inspect}") unless name.matches?(IDENTIFIER)

        {name, value}
      end

      private def render(template_path : String) : Int32
        tmp = File.tempfile("can_render", ".cr")
        tmp_path = tmp.path

        begin
          tmp.print(build_program(template_path, File.dirname(tmp_path)))
          tmp.close

          output = IO::Memory.new
          error = IO::Memory.new
          status = Process.run(
            "crystal", ["run", "--no-color", tmp_path],
            env: compiler_env, output: output, error: error, chdir: Dir.current
          )

          unless status.success?
            STDERR << error
            return status.exit_code || 1
          end

          if output_path = @output_path
            File.write(output_path, output.to_s)
          else
            STDOUT << output
          end

          0
        rescue ex : File::NotFoundError
          STDERR.puts "can-render: crystal executable not found"
          1
        ensure
          tmp.close unless tmp.closed?
          File.delete(tmp_path) if File.exists?(tmp_path)
        end
      end

      private def build_program(template_path : String, program_dir : String) : String
        String.build do |io|
          io << "require " << @can_require.inspect << '\n'
          @requires.each do |path|
            io << "require " << require_path(path, program_dir).inspect << '\n'
          end

          io << "\nclass " << @class_name << '\n'
          @assigns.each do |name, _|
            io << "  getter " << name << " : String\n"
          end

          unless @assigns.empty?
            io << "\n  def initialize("
            @assigns.each_with_index do |(name, _), index|
              io << ", " unless index == 0
              io << '@' << name << " : String"
            end
            io << ")\n"
            io << "  end\n"
          end

          io << "\n  Can.view " << template_path.inspect << "\n"
          io << "end\n\n"
          io << "page = " << @class_name << ".new"

          unless @assigns.empty?
            io << '('
            @assigns.each_with_index do |(_, value), index|
              io << ", " unless index == 0
              io << value.inspect
            end
            io << ')'
          end

          io << "\npage.render(STDOUT)\n"
        end
      end

      private def require_path(path : String, program_dir : String) : String
        relative = Path[File.expand_path(path)].relative_to(Path[program_dir]).to_s
        relative.starts_with?(".") ? relative : "./#{relative}"
      end

      private def compiler_env : Hash(String, String)
        {"CRYSTAL_PATH" => compiler_crystal_path}
      end

      private def compiler_crystal_path : String
        output = IO::Memory.new
        status = Process.run("crystal", ["env", "CRYSTAL_PATH"], output: output, error: Process::Redirect::Close)
        default = status.success? ? output.to_s.strip : ENV["CRYSTAL_PATH"]? || ""

        default.empty? ? @can_source_dir : "#{@can_source_dir}:#{default}"
      end

      private def print_help(parser : OptionParser) : Int32
        puts parser
        0
      end

      private def print_version : Int32
        puts Can::VERSION
        0
      end
    end
  end
end
