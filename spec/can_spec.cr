require "./spec_helper"

describe Can do
  it "loads" do
    Can::VERSION.should eq("0.2.2")
  end
end
