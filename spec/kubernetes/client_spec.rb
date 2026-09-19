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

  it "loads kubeconfig and builds core and networking clients for the current context" do
    kubeconfig = write_kubeconfig
    api = instance_double(Kubeclient::Client)
    networking_api = instance_double(Kubeclient::Client)
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
    expect(Kubeclient::Client).to receive(:new).twice.and_return(api)

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
                    { "path" => "/app", "pathType" => "Prefix" }
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
            KubeTraffic::Kubernetes::IngressPath.new(path: "/app", path_type: "Prefix")
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
