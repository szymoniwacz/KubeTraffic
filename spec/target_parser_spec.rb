# frozen_string_literal: true

RSpec.describe KubeTraffic::TargetParser do
  def parse(input)
    described_class.parse(input)
  end

  it "parses a hostname only" do
    target = parse("api.example.com")

    expect(target.host).to eq("api.example.com")
    expect(target.path).to eq("/")
  end

  it "parses a hostname and path" do
    target = parse("api.example.com/users")

    expect(target.host).to eq("api.example.com")
    expect(target.path).to eq("/users")
  end

  it "parses a URL with a scheme" do
    target = parse("https://api.example.com/users")

    expect(target.host).to eq("api.example.com")
    expect(target.path).to eq("/users")
  end

  it "parses an http URL without a path as /" do
    target = parse("http://api.example.com")

    expect(target.host).to eq("api.example.com")
    expect(target.path).to eq("/")
  end

  it "rejects blank input" do
    expect { parse("  ") }.to raise_error(KubeTraffic::TargetParser::Error, "target is required")
  end

  it "rejects a path without a host" do
    expect { parse("/users") }.to raise_error(KubeTraffic::TargetParser::Error, /invalid target/)
  end

  it "rejects a non-http scheme" do
    expect { parse("ftp://api.example.com/users") }.to raise_error(
      KubeTraffic::TargetParser::Error,
      /invalid target/
    )
  end

  it "rejects malformed input" do
    expect { parse("https://") }.to raise_error(KubeTraffic::TargetParser::Error, /invalid target/)
  end
end
