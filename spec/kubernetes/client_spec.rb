# frozen_string_literal: true

require "tempfile"
require "kubeclient"

RSpec.describe KubeTraffic::Kubernetes::Client do
  def write_kubeconfig(current_context: "test", extra_contexts: [], namespace: nil)
    file = Tempfile.new(["kubeconfig", ".yml"])
    file.write(<<~YAML)
      apiVersion: v1
      kind: Config
      current-context: #{current_context}
      contexts:
      - name: test
        context:
          cluster: test
          user: test
          #{namespace && "namespace: #{namespace}"}
      #{extra_contexts.join}
      clusters:
      - name: test
        cluster:
          server: https://kube.example.test
      users:
      - name: test
        user:
          token: fake-token
    YAML
    file.flush
    file
  end

  def http_error(code, message)
    Kubeclient::HttpError.new(code, message, nil)
  end

  def ingress_resource(name:, namespace: "default", spec: nil)
    Kubeclient::Resource.new(
      "metadata" => { "name" => name, "namespace" => namespace },
      "spec" => spec
    )
  end

  def listed_path(spec)
    networking_api = double("networking_api")
    allow(networking_api).to receive(:get_ingresses).and_return(
      [
        ingress_resource(
          name: "api",
          spec: {
            "rules" => [
              {
                "host" => "api.example.com",
                "http" => { "paths" => [spec] }
              }
            ]
          }
        )
      ]
    )

    described_class.new(
      api: instance_double(Kubeclient::Client),
      networking_api: networking_api
    ).list_ingresses.first.rules.first.paths.first
  end

  def client_options
    hash_including(
      ssl_options: hash_including(:verify_ssl),
      auth_options: hash_including(bearer_token: "fake-token")
    )
  end

  around do |example|
    original = ENV["KUBECONFIG"]
    example.run
  ensure
    if original.nil?
      ENV.delete("KUBECONFIG")
    else
      ENV["KUBECONFIG"] = original
    end
  end

  it "loads kubeconfig and builds core, networking, and discovery clients for the current context" do
    kubeconfig = write_kubeconfig
    api = instance_double(Kubeclient::Client)
    networking_api = instance_double(Kubeclient::Client)
    discovery_api = instance_double(Kubeclient::Client)
    expect(Kubeclient::Client).to receive(:new).with(
      "https://kube.example.test",
      "v1",
      client_options
    ).and_return(api)
    expect(Kubeclient::Client).to receive(:new).with(
      "https://kube.example.test/apis/networking.k8s.io",
      "v1",
      client_options
    ).and_return(networking_api)
    expect(Kubeclient::Client).to receive(:new).with(
      "https://kube.example.test/apis/discovery.k8s.io",
      "v1",
      client_options
    ).and_return(discovery_api)

    ENV["KUBECONFIG"] = kubeconfig.path
    described_class.connect

    kubeconfig.close!
  end

  it "uses an explicit kubeconfig path and named context" do
    kubeconfig = write_kubeconfig(
      current_context: "other",
      extra_contexts: [
        <<~YAML
          - name: staging
            context:
              cluster: test
              user: test
        YAML
      ]
    )
    api = instance_double(Kubeclient::Client)
    expect(Kubeclient::Client).to receive(:new).exactly(3).times.and_return(api)

    described_class.connect(context: "staging", kubeconfig: kubeconfig.path)

    kubeconfig.close!
  end

  it "defaults to the default namespace when the context has none" do
    kubeconfig = write_kubeconfig
    api = instance_double(Kubeclient::Client)
    allow(Kubeclient::Client).to receive(:new).and_return(api)

    client = described_class.connect(kubeconfig: kubeconfig.path)

    expect(client.namespace).to eq("default")
  ensure
    kubeconfig.close!
  end

  it "uses the kubeconfig context namespace when none is given" do
    kubeconfig = write_kubeconfig(namespace: "apps")
    api = instance_double(Kubeclient::Client)
    allow(Kubeclient::Client).to receive(:new).and_return(api)

    client = described_class.connect(kubeconfig: kubeconfig.path)

    expect(client.namespace).to eq("apps")
  ensure
    kubeconfig.close!
  end

  it "prefers an explicit namespace over the kubeconfig context namespace" do
    kubeconfig = write_kubeconfig(namespace: "apps")
    api = instance_double(Kubeclient::Client)
    allow(Kubeclient::Client).to receive(:new).and_return(api)

    client = described_class.connect(namespace: "kube-system", kubeconfig: kubeconfig.path)

    expect(client.namespace).to eq("kube-system")
  ensure
    kubeconfig.close!
  end

  it "raises when an explicit namespace is blank" do
    kubeconfig = write_kubeconfig(namespace: "apps")
    api = instance_double(Kubeclient::Client)
    allow(Kubeclient::Client).to receive(:new).and_return(api)

    expect {
      described_class.connect(namespace: "  ", kubeconfig: kubeconfig.path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      "namespace must not be empty"
    )
  ensure
    kubeconfig.close!
  end

  it "uses the default namespace when an injected API has none" do
    api = instance_double(Kubeclient::Client)

    expect(described_class.new(api: api).namespace).to eq("default")
  end

  it "raises when kubeconfig is missing" do
    ENV.delete("KUBECONFIG")
    path = File.join(Dir.tmpdir, "kubetraffic-missing-kubeconfig")

    expect {
      described_class.connect(kubeconfig: path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      "kubeconfig not found: #{path}"
    )
  end

  it "raises when the named context is missing" do
    kubeconfig = write_kubeconfig

    expect {
      described_class.connect(context: "missing", kubeconfig: kubeconfig.path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      'kubernetes context not found: "missing"'
    )

    kubeconfig.close!
  end

  it "verifies connectivity through the wrapped API client" do
    api = instance_double(Kubeclient::Client)
    expect(api).to receive(:api).and_return({ "versions" => ["v1"] })

    expect(described_class.new(api: api).verify_connection!).to eq(true)
  end

  it "maps unauthorized responses" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(http_error(401, "Unauthorized"))

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps forbidden responses" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(http_error(403, "Forbidden"))

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps other Kubernetes HTTP errors as API errors" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(http_error(500, "Internal error"))

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::ApiError,
      /Kubernetes API error/
    )
  end

  it "maps low-level network errors as connection failures" do
    api = instance_double(Kubeclient::Client)
    allow(api).to receive(:api).and_raise(Errno::ECONNREFUSED)

    expect {
      described_class.new(api: api).verify_connection!
    }.to raise_error(
      KubeTraffic::Kubernetes::ConnectionError,
      /unable to connect to the Kubernetes API/
    )
  end

  it "lists Ingress resources from the selected namespace" do
    networking_api = double("networking_api")
    expect(networking_api).to receive(:get_ingresses).with(namespace: "apps").and_return(
      [
        ingress_resource(
          name: "web",
          namespace: "apps",
          spec: {
            "rules" => [
              {
                "host" => "web.example.com",
                "http" => {
                  "paths" => [
                    {
                      "path" => "/app",
                      "pathType" => "Prefix",
                      "backend" => {
                        "service" => {
                          "name" => "web",
                          "port" => { "number" => 80 }
                        }
                      }
                    }
                  ]
                }
              }
            ]
          }
        ),
        ingress_resource(name: "api", namespace: "apps", spec: { "rules" => [] })
      ]
    )

    ingresses = described_class.new(
      api: instance_double(Kubeclient::Client),
      networking_api: networking_api,
      namespace: "apps"
    ).list_ingresses

    expect(ingresses.map(&:name)).to eq(%w[api web])
    expect(ingresses.map(&:namespace).uniq).to eq(["apps"])
    expect(ingresses.find { |ingress| ingress.name == "web" }.rules).to eq(
      [
        KubeTraffic::Kubernetes::IngressRule.new(
          host: "web.example.com",
          paths: [
            KubeTraffic::Kubernetes::IngressPath.new(
              path: "/app",
              path_type: "Prefix",
              backend: KubeTraffic::Kubernetes::IngressServiceBackend.new(
                name: "web",
                port_number: 80,
                port_name: nil
              )
            )
          ]
        )
      ]
    )
  end

  it "normalizes a missing Ingress path to / and preserves a missing pathType" do
    networking_api = double("networking_api")
    allow(networking_api).to receive(:get_ingresses).and_return(
      [
        ingress_resource(
          name: "bare",
          spec: {
            "rules" => [
              { "http" => { "paths" => [{ "path" => nil, "pathType" => nil }] } }
            ]
          }
        )
      ]
    )

    ingress = described_class.new(
      api: instance_double(Kubeclient::Client),
      networking_api: networking_api
    ).list_ingresses.first

    expect(ingress.rules.first.host).to be_nil
    expect(ingress.rules.first.paths).to eq(
      [KubeTraffic::Kubernetes::IngressPath.new(path: "/", path_type: nil)]
    )
  end

  it "maps a numeric Ingress backend Service port" do
    path = listed_path(
      "path" => "/users",
      "pathType" => "Prefix",
      "backend" => {
        "service" => {
          "name" => "api",
          "port" => { "number" => 8080 }
        }
      }
    )

    expect(path.backend).to eq(
      KubeTraffic::Kubernetes::IngressServiceBackend.new(
        name: "api",
        port_number: 8080,
        port_name: nil
      )
    )
  end

  it "maps a named Ingress backend Service port" do
    path = listed_path(
      "path" => "/users",
      "pathType" => "Prefix",
      "backend" => {
        "service" => {
          "name" => "api",
          "port" => { "name" => "http" }
        }
      }
    )

    expect(path.backend).to eq(
      KubeTraffic::Kubernetes::IngressServiceBackend.new(
        name: "api",
        port_number: nil,
        port_name: "http"
      )
    )
  end

  it "does not invent a Service backend when it is missing or not a Service" do
    missing = listed_path("path" => "/users", "pathType" => "Prefix")
    resource = listed_path(
      "path" => "/users",
      "pathType" => "Prefix",
      "backend" => {
        "resource" => {
          "apiGroup" => "example.com",
          "kind" => "StorageBucket",
          "name" => "assets"
        }
      }
    )
    blank_name = listed_path(
      "path" => "/users",
      "pathType" => "Prefix",
      "backend" => {
        "service" => {
          "name" => " ",
          "port" => { "number" => 80 }
        }
      }
    )

    expect(missing.backend).to be_nil
    expect(resource.backend).to be_nil
    expect(blank_name.backend).to be_nil
  end

  it "preserves a Service name when the backend port is missing or malformed" do
    missing_port = listed_path(
      "path" => "/users",
      "pathType" => "Prefix",
      "backend" => { "service" => { "name" => "api" } }
    )
    malformed_port = listed_path(
      "path" => "/users",
      "pathType" => "Prefix",
      "backend" => {
        "service" => {
          "name" => "api",
          "port" => { "number" => "http" }
        }
      }
    )

    expect(missing_port.backend.name).to eq("api")
    expect(missing_port.backend.port_number).to be_nil
    expect(missing_port.backend.port_name).to be_nil
    expect(malformed_port.backend.port_number).to be_nil
    expect(malformed_port.backend.port_name).to be_nil
  end

  def fetched_service(spec:, name: "api", namespace: "apps")
    api = double("api")
    allow(api).to receive(:get_service).with(name, namespace).and_return(
      Kubeclient::Resource.new(
        "metadata" => { "name" => name, "namespace" => namespace },
        "spec" => spec
      )
    )

    described_class.new(
      api: api,
      networking_api: double("networking_api"),
      namespace: namespace
    ).get_service(name)
  end

  it "fetches a Service from the selected namespace" do
    service = fetched_service(
      spec: {
        "ports" => [
          { "name" => "http", "port" => 80 },
          { "name" => "https", "port" => 443 }
        ]
      }
    )

    expect(service).to eq(
      KubeTraffic::Kubernetes::Service.new(
        name: "api",
        namespace: "apps",
        ports: [
          KubeTraffic::Kubernetes::ServicePort.new(name: "http", port: 80),
          KubeTraffic::Kubernetes::ServicePort.new(name: "https", port: 443)
        ]
      )
    )
  end

  it "drops Service ports that have no numeric port" do
    service = fetched_service(
      spec: {
        "ports" => [
          { "name" => "http" },
          { "name" => "alt", "port" => "not-a-port" },
          { "port" => 9090 }
        ]
      }
    )

    expect(service.ports).to eq(
      [KubeTraffic::Kubernetes::ServicePort.new(name: nil, port: 9090)]
    )
  end

  it "returns nil when the Service is missing" do
    api = double("api")
    allow(api).to receive(:get_service).with("api", "default")
      .and_raise(http_error(404, "services \"api\" not found"))

    expect(
      described_class.new(
        api: api,
        networking_api: double("networking_api")
      ).get_service("api")
    ).to be_nil
  end

  it "does not query the API for a blank Service name" do
    api = double("api")
    expect(api).not_to receive(:get_service)

    expect(
      described_class.new(
        api: api,
        networking_api: double("networking_api")
      ).get_service(" ")
    ).to be_nil
  end

  it "maps Service get authorization failures" do
    api = double("api")
    allow(api).to receive(:get_service).and_raise(http_error(403, "Forbidden"))

    expect {
      described_class.new(
        api: api,
        networking_api: double("networking_api")
      ).get_service("api")
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps Service get HTTP errors as API errors" do
    api = double("api")
    allow(api).to receive(:get_service).and_raise(http_error(500, "Internal error"))

    expect {
      described_class.new(
        api: api,
        networking_api: double("networking_api")
      ).get_service("api")
    }.to raise_error(
      KubeTraffic::Kubernetes::ApiError,
      /Kubernetes API error/
    )
  end

  def listed_slices(resources, service_name: "api", namespace: "apps")
    discovery_api = double("discovery_api")
    allow(discovery_api).to receive(:get_endpoint_slices).and_return(resources)

    described_class.new(
      api: instance_double(Kubeclient::Client),
      networking_api: double("networking_api"),
      discovery_api: discovery_api,
      namespace: namespace
    ).list_endpoint_slices(service_name)
  end

  def slice_resource(name:, namespace: "apps", labels: { "kubernetes.io/service-name" => "api" }, endpoints: [])
    Kubeclient::Resource.new(
      "metadata" => { "name" => name, "namespace" => namespace, "labels" => labels },
      "endpoints" => endpoints
    )
  end

  it "lists EndpointSlices for a Service using the kubernetes.io/service-name label" do
    discovery_api = double("discovery_api")
    expect(discovery_api).to receive(:get_endpoint_slices).with(
      namespace: "apps",
      label_selector: "kubernetes.io/service-name=api"
    ).and_return(
      [
        slice_resource(
          name: "api-b",
          endpoints: [
            { "addresses" => ["10.1.2.4"], "conditions" => { "ready" => false } }
          ]
        ),
        slice_resource(
          name: "api-a",
          endpoints: [
            { "addresses" => ["10.1.2.3", " "], "conditions" => { "ready" => true } }
          ]
        )
      ]
    )

    slices = described_class.new(
      api: instance_double(Kubeclient::Client),
      networking_api: double("networking_api"),
      discovery_api: discovery_api,
      namespace: "apps"
    ).list_endpoint_slices("api")

    expect(slices.map(&:name)).to eq(%w[api-a api-b])
    expect(slices.map(&:service_name).uniq).to eq(["api"])
    expect(slices.first.endpoints).to eq(
      [KubeTraffic::Kubernetes::Endpoint.new(addresses: ["10.1.2.3"], ready: true)]
    )
    expect(slices.last.endpoints).to eq(
      [KubeTraffic::Kubernetes::Endpoint.new(addresses: ["10.1.2.4"], ready: false)]
    )
  end

  it "maps an EndpointSlice Pod targetRef" do
    slices = listed_slices(
      [
        slice_resource(
          name: "api-abc",
          endpoints: [
            {
              "addresses" => ["10.1.2.3"],
              "conditions" => { "ready" => true },
              "targetRef" => { "kind" => "Pod", "namespace" => "apps", "name" => "api-abc" }
            }
          ]
        )
      ]
    )

    expect(slices.first.endpoints.first.target_ref).to eq(
      KubeTraffic::Kubernetes::TargetRef.new(kind: "Pod", namespace: "apps", name: "api-abc")
    )
  end

  it "fetches a Pod from the selected namespace" do
    api = double("api")
    expect(api).to receive(:get_pod).with("api-abc", "apps").and_return(
      Kubeclient::Resource.new(
        "metadata" => { "name" => "api-abc", "namespace" => "apps" },
        "status" => {
          "podIP" => "10.1.2.3",
          "phase" => "Running",
          "conditions" => [
            { "type" => "Ready", "status" => "True" }
          ]
        }
      )
    )

    pod = described_class.new(
      api: api,
      networking_api: double("networking_api"),
      discovery_api: double("discovery_api"),
      namespace: "apps"
    ).get_pod("api-abc")

    expect(pod).to eq(
      KubeTraffic::Kubernetes::Pod.new(
        name: "api-abc",
        namespace: "apps",
        ip: "10.1.2.3",
        phase: "Running",
        ready: true
      )
    )
  end

  it "returns nil when the Pod is missing" do
    api = double("api")
    allow(api).to receive(:get_pod).with("api-abc", "apps")
      .and_raise(http_error(404, "pods \"api-abc\" not found"))

    expect(
      described_class.new(
        api: api,
        networking_api: double("networking_api"),
        discovery_api: double("discovery_api"),
        namespace: "apps"
      ).get_pod("api-abc")
    ).to be_nil
  end

  it "does not query the API for a blank Pod name" do
    api = double("api")
    expect(api).not_to receive(:get_pod)

    expect(
      described_class.new(
        api: api,
        networking_api: double("networking_api"),
        discovery_api: double("discovery_api")
      ).get_pod(" ")
    ).to be_nil
  end

  it "preserves unknown EndpointSlice readiness instead of inventing true or false" do
    slices = listed_slices(
      [
        slice_resource(
          name: "api-abc",
          endpoints: [{ "addresses" => ["10.1.2.3"] }]
        )
      ]
    )

    expect(slices.first.endpoints.first.ready).to be_nil
  end

  it "returns no EndpointSlices when the Service name is blank" do
    discovery_api = double("discovery_api")
    expect(discovery_api).not_to receive(:get_endpoint_slices)

    expect(
      described_class.new(
        api: instance_double(Kubeclient::Client),
        networking_api: double("networking_api"),
        discovery_api: discovery_api
      ).list_endpoint_slices(" ")
    ).to eq([])
  end

  it "maps EndpointSlice list authorization failures" do
    discovery_api = double("discovery_api")
    allow(discovery_api).to receive(:get_endpoint_slices).and_raise(http_error(403, "Forbidden"))

    expect {
      described_class.new(
        api: instance_double(Kubeclient::Client),
        networking_api: double("networking_api"),
        discovery_api: discovery_api
      ).list_endpoint_slices("api")
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps Ingress list authorization failures" do
    networking_api = double("networking_api")
    allow(networking_api).to receive(:get_ingresses).and_raise(http_error(403, "Forbidden"))

    expect {
      described_class.new(
        api: instance_double(Kubeclient::Client),
        networking_api: networking_api
      ).list_ingresses
    }.to raise_error(
      KubeTraffic::Kubernetes::AuthorizationError,
      /not authorized to access the Kubernetes API/
    )
  end

  it "maps Ingress list HTTP errors as API errors" do
    networking_api = double("networking_api")
    allow(networking_api).to receive(:get_ingresses).and_raise(http_error(500, "Internal error"))

    expect {
      described_class.new(
        api: instance_double(Kubeclient::Client),
        networking_api: networking_api
      ).list_ingresses
    }.to raise_error(
      KubeTraffic::Kubernetes::ApiError,
      /Kubernetes API error/
    )
  end

  it "raises when kubeconfig cannot be parsed" do
    kubeconfig = Tempfile.new(["kubeconfig", ".yml"])
    kubeconfig.write("not: valid: kubeconfig: [")
    kubeconfig.flush

    expect {
      described_class.connect(kubeconfig: kubeconfig.path)
    }.to raise_error(
      KubeTraffic::Kubernetes::ConfigError,
      /unable to load kubeconfig/
    )
  ensure
    kubeconfig.close!
  end
end
