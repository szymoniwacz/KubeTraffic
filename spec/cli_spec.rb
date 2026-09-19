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

  def stub_cluster(client: nil, namespace: "default", ingresses: [])
    fake = client || instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: namespace,
      list_ingresses: ingresses
    )
    allow(KubeTraffic::Kubernetes::Client).to receive(:connect).and_return(fake)
    fake
  end

  def ingress(name, namespace: "default", rules: [])
    KubeTraffic::Kubernetes::Ingress.new(name: name, namespace: namespace, rules: rules)
  end

  def matching_ingress
    ingress(
      "api",
      namespace: "apps",
      rules: [
        KubeTraffic::Kubernetes::IngressRule.new(
          host: "api.example.com",
          paths: [
            KubeTraffic::Kubernetes::IngressPath.new(path: "/users", path_type: "Prefix")
          ]
        )
      ]
    )
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
    stub_cluster

    status, stdout, stderr = run("trace", "https://api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace default\n" \
      "No Ingress resources in namespace default\n"
    )
    expect(stderr).to eq("")
  end

  it "traces a host and path without a scheme" do
    stub_cluster

    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace default\n" \
      "No Ingress resources in namespace default\n"
    )
    expect(stderr).to eq("")
  end

  it "prints the matching Ingress rule and path" do
    stub_cluster(namespace: "apps", ingresses: [matching_ingress])

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace apps\n" \
      "Matched Ingress api\n" \
      "  host api.example.com\n" \
      "  path /users\n" \
      "  pathType Prefix\n"
    )
    expect(stderr).to eq("")
  end

  it "reports when Ingresses exist but no rule matches the target" do
    stub_cluster(
      namespace: "apps",
      ingresses: [
        ingress(
          "web",
          namespace: "apps",
          rules: [
            KubeTraffic::Kubernetes::IngressRule.new(
              host: "web.example.com",
              paths: [
                KubeTraffic::Kubernetes::IngressPath.new(path: "/", path_type: "Prefix")
              ]
            )
          ]
        )
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace apps\n" \
      "No Ingress rule matches api.example.com/users in namespace apps\n"
    )
    expect(stderr).to eq("")
  end

  it "connects using an optional kubernetes context" do
    client = stub_cluster
    expect(KubeTraffic::Kubernetes::Client).to receive(:connect)
      .with(context: "staging", namespace: nil)
      .and_return(client)

    status, stdout, stderr = run("--context", "staging", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace default\n" \
      "No Ingress resources in namespace default\n"
    )
    expect(stderr).to eq("")
  end

  it "passes --namespace into the kubernetes client" do
    client = stub_cluster(namespace: "apps")
    expect(KubeTraffic::Kubernetes::Client).to receive(:connect)
      .with(context: nil, namespace: "apps")
      .and_return(client)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace apps\n" \
      "No Ingress resources in namespace apps\n"
    )
    expect(stderr).to eq("")
  end

  it "accepts -n as a short namespace option" do
    client = stub_cluster(namespace: "kube-system")
    expect(KubeTraffic::Kubernetes::Client).to receive(:connect)
      .with(context: nil, namespace: "kube-system")
      .and_return(client)

    status, stdout, stderr = run("-n", "kube-system", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace kube-system\n" \
      "No Ingress resources in namespace kube-system\n"
    )
    expect(stderr).to eq("")
  end

  it "reports kubeconfig errors from the kubernetes client" do
    allow(KubeTraffic::Kubernetes::Client).to receive(:connect)
      .and_raise(KubeTraffic::Kubernetes::ConfigError, "kubeconfig not found: /tmp/missing")

    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("kubeconfig not found: /tmp/missing")
  end

  it "reports kubernetes API connection errors" do
    client = instance_double(KubeTraffic::Kubernetes::Client)
    allow(client).to receive(:verify_connection!)
      .and_raise(KubeTraffic::Kubernetes::ConnectionError, "unable to connect to the Kubernetes API: connection refused")
    stub_cluster(client: client)

    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("unable to connect to the Kubernetes API")
  end

  it "reports kubernetes authorization errors" do
    client = instance_double(KubeTraffic::Kubernetes::Client)
    allow(client).to receive(:verify_connection!)
      .and_raise(KubeTraffic::Kubernetes::AuthorizationError, "not authorized to access the Kubernetes API: forbidden")
    stub_cluster(client: client)

    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("not authorized to access the Kubernetes API")
  end

  it "reports kubernetes API errors when listing Ingresses" do
    client = instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: "default"
    )
    allow(client).to receive(:list_ingresses)
      .and_raise(KubeTraffic::Kubernetes::ApiError, "Kubernetes API error: Ingress is forbidden")
    stub_cluster(client: client)

    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("Kubernetes API error: Ingress is forbidden")
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

  it "rejects extra arguments after the target" do
    status, stdout, stderr = run("trace", "api.example.com/users", "extra")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("unexpected arguments: extra")
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
