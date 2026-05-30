require "../ast"
require "../parser"
require "../codegen"

mode = ARGV[0]?
arg = ARGV[1]?
scope = ARGV[2]? || "class"

unless mode && arg
  STDERR.puts "usage: compile_template (inline|file) <source-or-path> [class|method|use|view]"
  exit 1
end

source_name = case mode
              when "inline" then "inline template"
              when "file"   then arg
              else               nil
              end

source = case mode
         when "inline" then arg
         when "file"
           begin
             File.read(arg)
           rescue ex
             STDERR.puts "Can template error: cannot read #{arg}: #{ex.message}"
             exit 1
           end
         else
           STDERR.puts "unknown mode: #{mode}"
           exit 1
         end

scope_sym = case scope
            when "class"  then :class
            when "method" then :method
            when "use"    then :use
            when "view"   then :view
            else
              STDERR.puts "unknown scope: #{scope}"
              exit 1
            end

begin
  print Can::Codegen.compile(source, scope_sym, source_name)
rescue ex : Can::ParseError
  if source_name
    message = ex.message.to_s.sub(/ \(line \d+, col \d+\)\z/, "")
    STDERR.puts "Can template error in #{source_name}:#{ex.line}:#{ex.column}: #{message}"
  else
    STDERR.puts "Can template error: #{ex.message}"
  end
  exit 1
rescue ex
  STDERR.puts "Can template error: #{ex.message}"
  exit 1
end
