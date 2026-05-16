require "spec"
require "../src/can"

CAN_SRC_DIR  = File.expand_path("../src", __DIR__)
PROJECT_ROOT = File.expand_path("..", __DIR__)

# Crystal honors $CRYSTAL_PATH for require lookup; if set it replaces the
# default, so we query the default and prepend.
CRYSTAL_PATH_FOR_TESTS = begin
  default = `crystal env CRYSTAL_PATH`.strip
  default.empty? ? CAN_SRC_DIR : "#{CAN_SRC_DIR}:#{default}"
end
