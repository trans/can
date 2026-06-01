require "./can"
require "./can/cli/render"

exit Can::CLI::Render.run(ARGV, "can", __DIR__)
