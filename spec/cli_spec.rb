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

  def no_ingress_output(namespace)
    <<~TEXT
      Tracing api.example.com/users in namespace #{namespace}

      [x] Ingress
           No Ingress resources in namespace #{namespace}

      Result: failed (ingress_not_found)
    TEXT
  end

  def stub_cluster(client: nil, namespace: "default", ingresses: [], service: nil, endpoint_slices: [], pods: {})
    fake = client || instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: namespace,
      list_ingresses: ingresses,
      get_service: service,
      list_endpoint_slices: endpoint_slices
    )
    unless client
      allow(fake).to receive(:get_pod) do |name, namespace: nil|
        pods.fetch([namespace, name]) { pods[name] }
      end
    end
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

  def service_port(port, name: nil, target_port_number: nil, target_port_name: nil)
    KubeTraffic::Kubernetes::ServicePort.new(
      name: name,
      port: port,
      target_port_number: target_port_number,
      target_port_name: target_port_name
    )
  end

  def mapped_service(name = "api", namespace: "apps", ports: [service_port(80, name: "http")])
    KubeTraffic::Kubernetes::Service.new(name: name, namespace: namespace, ports: ports)
  end

  def endpoint(*addresses, ready: true, target_ref: nil)
    KubeTraffic::Kubernetes::Endpoint.new(addresses: addresses, ready: ready, target_ref: target_ref)
  end

  def target_ref(name, kind: "Pod", namespace: "apps")
    KubeTraffic::Kubernetes::TargetRef.new(kind: kind, namespace: namespace, name: name)
  end

  def mapped_pod(name = "api-abc", namespace: "apps", ip: "10.1.2.3", phase: "Running", ready: true, containers: [])
    KubeTraffic::Kubernetes::Pod.new(
      name: name,
      namespace: namespace,
      ip: ip,
      phase: phase,
      ready: ready,
      containers: containers
    )
  end

  def container(name, *ports)
    KubeTraffic::Kubernetes::Container.new(name: name, ports: ports)
  end

  def container_port(number, name: nil)
    KubeTraffic::Kubernetes::ContainerPort.new(name: name, container_port: number)
  end

  def endpoint_slice(name, service_name: "api", namespace: "apps", endpoints: [])
    KubeTraffic::Kubernetes::EndpointSlice.new(
      name: name,
      namespace: namespace,
      service_name: service_name,
      endpoints: endpoints
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
    expect(stdout).to eq(no_ingress_output("default"))
    expect(stderr).to eq("")
  end

  it "traces a host and path without a scheme" do
    stub_cluster

    status, stdout, stderr = run("trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(no_ingress_output("default"))
    expect(stderr).to eq("")
  end

  it "prints the matching Ingress rule and path" do
    stub_cluster(namespace: "apps", ingresses: [matching_ingress], service: mapped_service)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(
      "Tracing api.example.com/users in namespace apps\n" \
      "\n" \
      "[ok] Ingress api\n" \
      "     host api.example.com\n" \
      "     path /users\n" \
      "     pathType Prefix\n" \
      "     service api:80\n" \
      "\n" \
      "[ok] Service api\n" \
      "     port 80 name http\n" \
      "\n" \
      "[x] EndpointSlice\n" \
      "     No EndpointSlices for Service api\n" \
      "     No usable endpoints for Service api\n" \
      "\n" \
      "Result: failed (service_no_endpoints)\n"
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
    expect(stdout).to include("[ok] Service api\n     port 80 name http\n")
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
    expect(stdout).to include("[ok] Service api\n     port 443 name https\n")
    expect(stderr).to eq("")
  end

  it "reports a missing Service without inventing a port" do
    stub_cluster(namespace: "apps", ingresses: [matching_ingress], service: nil)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  service api:80\n")
    expect(stdout).to include("[x] Service api\n     Service api not found in namespace apps\n")
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
    expect(stdout).to include("[x] Service api\n     no port matches 8080\n")
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
    expect(stdout).to include("[x] Service api\n     backend port cannot be interpreted\n")
    expect(stderr).to eq("")
  end

  it "lists EndpointSlices labeled for the resolved Service" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-xyz",
          endpoints: [endpoint("10.1.2.4", ready: false), endpoint("10.1.2.3")]
        ),
        endpoint_slice("api-abc", endpoints: [endpoint("10.0.0.1")])
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include(
      "[ok] EndpointSlice\n" \
      "     api-abc\n" \
      "       10.0.0.1 ready=true\n" \
      "     api-xyz\n" \
      "       10.1.2.4 ready=false\n" \
      "       10.1.2.3 ready=true\n"
    )
    expect(stdout).to include("No Pod target references\n")
    expect(stderr).to eq("")
  end

  it "reports when the Service has no EndpointSlices" do
    stub_cluster(namespace: "apps", ingresses: [matching_ingress], service: mapped_service)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("No EndpointSlices for Service api\n")
    expect(stdout).to include("No usable endpoints for Service api\n")
    expect(stderr).to eq("")
  end

  it "reports EndpointSlices that contain no endpoints" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [endpoint_slice("api-empty")]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("[x] EndpointSlice\n     api-empty\n       no endpoints\n")
    expect(stdout).to include("No endpoints for Service api\n")
    expect(stdout).to include("No usable endpoints for Service api\n")
    expect(stderr).to eq("")
  end

  it "does not look up EndpointSlices when the Service is missing" do
    client = stub_cluster(namespace: "apps", ingresses: [matching_ingress], service: nil)
    expect(client).not_to receive(:list_endpoint_slices)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).not_to include("EndpointSlice")
    expect(stderr).to eq("")
  end

  it "reports ready and not-ready endpoint counts" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3"), endpoint("10.1.2.4", ready: false)]
        )
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("     10.1.2.3 ready=true\n")
    expect(stdout).to include("     10.1.2.4 ready=false\n")
    expect(stdout).to include("     ready 1\n     not-ready 1\n     unknown readiness 0\n")
    expect(stdout).not_to include("No usable endpoints")
    expect(stdout).to include("No Pod target references\n")
    expect(stderr).to eq("")
  end

  it "reports when endpoints exist but none are usable" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.4", ready: false), endpoint("10.1.2.5", ready: false)]
        )
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("  ready 0\n  not-ready 2\n  unknown readiness 0\n")
    expect(stdout).to include("No usable endpoints for Service api\n")
    expect(stdout).to include("No Pod target references\n")
    expect(stderr).to eq("")
  end

  it "treats omitted endpoint readiness as usable" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.4", ready: false), endpoint("10.1.2.5", ready: nil)]
        )
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("     ready 0\n     not-ready 1\n     unknown readiness 1\n")
    expect(stdout).not_to include("No usable endpoints")
    expect(stdout).to include("No Pod target references\n")
    expect(stderr).to eq("")
  end

  it "resolves Pods from EndpointSlice targetRef" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ],
      pods: { ["apps", "api-abc"] => mapped_pod }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include(
      "[ok] Pod api-abc\n" \
      "     IP 10.1.2.3\n" \
      "     phase Running\n" \
      "     ready=true\n"
    )
    expect(stderr).to eq("")
  end

  it "reports a missing Pod named by targetRef" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Pod api-abc not found in namespace apps\n")
    expect(stderr).to eq("")
  end

  it "does not report a missing Pod referenced only by a not-ready endpoint" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [
            endpoint("10.1.2.3", target_ref: target_ref("api-a")),
            endpoint("10.1.2.4", ready: false, target_ref: target_ref("api-b"))
          ]
        )
      ],
      pods: { ["apps", "api-a"] => mapped_pod("api-a") }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Pod api-a\n")
    expect(stdout).not_to include("Pod api-b not found")
    expect(stderr).to eq("")
  end

  it "reports a missing Pod named by a ready=nil endpoint" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.5", ready: nil, target_ref: target_ref("api-abc"))]
        )
      ]
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Pod api-abc not found in namespace apps\n")
    expect(stderr).to eq("")
  end

  it "reports missing Pods only for usable endpoints" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service,
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [
            endpoint("10.1.2.3", target_ref: target_ref("api-a")),
            endpoint("10.1.2.4", ready: false, target_ref: target_ref("api-b")),
            endpoint("10.1.2.5", ready: nil, target_ref: target_ref("api-c"))
          ]
        )
      ],
      pods: { ["apps", "api-a"] => mapped_pod("api-a") }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Pod api-a\n")
    expect(stdout).not_to include("Pod api-b not found")
    expect(stdout).to include("Pod api-c not found in namespace apps\n")
    expect(stderr).to eq("")
  end

  it "prints a numeric Service targetPort" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service(ports: [service_port(80, name: "http", target_port_number: 8080)]),
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ],
      pods: { ["apps", "api-abc"] => mapped_pod }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("[ok] Target port\n     8080\n")
    expect(stdout).to include("No declared containerPort matches 8080\n")
    expect(stdout).to include(
      "declared containerPort is configuration, not proof a process is listening\n"
    )
    expect(stderr).to eq("")
  end

  it "resolves a named targetPort against Pod container ports" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service(ports: [service_port(80, name: "http", target_port_name: "http")]),
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ],
      pods: {
        ["apps", "api-abc"] => mapped_pod(
          containers: [container("api", container_port(8080, name: "http"))]
        )
      }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("[ok] Target port\n     named http\n     api-abc 8080\n")
    expect(stdout).to include("[ok] Container api on Pod api-abc\n     port 8080 name http\n")
    expect(stdout).to include(
      "declared containerPort is configuration, not proof a process is listening\n"
    )
    expect(stderr).to eq("")
  end

  it "resolves a named targetPort to different numbers on usable pods" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service(ports: [service_port(80, name: "http", target_port_name: "http")]),
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [
            endpoint("10.1.2.3", target_ref: target_ref("api-a")),
            endpoint("10.1.2.4", target_ref: target_ref("api-b")),
            endpoint("10.1.2.5", ready: false, target_ref: target_ref("api-c"))
          ]
        )
      ],
      pods: {
        ["apps", "api-a"] => mapped_pod(
          "api-a",
          containers: [container("api", container_port(8080, name: "http"))]
        ),
        ["apps", "api-b"] => mapped_pod(
          "api-b",
          containers: [container("api", container_port(9090, name: "http"))]
        ),
        ["apps", "api-c"] => mapped_pod(
          "api-c",
          containers: [container("api", container_port(7070, name: "http"))]
        )
      }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Target port named http\n  api-a 8080\n  api-b 9090\n")
    expect(stdout).not_to include("api-c 7070")
    expect(stdout).to include("Container api on Pod api-a\n  port 8080 name http\n")
    expect(stdout).to include("Container api on Pod api-b\n  port 9090 name http\n")
    expect(stderr).to eq("")
  end

  it "reports an unresolved named targetPort" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service(ports: [service_port(80, name: "http", target_port_name: "http")]),
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ],
      pods: {
        ["apps", "api-abc"] => mapped_pod(
          containers: [container("api", container_port(8080, name: "metrics"))]
        )
      }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("Named targetPort http unresolved\n  api-abc (not declared)\n")
    expect(stdout).not_to include("Container ")
    expect(stdout).not_to include("declared containerPort")
    expect(stderr).to eq("")
  end

  it "shows the container port step for a numeric targetPort" do
    stub_cluster(
      namespace: "apps",
      ingresses: [matching_ingress],
      service: mapped_service(ports: [service_port(80, name: "http", target_port_number: 8080)]),
      endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ],
      pods: {
        ["apps", "api-abc"] => mapped_pod(
          containers: [container("api", container_port(8080))]
        )
      }
    )

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to include("[ok] Container api on Pod api-abc\n     port 8080\n")
    expect(stdout).to include(
      "declared containerPort is configuration, not proof a process is listening\n"
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
      "\n" \
      "[x] Ingress\n" \
      "     No Ingress rule matches api.example.com/users in namespace apps\n" \
      "\n" \
      "Result: failed (ingress_not_found)\n"
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
    expect(stdout).to eq(no_ingress_output("default"))
    expect(stderr).to eq("")
  end

  it "passes --namespace into the kubernetes client" do
    client = stub_cluster(namespace: "apps")
    expect(KubeTraffic::Kubernetes::Client).to receive(:connect)
      .with(context: nil, namespace: "apps")
      .and_return(client)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(no_ingress_output("apps"))
    expect(stderr).to eq("")
  end

  it "accepts -n as a short namespace option" do
    client = stub_cluster(namespace: "kube-system")
    expect(KubeTraffic::Kubernetes::Client).to receive(:connect)
      .with(context: nil, namespace: "kube-system")
      .and_return(client)

    status, stdout, stderr = run("-n", "kube-system", "trace", "api.example.com/users")

    expect(status).to eq(0)
    expect(stdout).to eq(no_ingress_output("kube-system"))
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

  it "reports kubernetes API errors when listing EndpointSlices" do
    client = instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: "apps",
      list_ingresses: [matching_ingress],
      get_service: mapped_service
    )
    allow(client).to receive(:list_endpoint_slices)
      .and_raise(KubeTraffic::Kubernetes::ApiError, "Kubernetes API error: EndpointSlice is forbidden")
    stub_cluster(client: client)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("Kubernetes API error: EndpointSlice is forbidden")
  end

  it "reports kubernetes API errors when fetching a Pod" do
    client = instance_double(
      KubeTraffic::Kubernetes::Client,
      verify_connection!: true,
      namespace: "apps",
      list_ingresses: [matching_ingress],
      get_service: mapped_service,
      list_endpoint_slices: [
        endpoint_slice(
          "api-abc",
          endpoints: [endpoint("10.1.2.3", target_ref: target_ref("api-abc"))]
        )
      ]
    )
    allow(client).to receive(:get_pod)
      .and_raise(KubeTraffic::Kubernetes::ApiError, "Kubernetes API error: Pod is forbidden")
    stub_cluster(client: client)

    status, stdout, stderr = run("--namespace", "apps", "trace", "api.example.com/users")

    expect(status).to eq(1)
    expect(stdout).to eq("")
    expect(stderr).to include("Kubernetes API error: Pod is forbidden")
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
