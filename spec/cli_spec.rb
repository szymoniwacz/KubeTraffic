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

  def stub_cluster(client: nil, namespace: "default", ingresses: [], service: nil)
    fake = client || instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: namespace,
      list_ingresses: ingresses,
      get_service: service
    )
    allow(KubeTraffic::Kubernetes::Client).to receive(:connect).and_return(fake)
    fake
  end

  def ingress(name, namespace: "default", rules: [])
    KubeTraffic::Kubernetes::Ingress.new(name: name, namespace: namespace, rules: rules)
  end

  def matching_ingress(backend: service_backend("api", port_number: 80))
    ingress(
      "api",
      namespace: "apps",
      rules: [
        KubeTraffic::Kubernetes::IngressRule.new(
          host: "api.example.com",
          paths: [
            KubeTraffic::Kubernetes::IngressPath.new(
              path: "/users",
              path_type: "Prefix",
              backend: backend
            )
          ]
        )
      ]
    )
  end

  def service_backend(name, port_number: nil, port_name: nil)
    KubeTraffic::Kubernetes::IngressServiceBackend.new(
      name: name,
      port_number: port_number,
      port_name: port_name
    )
  end

  def service_port(port, name: nil)
    KubeTraffic::Kubernetes::ServicePort.new(name: name, port: port)
  end

  def mapped_service(name = "api", namespace: "apps", ports: [service_port(80, name: "http")])
    KubeTraffic::Kubernetes::Service.new(name: name, namespace: namespace, ports: ports)
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
    stub_cluster(namespace: "apps", ingresses: [matching_ingress], service: mapped_service)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace apps\n" \
      "Matched Ingress api\n" \
      "  host api.example.com\n" \
      "  path /users\n" \
      "  pathType Prefix\n" \
      "  service api:80\n" \
      "Service api\n" \
      "  port 80 name http\n"
    )
    expect(stderr).to eq("")
  end

  it "prints a named backend Service port" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress(backend: service_backend("api", port_name: "http"))],
      service: mapped_service
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  service api:http\n")
    expect(stderr).to eq("")
  end

  it "prints the resolved Service port for a numeric Ingress backend" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service(
        ports: [service_port(80, name: "http"), service_port(443, name: "https")]
      )
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Service api\n  port 80 name http\n")
    expect(stderr).to eq("")
  end

  it "prints the resolved Service port for a named Ingress backend" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress(backend: service_backend("api", port_name: "https"))],
      service: mapped_service(
        ports: [service_port(80, name: "http"), service_port(443, name: "https")]
      )
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  service api:https\n")
    expect(stdout).to include("Service api\n  port 443 name https\n")
    expect(stderr).to eq("")
  end

  it "reports a missing Service without inventing a port" do
    stub_cluster(namespace: "apps", ingresses: [matching_ingress], service: nil)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  service api:80\n")
    expect(stdout).to include("Service api not found in namespace apps\n")
    expect(stderr).to eq("")
  end

  it "reports an unmatched Service port" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress(backend: service_backend("api", port_number: 8080))],
      service: mapped_service(ports: [service_port(80, name: "http"), service_port(443)])
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Service api\n  no port matches 8080\n")
    expect(stderr).to eq("")
  end

  it "reports when the matched backend is not a Service" do
    stub_cluster(namespace: "apps", ingresses: [matching_ingress(backend: nil)])

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  backend cannot be interpreted\n")
    expect(stderr).to eq("")
  end

  it "reports when the Service backend has no interpretable port" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress(backend: service_backend("api"))],
      service: mapped_service
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  service api (backend port cannot be interpreted)\n")
    expect(stdout).to include("Service api\n  backend port cannot be interpreted\n")
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

  it "reports kubernetes API errors when fetching a Service" do
    client = instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: "apps",
      list_ingresses: [matching_ingress]
    )
    allow(client).to receive(:get_service)
      .and_raise(KubeTraffic::Kubernetes::ApiError, "Kubernetes API error: Service is forbidden")
    stub_cluster(client: client)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("Kubernetes API error: Service is forbidden")
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
