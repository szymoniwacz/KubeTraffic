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
    expect(stderr).to include("Usage: kubetraffic [options]")
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
