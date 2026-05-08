require "../ast"
require "../parser"
require "../codegen"

mode = ARGV[0]?
arg = ARGV[1]?
scope = ARGV[2]? || "class"

unless mode && arg
  STDERR.puts "usage: compile_template (inline|file) <source-or-path> [class|method]"
  exit 1
end

source = case mode
         when "inline" then arg
         when "file"   then File.read(arg)
         else
           STDERR.puts "unknown mode: #{mode}"
           exit 1
         end

scope_sym = case scope
            when "class"  then :class
            when "method" then :method
            else
              STDERR.puts "unknown scope: #{scope}"
              exit 1
            end

print Can::Codegen.compile(source, scope_sym)
