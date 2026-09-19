# frozen_string_literal: true

require "stringio"
require "open3"

RSpec.describe KubeTraffic::CLI do
  def run(*argv)
    stdout = StringIO.new
    stderr = StringIO.new
    status = described_class.run(argv, stdout: stdout, stderr: stderr)
    [status, stdout.string, stderr.string]
  end

  it "prints the version for --version" do
    status, stdout, stderr = run("--version")

    expect(status).to eq(0)
    expect(stdout).to eq("KubeTraffic #{KubeTraffic::VERSION}\n")
    expect(stderr).to eq("")
  end

  it "prints the version for -v" do
    status, stdout, stderr = run("-v")

    expect(status).to eq(0)
    expect(stdout).to eq("KubeTraffic #{KubeTraffic::VERSION}\n")
    expect(stderr).to eq("")
  end

  it "rejects unknown options" do
    status, stdout, stderr = run("--nope")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("invalid option")
  end

  it "prints usage when no options are given" do
    status, stdout, stderr = run

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("Usage: kubetraffic [options] [COMMAND]")
  end

  it "traces an https URL" do
    status, stdout, stderr = run("trace", "https://api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq("Tracing api.example.com/users\n")
    expect(stderr).to eq("")
  end

  it "traces a host and path without a scheme" do
    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq("Tracing api.example.com/users\n")
    expect(stderr).to eq("")
  end

  it "rejects an invalid trace target" do
    status, stdout, stderr = run("trace", "/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("invalid target")
  end

  it "rejects trace without a target" do
    status, stdout, stderr = run("trace")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("missing target")
  end

  it "rejects unknown commands" do
    status, stdout, stderr = run("watch")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("unknown command: watch")
  end
end

RSpec.describe "bin/kubetraffic" do
  it "prints the version" do
    executable = File.expand_path("../bin/kubetraffic", __dir__)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, executable, "--version")

    expect(status).to be_success
    expect(stdout).to eq("KubeTraffic #{KubeTraffic::VERSION}\n")
    expect(stderr).to eq("")
  end
end
