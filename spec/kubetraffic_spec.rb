# frozen_string_literal: true

RSpec.describe KubeTraffic do
  it "has a version number" do
    expect(KubeTraffic::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end
end
