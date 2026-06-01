require "./spec_helper"

describe Can do
  it "loads" do
    shard_version = File.read(File.join(PROJECT_ROOT, "shard.yml"))
      .match(/^version:\s*(\S+)/m)
      .not_nil![1]

    Can::VERSION.should eq(shard_version)
  end
end
